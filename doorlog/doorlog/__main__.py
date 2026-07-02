"""Entry point: python -m doorlog --config /etc/doorlog/config.yaml"""

import argparse
import logging
import logging.handlers
import os
import signal
import sys
import threading

from .config import Config
from .poller import Poller
from .store import Store

log = logging.getLogger("doorlog")


def _setup_logging(cfg):
    root = logging.getLogger()
    root.setLevel(cfg.log_level.upper())
    formatter = logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s")

    handlers = [logging.StreamHandler(sys.stdout)]
    try:
        parent = os.path.dirname(cfg.log_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        # WatchedFileHandler reopens after logrotate moves the file.
        handlers.append(logging.handlers.WatchedFileHandler(cfg.log_path))
    except OSError as exc:
        print(f"WARNING: cannot open {cfg.log_path} ({exc}); logging to stdout only",
              file=sys.stderr)
    for handler in handlers:
        handler.setFormatter(formatter)
        root.addHandler(handler)
    logging.getLogger("pymodbus").setLevel(logging.WARNING)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="doorlog", description="Permanent door-event history logger"
    )
    parser.add_argument("--config", default="/etc/doorlog/config.yaml",
                        help="path to YAML config (default: %(default)s)")
    args = parser.parse_args(argv)

    cfg = Config.load(args.config)
    _setup_logging(cfg)

    stop = threading.Event()

    def _handle_signal(signum, _frame):
        log.info("received %s — shutting down", signal.Signals(signum).name)
        stop.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    store = Store(cfg.db_path)
    try:
        Poller(cfg, store, stop).run()
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
