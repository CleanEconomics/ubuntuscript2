"""Permanent door-event history logger.

Polls the WAGO bay-door PLC over Modbus TCP, detects events that are new
since the last poll, and appends them to a local SQLite database (WAL mode).
The PLC keeps only the last 10 events per door in its ring buffer; this
service is the permanent, unbounded audit trail on the IPC.
"""

__version__ = "1.0.0"
