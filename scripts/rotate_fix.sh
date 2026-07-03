#!/usr/bin/env bash
set -euo pipefail

# rotate_fix.sh
# ---------------------------------------------------------------------------
# Fix auto-rotation that reads the tablet's orientation WRONG — screen comes
# up upside down (or 90 degrees off) in EVERY position. Cause: this model's
# accelerometer is mounted differently than Linux assumes. This installs an
# ACCEL_MOUNT_MATRIX calibration for the device model.
#
#   screen is upside down          -> sudo MODE=180 bash rotate_fix.sh
#   screen is 90 deg clockwise off -> sudo MODE=90  bash rotate_fix.sh
#   screen is 90 deg counter off   -> sudo MODE=270 bash rotate_fix.sh
#   undo                           -> sudo MODE=none bash rotate_fix.sh
#
# Reboot after running. Applies to this hardware model (matched by DMI), so
# the same fix works identically on every unit of the same tablet.
# ---------------------------------------------------------------------------

HWDB_FILE="/etc/udev/hwdb.d/61-kiosk-sensor.hwdb"

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run with sudo:  sudo MODE=180 bash $0" >&2
  exit 1
fi

if [[ "${MODE:-}" == "none" ]]; then
  rm -f "$HWDB_FILE"
  systemd-hwdb update
  udevadm trigger 2>/dev/null || true
  echo "✅ Sensor calibration removed — reboot to apply."
  exit 0
fi

MATRIX=""
case "${MODE:-}" in
  180) MATRIX="-1, 0, 0; 0, -1, 0; 0, 0, 1" ;;
  90)  MATRIX="0, 1, 0; -1, 0, 0; 0, 0, 1" ;;
  270) MATRIX="0, -1, 0; 1, 0, 0; 0, 0, 1" ;;
  *)
    echo "❌ Set MODE to 180, 90, 270, or none:" >&2
    echo "   screen upside down in every position -> sudo MODE=180 bash $0" >&2
    exit 1 ;;
esac

SVN="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo '*')"
PN="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo '*')"
# hwdb match patterns glob; swap spaces for wildcards to stay safe.
SVN="${SVN// /*}"
PN="${PN// /*}"

echo "🧭 Model: $SVN / $PN"
echo "🧭 Accelerometer matrix: $MATRIX"

cat > "$HWDB_FILE" <<EOF
# Written by rotate_fix.sh — accelerometer mount correction for this model.
sensor:modalias:*:dmi:*svn${SVN}*pn${PN}*
 ACCEL_MOUNT_MATRIX=${MATRIX}
EOF

systemd-hwdb update
udevadm trigger 2>/dev/null || true
echo "✅ Calibration installed ($HWDB_FILE) — reboot to apply:  sudo reboot"
