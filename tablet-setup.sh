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
# Usage (change only the IP):
#   sudo APPLIANCE_IP=192.168.1.17 ./tablet-setup.sh && sudo reboot
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

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
echo "🌐 Appliance IP: ${APPLIANCE_IP:-192.168.1.17 (default)}"
echo "📁 Logging to:   $LOG_FILE"
echo "==============================="

# --------------------------------------------
# Fetch and execute a script from GitHub
# --------------------------------------------
run_remote_script() {
  local script_name="$1"
  local url="$RAW_BASE/scripts/$script_name"

  local log_name="${script_name%.sh}.log"
  local script_log="$LOG_DIR/$log_name"

  echo "▶️  Running $script_name ..."
  echo "📄 Logging to: $script_log"

  {
    echo "===== START $script_name $(date) ====="
    curl -fsSL "$url" | bash
    echo "===== END $script_name $(date) ====="
  } > >(tee -a "$script_log" "$LOG_FILE") 2>&1

  echo "✅ Finished $script_name"
  echo ""
}

# --------------------------------------------
# Run the tablet profile in order
# --------------------------------------------
for script in "${TABLET_SCRIPTS[@]}"; do
  run_remote_script "$script"
done

echo "==============================="
echo "🎯 Tablet setup complete!"
echo "   Kiosk URL:  http://${APPLIANCE_IP:-192.168.1.17}"
echo "   Reboot to enter kiosk mode:  sudo reboot"
echo "   Logs saved to: $LOG_DIR"
echo "==============================="
