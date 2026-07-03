"""Configuration loading (spec §7). Single YAML file merged over defaults."""

import copy

import yaml

DEFAULTS = {
    "plc_host": "",  # required — set in config.yaml (no hardcoded PLC address)
    "plc_port": 502,
    "unit_id": 1,
    "reg_base": 0,
    "word_order_high_first": True,
    "poll_interval_sec": 3.0,
    "db_path": "/var/lib/doorlog/doorlog.db",
    "n_doors": 50,
    "max_events": 10,
    "door_labels": {
        # Doors 1..(split_at-1) are Receiving, split_at..n_doors are Shipping.
        "receiving_prefix": "R-",
        "shipping_prefix": "S-",
        "split_at": 26,
        "overrides": {},  # e.g. {7: "DOCK-7"} wins over the prefix scheme
    },
    "event_labels": {
        # Keep identical to the HMI (spec §4). 0 is "not an event", never stored.
        1: "OPEN",
        2: "CLOSED & LOCKED",
        3: "ALARM (timeout)",
        4: "ALARM (tamper)",
    },
    "reconnect_backoff_sec": [1, 2, 5, 10, 30],
    "retention_years": 0,  # 0 = unbounded (default); >0 enables a daily prune
    "log_level": "INFO",
    "log_path": "/var/log/doorlog/doorlog.log",
}


class Config:
    def __init__(self, data=None):
        merged = copy.deepcopy(DEFAULTS)
        for key, value in (data or {}).items():
            if isinstance(value, dict) and isinstance(merged.get(key), dict):
                merged[key].update(value)
            else:
                merged[key] = value

        self.plc_host = str(merged["plc_host"])
        self.plc_port = int(merged["plc_port"])
        self.unit_id = int(merged["unit_id"])
        self.reg_base = int(merged["reg_base"])
        self.word_order_high_first = bool(merged["word_order_high_first"])
        self.poll_interval_sec = float(merged["poll_interval_sec"])
        self.db_path = str(merged["db_path"])
        self.n_doors = int(merged["n_doors"])
        self.max_events = int(merged["max_events"])
        self.retention_years = int(merged["retention_years"])
        self.log_level = str(merged["log_level"])
        self.log_path = str(merged["log_path"])

        backoff = merged["reconnect_backoff_sec"]
        if isinstance(backoff, str):  # tolerate "1,2,5,10,30"
            backoff = [part for part in backoff.split(",") if part.strip()]
        self.reconnect_backoff_sec = [float(v) for v in backoff] or [5.0]

        # YAML may deliver these keys as ints or strings; normalize to int.
        self.event_labels = {
            int(code): str(label) for code, label in merged["event_labels"].items()
        }
        labels = merged["door_labels"]
        self._receiving_prefix = str(labels["receiving_prefix"])
        self._shipping_prefix = str(labels["shipping_prefix"])
        self._split_at = int(labels["split_at"])
        self._door_overrides = {
            int(door): str(label) for door, label in (labels.get("overrides") or {}).items()
        }

    @classmethod
    def load(cls, path):
        with open(path, "r", encoding="utf-8") as handle:
            return cls(yaml.safe_load(handle) or {})

    def door_label(self, door_id):
        override = self._door_overrides.get(door_id)
        if override is not None:
            return override
        if door_id < self._split_at:
            return f"{self._receiving_prefix}{door_id:02d}"
        return f"{self._shipping_prefix}{door_id - self._split_at + 1:02d}"

    def event_label(self, code):
        return self.event_labels.get(code, f"UNKNOWN({code})")
