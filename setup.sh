#!/usr/bin/env bash
set -e

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

# --- Require the kiosk target up front (nothing is hardcoded) -----------------
#   APPLIANCE_URL='http://host:port/path'  -> what the kiosk opens
#   APPLIANCE_IP=192.168.1.50              -> shorthand for http://<ip>
#   PLC_HOST=192.168.1.17                  -> Modbus PLC for the door logger
#                                             (defaults to APPLIANCE_IP if set)
if [[ -z "${APPLIANCE_URL:-}" && -z "${APPLIANCE_IP:-}" && -z "${KIOSK_URL:-}" ]]; then
  echo "❌ No kiosk target set — nothing is hardcoded, you must pass one:"
  echo "   sudo APPLIANCE_URL='http://74.208.61.41:3005/login' PLC_HOST=192.168.1.17 bash $0"
  echo "   sudo APPLIANCE_IP=192.168.1.50 bash $0"
  exit 1
fi
TARGET_DISPLAY="${KIOSK_URL:-${APPLIANCE_URL:-http://$APPLIANCE_IP}}"
export APPLIANCE_URL APPLIANCE_IP KIOSK_URL PLC_HOST 2>/dev/null || true

# --------------------------------------------
# Detect parent run directory (from install.sh)
# --------------------------------------------
if [[ -n "$INSTALL_RUN_DIR" && -d "$INSTALL_RUN_DIR" ]]; then
  LOG_DIR="$INSTALL_RUN_DIR"
else
  # fallback if run standalone
  LOG_DIR="$HOME/setup_logs/$(date +'%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$LOG_DIR"
fi

LOG_FILE="$LOG_DIR/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================="
echo "  🧰 Remote Ubuntu Setup"
echo "==============================="
echo "📁 Logging to: $LOG_FILE"
echo "==============================="

# --------------------------------------------
# Function to fetch and execute a script from GitHub
# --------------------------------------------
FAILED_SCRIPTS=()

run_remote_script() {
  local script_name="$1"
  local url="$RAW_BASE/scripts/$script_name"

  # individual script log inside same folder
  local log_name="${script_name%.sh}.log"
  local script_log="$LOG_DIR/$log_name"

  echo "▶️  Running $script_name ..."
  echo "📄 Logging to: $script_log"

  # One failing step must NOT abort the provision — record it, keep going,
  # and report at the end.
  local status=0
  {
    echo "===== START $script_name $(date) ====="
    curl -fsSL "$url" | bash || status=$?
    echo "===== END $script_name $(date) (exit $status) ====="
  } > >(tee -a "$script_log" "$LOG_FILE") 2>&1

  if [[ $status -ne 0 ]]; then
    FAILED_SCRIPTS+=("$script_name")
    echo "⚠️  $script_name FAILED (exit $status) — continuing with remaining steps"
  else
    echo "✅ Finished $script_name"
  fi
  echo ""
}

# --------------------------------------------
# Run all numbered scripts in order
# --------------------------------------------
SCRIPT_LIST=$(curl -fsSL "https://api.github.com/repos/$REPO/contents/scripts?ref=$BRANCH" \
  | grep '"name":' | cut -d '"' -f 4 | grep '^[0-9][0-9]_.*\.sh' | sort)

for script in $SCRIPT_LIST; do
  run_remote_script "$script"
done

echo "==============================="
if [[ ${#FAILED_SCRIPTS[@]} -gt 0 ]]; then
  echo "⚠️  Setup finished with FAILURES: ${FAILED_SCRIPTS[*]}"
  echo "   Re-run a failed step with:"
  echo "   curl -fsSL $RAW_BASE/scripts/<name> | sudo APPLIANCE_URL='$TARGET_DISPLAY' bash"
else
  echo "🎯 Setup complete!"
fi
echo "Kiosk URL: $TARGET_DISPLAY"
echo "Logs saved to: $LOG_DIR"
echo "==============================="
