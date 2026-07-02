"""SQLite store (spec §6). WAL mode so dashboards can read while we write."""

import os
import sqlite3
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS door_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    door_id         INTEGER NOT NULL,          -- 1..50
    door_label      TEXT    NOT NULL,          -- 'R-08', 'S-14'
    event_seq       INTEGER NOT NULL,          -- global monotonic, from PLC
    event_type      INTEGER NOT NULL,          -- enum code 1..4
    event_label     TEXT    NOT NULL,          -- 'OPEN', 'ALARM (tamper)', ...
    event_ts        TEXT    NOT NULL,          -- ISO local: '2026-07-02 07:31:21'
    event_ts_epoch  INTEGER NOT NULL,          -- seconds since 1970 (local)
    inserted_at     TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (door_id, event_seq)                -- dedup guard
);

CREATE INDEX IF NOT EXISTS ix_door_ts   ON door_events (door_id, event_ts_epoch);
CREATE INDEX IF NOT EXISTS ix_ts        ON door_events (event_ts_epoch);
CREATE INDEX IF NOT EXISTS ix_type_ts   ON door_events (event_type, event_ts_epoch);
"""

INSERT_SQL = (
    "INSERT OR IGNORE INTO door_events "
    "(door_id, door_label, event_seq, event_type, event_label, event_ts, event_ts_epoch) "
    "VALUES (?, ?, ?, ?, ?, ?, ?)"
)


class Store:
    def __init__(self, path):
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        self._conn = sqlite3.connect(path)
        self._conn.execute("PRAGMA journal_mode = WAL;")
        self._conn.executescript(SCHEMA)
        self._conn.commit()

    def high_water(self):
        """Per-door max stored sequence — makes restarts resumable (spec §5.1)."""
        rows = self._conn.execute(
            "SELECT door_id, MAX(event_seq) FROM door_events GROUP BY door_id"
        )
        return {door_id: max_seq for door_id, max_seq in rows}

    def count(self):
        return self._conn.execute("SELECT COUNT(*) FROM door_events").fetchone()[0]

    def insert_events(self, rows):
        """Idempotent append; returns how many rows were actually new."""
        before = self._conn.total_changes
        self._conn.executemany(INSERT_SQL, rows)
        self._conn.commit()
        return self._conn.total_changes - before

    def prune(self, years):
        # event_ts_epoch encodes local wall-clock, time.time() is UTC; the
        # hours of skew are irrelevant at a multi-year retention horizon.
        cutoff = int(time.time()) - years * 31557600
        cursor = self._conn.execute(
            "DELETE FROM door_events WHERE event_ts_epoch < ?", (cutoff,)
        )
        self._conn.commit()
        return cursor.rowcount

    def close(self):
        self._conn.commit()
        self._conn.close()
