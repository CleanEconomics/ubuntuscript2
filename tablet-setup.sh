#!/usr/bin/env bash
set -e

# tablet-setup.sh
# ---------------------------------------------------------------------------
# Provision a LINUX TABLET as a kiosk viewer device.
#
# Runs the slim profile of the stack — the tablet only displays the appliance
# web portal; it does NOT get the IPC payload (Node-RED, Docker, Beremiz, or
# the door-event logger — those live on the IPC, the single system of record).
#
#   included: system update, wallpaper + Plymouth branding, RustDesk remote
#             support, Google Chrome kiosk, tablet tweaks (rotation lock,
#             on-screen keyboard, no suspend), automatic updates OFF
#   skipped:  02 node stack, 03 python/docker, 04 beremiz, 09 doorlog
#
# Usage — the kiosk target is REQUIRED (no hardcoded default):
#   sudo APPLIANCE_URL='http://host:port/path' ./tablet-setup.sh && sudo reboot
#   sudo APPLIANCE_IP=192.168.1.50             ./tablet-setup.sh && sudo reboot
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

# --- Require the kiosk target up front ----------------------------------------
if [[ -z "${APPLIANCE_URL:-}" && -z "${APPLIANCE_IP:-}" && -z "${KIOSK_URL:-}" ]]; then
  echo "❌ No kiosk target set — nothing is hardcoded, you must pass one:"
  echo "   sudo APPLIANCE_URL='http://host:port/path' bash $0"
  echo "   sudo APPLIANCE_IP=<ip> bash $0"
  exit 1
fi
TARGET_DISPLAY="${KIOSK_URL:-${APPLIANCE_URL:-http://$APPLIANCE_IP}}"
export APPLIANCE_URL APPLIANCE_IP KIOSK_URL 2>/dev/null || true

TABLET_SCRIPTS=(
  01_system_update.sh
  05_wallpaper.sh
  06_plymouth.sh
  07_anydesk_install.sh
  08_kiosk.sh
  tablet_tweaks.sh
  10_disable_updates.sh
)

# --------------------------------------------
# Logging (same layout as setup.sh)
# --------------------------------------------
if [[ -n "${INSTALL_RUN_DIR:-}" && -d "${INSTALL_RUN_DIR:-}" ]]; then
  LOG_DIR="$INSTALL_RUN_DIR"
else
  LOG_DIR="$HOME/setup_logs/tablet_$(date +'%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$LOG_DIR"
fi

LOG_FILE="$LOG_DIR/tablet-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================="
echo "  📱 Tablet Kiosk Setup"
echo "==============================="
echo "🌐 Kiosk target: $TARGET_DISPLAY"
echo "📁 Logging to:   $LOG_FILE"
echo "==============================="

# --------------------------------------------
# Fetch and execute a script from GitHub
# --------------------------------------------
FAILED_SCRIPTS=()

run_remote_script() {
  local script_name="$1"
  local url="$RAW_BASE/scripts/$script_name"

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
# Run the tablet profile in order
# --------------------------------------------
for script in "${TABLET_SCRIPTS[@]}"; do
  run_remote_script "$script"
done

echo "==============================="
if [[ ${#FAILED_SCRIPTS[@]} -gt 0 ]]; then
  echo "⚠️  Setup finished with FAILURES: ${FAILED_SCRIPTS[*]}"
  echo "   Re-run a failed step with:"
  echo "   curl -fsSL $RAW_BASE/scripts/<name> | sudo APPLIANCE_URL='$TARGET_DISPLAY' bash"
else
  echo "🎯 Tablet setup complete!"
fi
echo "   Kiosk URL:  $TARGET_DISPLAY"
echo "   Reboot to enter kiosk mode:  sudo reboot"
echo "   Logs saved to: $LOG_DIR"
echo "==============================="
