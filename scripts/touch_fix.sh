#!/usr/bin/env bash
set -euo pipefail

# touch_fix.sh
# ---------------------------------------------------------------------------
# Fix a touchscreen whose input is mirrored/rotated relative to the display
# (touch one corner, cursor lands in another). Writes a libinput calibration
# matrix via udev — works on Wayland and X11, survives reboots.
#
# Pick the mode by touching the TOP-LEFT corner of the screen:
#   lands BOTTOM-RIGHT -> sudo FLIP=xy bash touch_fix.sh   (fully inverted)
#   lands TOP-RIGHT    -> sudo FLIP=x  bash touch_fix.sh   (left/right mirrored)
#   lands BOTTOM-LEFT  -> sudo FLIP=y  bash touch_fix.sh   (up/down mirrored)
#   lands rotated 90   -> sudo ROTATE=90 bash touch_fix.sh (or ROTATE=270)
#
# Undo:   sudo FLIP=none bash touch_fix.sh
# If detection picks the wrong device: TOUCH_NAME="Exact Device Name" ...
# Reboot after running.
# ---------------------------------------------------------------------------

RULE_FILE="/etc/udev/rules.d/99-kiosk-touch.rules"

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run with sudo:  sudo FLIP=xy bash $0" >&2
  exit 1
fi

# --- Undo mode ----------------------------------------------------------------
if [[ "${FLIP:-}" == "none" ]]; then
  rm -f "$RULE_FILE"
  udevadm control --reload-rules
  udevadm trigger
  echo "✅ Calibration removed — reboot to apply."
  exit 0
fi

# --- Pick the matrix -----------------------------------------------------------
MATRIX=""
case "${FLIP:-}" in
  x)  MATRIX="-1 0 1 0 1 0"  ;;
  y)  MATRIX="1 0 0 0 -1 1"  ;;
  xy) MATRIX="-1 0 1 0 -1 1" ;;
  "") ;;
  *)  echo "❌ FLIP must be x, y, xy, or none" >&2; exit 1 ;;
esac
case "${ROTATE:-}" in
  90)  MATRIX="0 -1 1 1 0 0" ;;
  270) MATRIX="0 1 0 -1 0 1" ;;
  "") ;;
  *)  echo "❌ ROTATE must be 90 or 270" >&2; exit 1 ;;
esac
if [[ -z "$MATRIX" ]]; then
  echo "❌ Tell it what to fix. Touch the TOP-LEFT corner of the screen:" >&2
  echo "   cursor lands bottom-right -> sudo FLIP=xy bash $0" >&2
  echo "   cursor lands top-right    -> sudo FLIP=x  bash $0" >&2
  echo "   cursor lands bottom-left  -> sudo FLIP=y  bash $0" >&2
  echo "   everything is rotated 90  -> sudo ROTATE=90 bash $0  (or ROTATE=270)" >&2
  exit 1
fi

# --- Find the touchscreen device name ------------------------------------------
NAME="${TOUCH_NAME:-}"
if [[ -z "$NAME" ]]; then
  NAME="$(grep -i '^N: Name=' /proc/bus/input/devices \
          | grep -iE 'touch|goodix|egalax|elan|ilitek|silead|hid.*multitouch' \
          | head -1 | sed 's/^N: Name="//; s/"$//')"
fi
if [[ -z "$NAME" ]]; then
  echo "❌ Could not auto-detect the touchscreen. List devices with:" >&2
  echo "   grep 'Name=' /proc/bus/input/devices" >&2
  echo "then re-run with: sudo TOUCH_NAME=\"Exact Name\" FLIP=... bash $0" >&2
  exit 1
fi

echo "🖐  Touchscreen: $NAME"
echo "🧭 Calibration matrix: $MATRIX"

cat > "$RULE_FILE" <<EOF
# Written by touch_fix.sh — touch input calibration for this tablet model.
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="$NAME", ENV{LIBINPUT_CALIBRATION_MATRIX}="$MATRIX"
EOF

udevadm control --reload-rules
udevadm trigger
echo "✅ Calibration installed ($RULE_FILE) — reboot to apply:  sudo reboot"
