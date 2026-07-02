"""WAGO PLC simulator for the door-event register map (spec §3).

Serves the same Modbus holding-register layout the real PLC mirror produces
(Appendix A), with true ring-buffer semantics, so the doorlog service can be
tested end-to-end without hardware.

Usage:
    python tools/plc_sim.py [--port 5020] [--host 127.0.0.1] [--doors 50]

Then type commands on stdin:
    push <door> <etype> [epoch_seconds]    # add one event (ring-wraps at 10)
    quit
"""

import argparse
import sys
import threading
import time

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusServerContext,
    ModbusSlaveContext,
)
from pymodbus.server import StartTcpServer

RING_DEPTH = 10
WORDS_PER_EVENT = 5
DOOR_BLOCK_WORDS = 52


class PlcSim:
    def __init__(self, context, base=0, n_doors=50):
        self._ctx = context[0]  # single-slave context
        self._base = base
        self._n_doors = n_doors
        self._seq = 0
        self._head = {d: 0 for d in range(1, n_doors + 1)}
        self._count = {d: 0 for d in range(1, n_doors + 1)}

    def _set(self, address, values):
        self._ctx.setValues(3, address, values)  # fc 3 = holding registers

    @staticmethod
    def _words(value):
        """High-word-first, matching Appendix A."""
        return [(value >> 16) & 0xFFFF, value & 0xFFFF]

    def push(self, door, etype, ts=None):
        if not 1 <= door <= self._n_doors:
            raise ValueError(f"door out of range: {door}")
        ts = int(ts if ts is not None else time.time())
        self._seq += 1
        slot = self._head[door]

        ev_base = self._base + self._n_doors * 2 + (door - 1) * DOOR_BLOCK_WORDS
        self._set(ev_base + slot * WORDS_PER_EVENT,
                  self._words(self._seq) + self._words(ts) + [etype & 0xFFFF])

        self._head[door] = (slot + 1) % RING_DEPTH
        self._count[door] = min(RING_DEPTH, self._count[door] + 1)
        self._set(ev_base + 50, [self._head[door], self._count[door]])

        # Summary block: door's newest global seq
        self._set(self._base + (door - 1) * 2, self._words(self._seq))
        return self._seq


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5020)
    parser.add_argument("--doors", type=int, default=50)
    parser.add_argument("--base", type=int, default=0)
    args = parser.parse_args()

    total = args.base + args.doors * 2 + args.doors * DOOR_BLOCK_WORDS
    block = ModbusSequentialDataBlock(0, [0] * (total + 1))
    slave = ModbusSlaveContext(hr=block, zero_mode=True)
    context = ModbusServerContext(slaves=slave, single=True)

    threading.Thread(
        target=StartTcpServer,
        kwargs={"context": context, "address": (args.host, args.port)},
        daemon=True,
    ).start()
    print(f"READY modbus sim on {args.host}:{args.port} "
          f"({args.doors} doors, base {args.base})", flush=True)

    sim = PlcSim(context, base=args.base, n_doors=args.doors)
    for line in sys.stdin:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "quit":
            break
        if parts[0] == "push":
            door = int(parts[1])
            etype = int(parts[2])
            ts = int(parts[3]) if len(parts) > 3 else None
            seq = sim.push(door, etype, ts)
            print(f"OK seq={seq} door={door} etype={etype}", flush=True)
        else:
            print(f"ERR unknown command: {parts[0]}", flush=True)


if __name__ == "__main__":
    main()
