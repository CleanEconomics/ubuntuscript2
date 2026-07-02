#!/usr/bin/env bash
# Nightly WAL-safe SQLite backup (spec §8): VACUUM INTO a dated copy,
# keep 30 days. Raw file copies of a WAL database are not safe; this is.
set -euo pipefail

DB="/var/lib/doorlog/doorlog.db"
BACKUP_DIR="/var/lib/doorlog/backup"
OUT="$BACKUP_DIR/doorlog-$(date +%Y%m%d).db"

mkdir -p "$BACKUP_DIR"
rm -f "$OUT"    # VACUUM INTO refuses to overwrite
sqlite3 "$DB" "VACUUM INTO '$OUT'"
find "$BACKUP_DIR" -name 'doorlog-*.db' -mtime +30 -delete
echo "$(date -Is) backup written: $OUT"
