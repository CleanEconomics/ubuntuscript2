#!/usr/bin/env bash
set -euo pipefail

# 04_beremiz.sh
# Install Beremiz (package or from source), optional systemd service.
# Usage: ./04_beremiz.sh [--mode package|source] [--user beremiz] [--service yes|no] [--cpu 2]
# Defaults: mode=source, user=beremiz, service=yes, cpu=""

# --- Defaults ---
MODE="${1:-source}"            # or "package"
BEREMIZ_USER="beremiz"
INSTALL_DIR="/opt/beremiz"
CREATE_USER=yes
ENABLE_SERVICE=yes
CPU_AFFINITY=""                # leave blank to not pin; set like "2"
GIT_REPO="https://github.com/beremiz/beremiz.git"
PYTHON_BIN="/usr/bin/python3"

# Parse simple flags (optional)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --user) BEREMIZ_USER="$2"; shift 2 ;;
    --no-create-user) CREATE_USER=no; shift ;;
    --service) ENABLE_SERVICE="$2"; shift 2 ;;
    --cpu) CPU_AFFINITY="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--mode package|source] [--user name] [--no-create-user] [--service yes|no] [--cpu N] [--install-dir /path]"; exit 0 ;;
    *) shift ;;
  esac
done

# Auto-elevate with sudo if not root
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  exec sudo bash "$0" "$@"
fi

echo "==============================="
echo " Installing Beremiz"
echo " Mode: $MODE"
echo " User: $BEREMIZ_USER"
echo " Install dir: $INSTALL_DIR"
echo " Create user: $CREATE_USER"
echo " Enable service: $ENABLE_SERVICE"
echo " CPU affinity: ${CPU_AFFINITY:-none}"
echo "==============================="

# Make sure apt index is up to date
if command -v apt >/dev/null 2>&1; then
  apt update -y
fi

# Common dependencies
echo "📦 Installing dependencies..."
apt install -y git build-essential python3 python3-pip python3-venv \
               python3-wxgtk4.0 python3-lxml python3-pyro4 python3-zeroconf \
               wget curl || true

# optional diagnostics / tools
apt install -y net-tools || true

# Create beremiz user if desired
if [[ "$CREATE_USER" == "yes" ]]; then
  if ! id -u "$BEREMIZ_USER" >/dev/null 2>&1; then
    echo "👤 Creating user $BEREMIZ_USER..."
    useradd --system --create-home --shell /usr/sbin/nologin "$BEREMIZ_USER"
    usermod -aG sudo "$BEREMIZ_USER" || true
  else
    echo "👤 User $BEREMIZ_USER already exists"
  fi
fi

# Prepare log dir
LOG_DIR="/var/log/beremiz"
mkdir -p "$LOG_DIR"
chown "$BEREMIZ_USER":"$BEREMIZ_USER" "$LOG_DIR" || true
chmod 755 "$LOG_DIR"

if [[ "$MODE" == "package" ]]; then
  echo "📦 Installing beremiz from apt package (if available)..."
  apt install -y beremiz || {
    echo "⚠️ Package install failed or not available. Consider using --mode source"
  }
  echo "✅ Package mode complete. Run 'beremiz' to start IDE."
else
  # Source install into INSTALL_DIR
  echo "🔧 Installing beremiz from source into $INSTALL_DIR..."
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  chown "$BEREMIZ_USER":"$BEREMIZ_USER" "$INSTALL_DIR"

  echo "🔁 Cloning repository..."
  sudo -u "$BEREMIZ_USER" git clone "$GIT_REPO" "$INSTALL_DIR" --depth 1

  # Create python venv and install pip deps (local to user)
  echo "🐍 Setting up Python virtualenv..."
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
  # Activate and install
  # Use pip from venv to avoid interfering system packages
  "$INSTALL_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
  # Install any packaging requirements that may be needed by Beremiz
  "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" 2>/dev/null || true

  # Make a wrapper script to run Beremiz easily
  cat > "$INSTALL_DIR/run-beremiz.sh" <<EOF
#!/usr/bin/env bash
set -e
# Wrapper to run Beremiz under the venv
cd "$INSTALL_DIR"
exec ${CPU_AFFINITY:+/usr/bin/taskset -c $CPU_AFFINITY } "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/Beremiz.py" "\$@"
EOF
  chmod +x "$INSTALL_DIR/run-beremiz.sh"
  chown "$BEREMIZ_USER":"$BEREMIZ_USER" "$INSTALL_DIR/run-beremiz.sh"

  echo "✅ Beremiz source installed to $INSTALL_DIR (venv ready)."
  echo "Start the IDE manually as the beremiz user: sudo -u $BEREMIZ_USER DISPLAY=:0 $INSTALL_DIR/run-beremiz.sh &"
fi

# Optionally create a systemd service to run the runtime (if requested)
if [[ "$ENABLE_SERVICE" == "yes" ]]; then
  echo "⚙️ Creating systemd service for Beremiz runtime..."

  SERVICE_FILE="/etc/systemd/system/beremiz.service"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Beremiz soft PLC runtime
After=network.target

[Service]
Type=simple
User=$BEREMIZ_USER
Group=$BEREMIZ_USER
WorkingDirectory=$INSTALL_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$INSTALL_DIR/run-beremiz.sh
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable --now beremiz.service
  echo "✅ Service created and started: systemctl status beremiz.service"
  echo "Logs: sudo journalctl -u beremiz.service -f"
fi

echo ""
echo "==============================="
echo " Beremiz install finished"
echo " Mode: $MODE"
echo " Install dir: $INSTALL_DIR"
[[ "$ENABLE_SERVICE" == "yes" ]] && echo "Service: enabled (systemctl status beremiz.service)"
echo "To run IDE interactively: sudo -u $BEREMIZ_USER DISPLAY=:0 $INSTALL_DIR/run-beremiz.sh &"
echo "To run manually (source mode): $INSTALL_DIR/run-beremiz.sh"
echo "Logs: $LOG_DIR and journalctl -u beremiz.service"
echo "==============================="
