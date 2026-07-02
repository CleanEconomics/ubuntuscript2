#!/usr/bin/env bash
set -euo pipefail

# 09_doorlog.sh
# ---------------------------------------------------------------------------
# Install the Door Event History Logger service.
# Polls the WAGO bay-door PLC (192.168.1.17) over Modbus TCP and stores every
# door event permanently in SQLite at /var/lib/doorlog/doorlog.db — the PLC
# only keeps the last 10 events per door; the IPC keeps everything, forever.
#
# Installs: /opt/doorlog (code + venv), /etc/doorlog/config.yaml,
# systemd unit "doorlog", logrotate, and a nightly WAL-safe DB backup.
#
# PLC prerequisite: the Modbus holding-register mirror block must exist on
# the PLC (see doorlog/ spec, Appendix A). Until it does, the service just
# retries with backoff — installing first is safe.
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

APP_DIR="/opt/doorlog"
CFG_DIR="/etc/doorlog"
DATA_DIR="/var/lib/doorlog"
LOG_DIR="/var/log/doorlog"
SVC_USER="doorlog"

echo "==============================="
echo " 🚪 Installing Door Event Logger"
echo "==============================="

# --- Auto-elevate to root (works for ./file and curl|bash) -------------------
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  if [[ -r "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" == *.sh ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  exec sudo -E bash -c "curl -fsSL '$RAW_BASE/scripts/09_doorlog.sh' | bash"
fi

# --- System packages ---------------------------------------------------------
echo "📦 Installing system packages..."
apt update -y || true
apt install -y python3 python3-venv python3-pip sqlite3 curl || true

# --- Service user + directories ----------------------------------------------
if ! id "$SVC_USER" &>/dev/null; then
  echo "👤 Creating service user $SVC_USER..."
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SVC_USER"
fi
install -d -m 755 "$APP_DIR" "$APP_DIR/doorlog" "$APP_DIR/tools" "$CFG_DIR"
install -d -m 750 -o "$SVC_USER" -g "$SVC_USER" "$DATA_DIR" "$DATA_DIR/backup" "$LOG_DIR"

# --- Fetch application files (local repo checkout if present, else GitHub) ---
SRC_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../doorlog/doorlog/poller.py" ]]; then
  SRC_DIR="$(cd "$SCRIPT_DIR/../doorlog" && pwd)"
  echo "📁 Using local files from $SRC_DIR"
else
  echo "🌐 Downloading application files from $RAW_BASE/doorlog/"
fi

FILES=(
  requirements.txt
  config.yaml
  doorlog.service
  doorlog.logrotate
  backup.sh
  doorlog/__init__.py
  doorlog/__main__.py
  doorlog/config.py
  doorlog/store.py
  doorlog/poller.py
  tools/plc_sim.py
)
for f in "${FILES[@]}"; do
  if [[ -n "$SRC_DIR" ]]; then
    cp "$SRC_DIR/$f" "$APP_DIR/$f"
  else
    curl -fsSL "$RAW_BASE/doorlog/$f" -o "$APP_DIR/$f"
  fi
done
chmod +x "$APP_DIR/backup.sh"

# --- Python virtualenv + pinned dependencies ---------------------------------
echo "🐍 Creating virtualenv and installing dependencies..."
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
chown -R "$SVC_USER":"$SVC_USER" "$APP_DIR"

# --- Config (never overwrite an existing one) --------------------------------
if [[ ! -f "$CFG_DIR/config.yaml" ]]; then
  echo "⚙️  Installing default config to $CFG_DIR/config.yaml"
  cp "$APP_DIR/config.yaml" "$CFG_DIR/config.yaml"
else
  echo "⚙️  Keeping existing $CFG_DIR/config.yaml"
fi
chown root:"$SVC_USER" "$CFG_DIR/config.yaml"
chmod 640 "$CFG_DIR/config.yaml"

# --- logrotate + nightly backup ----------------------------------------------
echo "🧾 Installing logrotate and nightly backup cron..."
cp "$APP_DIR/doorlog.logrotate" /etc/logrotate.d/doorlog
cat > /etc/cron.d/doorlog-backup <<EOF
# Nightly WAL-safe SQLite backup (VACUUM INTO), keep 30 days
10 2 * * * $SVC_USER $APP_DIR/backup.sh >> $LOG_DIR/backup.log 2>&1
EOF
chmod 644 /etc/cron.d/doorlog-backup

# --- systemd service -----------------------------------------------------------
echo "🔧 Installing systemd service..."
cp "$APP_DIR/doorlog.service" /etc/systemd/system/doorlog.service
systemctl daemon-reload
systemctl enable doorlog.service
systemctl restart doorlog.service

sleep 2
systemctl --no-pager --lines=5 status doorlog.service || true

echo ""
echo "==============================="
echo "✅ Door Event Logger installed"
echo "   DB:      $DATA_DIR/doorlog.db"
echo "   Config:  $CFG_DIR/config.yaml"
echo "   Logs:    $LOG_DIR/doorlog.log"
echo "   Status:  systemctl status doorlog"
echo "   Query:   sqlite3 'file:$DATA_DIR/doorlog.db?mode=ro' 'SELECT * FROM door_events ORDER BY id DESC LIMIT 10;'"
echo "==============================="
