"""Modbus poll loop (spec §3, §5, §8).

Reads the 100-register summary each cycle, deep-reads only doors whose
maxSeq advanced, decodes ring slots, and appends new events idempotently.
"""

import logging
import time
from datetime import datetime, timedelta

from pymodbus.client import ModbusTcpClient
from pymodbus.exceptions import ModbusException
from pymodbus.pdu import ExceptionResponse

log = logging.getLogger("doorlog")

# Modbus caps a single read at 125 registers; 60 doors x 2 words = 120.
SUMMARY_DOORS_PER_READ = 60
WORDS_PER_EVENT = 5
DOOR_BLOCK_WORDS = 52  # 10 slots x 5 words + iHead + nCount


class ModbusReadError(RuntimeError):
    """transport=True means the connection itself is suspect (reconnect);
    transport=False is a protocol-level rejection (skip, connection fine)."""

    def __init__(self, message, transport=True):
        super().__init__(message)
        self.transport = transport


def u32(hi_word, lo_word, high_first=True):
    """Combine a 2-register DWORD; word order is a config flag (spec §5.3a)."""
    if high_first:
        return (hi_word << 16) | lo_word
    return (lo_word << 16) | hi_word


def decode_ts(seconds):
    """CODESYS DT here is LOCAL wall-clock seconds since 1970 (spec §5.3b).
    datetime.fromtimestamp() would double-shift by the host offset — use the
    naive timedelta form so the stored string matches the HMI clock."""
    dt_local = datetime(1970, 1, 1) + timedelta(seconds=int(seconds))
    return dt_local.isoformat(sep=" ")


class PlcClient:
    def __init__(self, cfg):
        self._cfg = cfg
        self._client = ModbusTcpClient(cfg.plc_host, port=cfg.plc_port, timeout=3)

    def connect(self):
        try:
            return self._client.connect()
        except OSError:
            return False

    def close(self):
        try:
            self._client.close()
        except OSError:
            pass

    def _read(self, address, count):
        try:
            result = self._client.read_holding_registers(
                address=address, count=count, slave=self._cfg.unit_id
            )
        except ModbusException as exc:
            raise ModbusReadError(f"modbus I/O error: {exc}") from exc
        except OSError as exc:
            raise ModbusReadError(f"socket error: {exc}") from exc
        if result is None:
            raise ModbusReadError("no response from PLC")
        if isinstance(result, ExceptionResponse):
            raise ModbusReadError(
                f"PLC rejected read at {address} x{count}: {result}", transport=False
            )
        if result.isError():
            raise ModbusReadError(f"modbus error at {address} x{count}: {result}")
        registers = getattr(result, "registers", None) or []
        if len(registers) < count:
            raise ModbusReadError(
                f"short read at {address}: got {len(registers)}, wanted {count}"
            )
        return registers

    def read_summary(self):
        """maxSeq for every door, one or two requests (spec §3.1)."""
        cfg = self._cfg
        values = []
        door = 1
        while door <= cfg.n_doors:
            batch = min(SUMMARY_DOORS_PER_READ, cfg.n_doors - door + 1)
            address = cfg.reg_base + (door - 1) * 2
            registers = self._read(address, batch * 2)
            for i in range(batch):
                values.append(
                    u32(registers[2 * i], registers[2 * i + 1], cfg.word_order_high_first)
                )
            door += batch
        return values  # index 0 = door 1

    def read_door(self, door_id):
        """52-register event block for one door (spec §3.2)."""
        cfg = self._cfg
        address = cfg.reg_base + cfg.n_doors * 2 + (door_id - 1) * DOOR_BLOCK_WORDS
        return self._read(address, DOOR_BLOCK_WORDS)


class Poller:
    def __init__(self, cfg, store, stop_event):
        self.cfg = cfg
        self.store = store
        self.stop = stop_event
        self.plc = PlcClient(cfg)
        self.last_seq = {}
        self._warned_codes = set()

    def run(self):
        cfg = self.cfg
        self.last_seq = self.store.high_water()
        log.info(
            "starting: plc=%s:%d unit=%d base=%d poll=%.1fs doors=%d db=%s (%d rows, %d doors resumed)",
            cfg.plc_host, cfg.plc_port, cfg.unit_id, cfg.reg_base,
            cfg.poll_interval_sec, cfg.n_doors, cfg.db_path,
            self.store.count(), len(self.last_seq),
        )

        connected = False
        attempt = 0
        next_prune = 0.0

        while not self.stop.is_set():
            if not connected:
                if self.plc.connect():
                    connected = True
                    attempt = 0
                    log.info("connected to PLC %s:%d", cfg.plc_host, cfg.plc_port)
                else:
                    if attempt == 0:
                        log.warning(
                            "PLC %s:%d unreachable — retrying (backoff %s s, capped)",
                            cfg.plc_host, cfg.plc_port, cfg.reconnect_backoff_sec,
                        )
                    delay = cfg.reconnect_backoff_sec[
                        min(attempt, len(cfg.reconnect_backoff_sec) - 1)
                    ]
                    attempt += 1
                    self.stop.wait(delay)
                    continue

            try:
                summary = self.plc.read_summary()
            except ModbusReadError as exc:
                log.warning("connection to PLC lost (%s) — reconnecting", exc)
                self.plc.close()
                connected = False
                continue

            for door_id in range(1, cfg.n_doors + 1):
                if self.stop.is_set():
                    break
                max_seq = summary[door_id - 1]
                if max_seq <= self.last_seq.get(door_id, 0):
                    continue
                try:
                    self._harvest_door(door_id, max_seq)
                except ModbusReadError as exc:
                    if exc.transport:
                        log.warning(
                            "connection to PLC lost while reading door %d (%s) — reconnecting",
                            door_id, exc,
                        )
                        self.plc.close()
                        connected = False
                        break
                    # Protocol rejection: skip this door this cycle (spec §8);
                    # last_seq wasn't advanced, so it's retried next poll.
                    log.warning("door %d read rejected (%s) — skipping this cycle", door_id, exc)
                except Exception:
                    log.exception("door %d: failed to store events — will retry next cycle", door_id)

            if cfg.retention_years > 0 and time.monotonic() >= next_prune:
                deleted = self.store.prune(cfg.retention_years)
                if deleted:
                    log.info("pruned %d rows older than %d years", deleted, cfg.retention_years)
                next_prune = time.monotonic() + 86400

            self.stop.wait(cfg.poll_interval_sec)

        self.plc.close()
        log.info("stopped")

    def _harvest_door(self, door_id, max_seq):
        cfg = self.cfg
        last = self.last_seq.get(door_id, 0)
        registers = self.plc.read_door(door_id)
        high_first = cfg.word_order_high_first

        rows = []
        for slot in range(cfg.max_events):
            offset = slot * WORDS_PER_EVENT
            seq = u32(registers[offset], registers[offset + 1], high_first)
            if seq == 0 or seq <= last:  # empty slot / already stored
                continue
            ts = u32(registers[offset + 2], registers[offset + 3], high_first)
            etype = registers[offset + 4]
            if etype == 0:
                continue
            if etype not in cfg.event_labels and etype not in self._warned_codes:
                self._warned_codes.add(etype)
                log.warning("unknown event code %d (storing as UNKNOWN(%d))", etype, etype)
            rows.append((
                door_id,
                cfg.door_label(door_id),
                seq,
                etype,
                cfg.event_label(etype),
                decode_ts(ts),
                ts,
            ))
        rows.sort(key=lambda row: row[2])  # ring slots are not time-ordered

        inserted = self.store.insert_events(rows) if rows else 0

        # Loss visibility (spec §5.4). The sequence counter is global across
        # all doors, so a per-door seq gap alone means nothing. Loss is only
        # possible when EVERY ring slot is newer than what we had stored —
        # i.e. the door produced >= ring-depth events since the last poll and
        # anything beyond the ring was overwritten unseen.
        n_count = registers[51]  # ring diagnostic: valid entries 0..10
        if last == 0:
            if n_count >= cfg.max_events:
                log.info(
                    "door %d: ring already full at first read — history starts with its last %d events; anything older was never mirrored",
                    door_id, cfg.max_events,
                )
        elif len(rows) >= cfg.max_events:
            log.warning(
                "door %d: possible event loss — %d new events since last poll fills the whole ring (depth %d); older unseen events may have been overwritten",
                door_id, len(rows), cfg.max_events,
            )

        self.last_seq[door_id] = max([last, max_seq] + [row[2] for row in rows])
        if inserted:
            log.info(
                "door %d (%s): stored %d new event(s), latest seq %d",
                door_id, cfg.door_label(door_id), inserted, self.last_seq[door_id],
            )
