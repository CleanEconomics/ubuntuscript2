#!/usr/bin/env bash
set -euo pipefail

# tablet_tweaks.sh
# ---------------------------------------------------------------------------
# Tablet-specific hardening for kiosk viewer devices. Run by tablet-setup.sh
# (deliberately NOT numbered so the full IPC setup.sh doesn't pick it up).
#
#   - Auto-rotation ON by default: screen AND touch follow how the tablet is
#     held (requires iio-sensor-proxy, installed here). For wall-mounted
#     units, freeze it instead with:  LOCK_ROTATION=1 ./tablet_tweaks.sh
#   - Keeps the on-screen keyboard AVAILABLE (no physical keyboard — portal
#     text fields must pop the OSK)
#   - No notification banners over the kiosk
#   - Suspend is impossible: power button ignored, sleep targets masked
#   - No screen dimming on battery
#   - Removes the GNOME first-login welcome tour
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

echo "==============================="
echo " 📱 Applying tablet kiosk tweaks"
echo "==============================="

# --- Auto-elevate to root (works for ./file and curl|bash) -------------------
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  if [[ -r "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" == *.sh ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  exec sudo -E bash -c "curl -fsSL '$RAW_BASE/scripts/tablet_tweaks.sh' | bash"
fi

# --- 1. System-wide GNOME settings (dconf) ------------------------------------
# Auto-rotation needs the sensor daemon; harmless if no accelerometer exists.
apt install -y iio-sensor-proxy 2>/dev/null || true

# LOCK_ROTATION=1 freezes the current orientation (wall mounts); default 0
# lets screen + touch follow the accelerometer. Setting BOOT_ROTATION (a fixed
# mount) implies the lock unless LOCK_ROTATION=0 is passed explicitly.
ORIENTATION_LOCK="false"
if [[ "${LOCK_ROTATION:-}" == "1" ]]; then
  ORIENTATION_LOCK="true"
elif [[ -z "${LOCK_ROTATION:-}" && -n "${BOOT_ROTATION:-}" ]]; then
  ORIENTATION_LOCK="true"
fi

echo "🖥️  Writing system-wide GNOME tablet settings (rotation lock: $ORIENTATION_LOCK)..."
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
if [[ ! -f /etc/dconf/profile/user ]]; then
  printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
  echo 'system-db:local' >> /etc/dconf/profile/user
fi

cat > /etc/dconf/db/local.d/01-tablet-kiosk <<EOF
[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=$ORIENTATION_LOCK

[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true

[org/gnome/desktop/notifications]
show-banners=false

[org/gnome/settings-daemon/plugins/power]
power-button-action='nothing'
idle-dim=false
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
EOF
dconf update
if [[ "$ORIENTATION_LOCK" == "true" ]]; then
  echo "✅ rotation LOCKED (LOCK_ROTATION=1), OSK on, banners off, power/idle hardened"
else
  echo "✅ auto-rotation ON (screen + touch follow the tablet), OSK on, banners off, power/idle hardened"
fi

# --- 2. Make suspend impossible at the OS level --------------------------------
echo "🔌 Masking suspend/sleep targets and power keys..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/60-tablet-kiosk.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
EOF
for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  systemctl mask "$unit" 2>/dev/null || true
done
echo "✅ device can only be powered off by holding the power button (firmware)"

# --- 3. Remove the GNOME first-login welcome tour ------------------------------
apt purge -y gnome-initial-setup 2>/dev/null || true

# --- 4. Fixed boot orientation (BOOT_ROTATION=left|right|inverted|normal) ------
# Sets the panel orientation at the KERNEL level, so the boot splash, the
# login screen, the GNOME session, AND the touch mapping all come up rotated
# together. left = portrait with the top toward the tablet's left edge; if
# yours lands upside down, use right instead.
if [[ -n "${BOOT_ROTATION:-}" ]]; then
  ORIENT=""; FBROT=0
  case "$BOOT_ROTATION" in
    left)     ORIENT="left_side_up";  FBROT=3 ;;
    right)    ORIENT="right_side_up"; FBROT=1 ;;
    inverted) ORIENT="upside_down";   FBROT=2 ;;
    normal)   ORIENT="normal";        FBROT=0 ;;
    *) echo "⚠️  BOOT_ROTATION must be left, right, inverted, or normal — skipping." ;;
  esac
  if [[ -n "$ORIENT" ]]; then
    # Find the internal panel's DRM connector (eDP/DSI/LVDS preferred).
    CONN=""
    for d in /sys/class/drm/card*-*; do
      [[ -f "$d/status" ]] || continue
      grep -qx connected "$d/status" || continue
      name="${d##*/}"; name="${name#*-}"
      case "$name" in
        eDP*|DSI*|LVDS*) CONN="$name"; break ;;
      esac
      if [[ -z "$CONN" ]]; then CONN="$name"; fi
    done
    if [[ -z "$CONN" ]]; then
      echo "⚠️  No connected display connector found — skipping boot rotation."
    else
      echo "🔄 Rotating display at boot: $CONN -> $ORIENT (splash + login + session + touch)..."
      sed -i -E 's/ ?video=[^ "]*panel_orientation[^ "]*//g; s/ ?fbcon=rotate:[0-9]//g' /etc/default/grub
      sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)\"|\1\2 video=$CONN:panel_orientation=$ORIENT fbcon=rotate:$FBROT\"|" /etc/default/grub
      if grep -q "panel_orientation=$ORIENT" /etc/default/grub; then
        update-grub
        echo "✅ Boot orientation set (video=$CONN:panel_orientation=$ORIENT)"
      else
        echo "⚠️  Could not edit GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub — boot rotation not applied."
      fi
    fi
  fi
fi

# --- 5. Optional touchscreen calibration ---------------------------------------
# Some tablet models have the touch sensor mirrored vs the panel. Pass
# TOUCH_FLIP=x|y|xy or TOUCH_ROTATE=90|270 to bake in the fix (see
# scripts/touch_fix.sh for the corner test that picks the right value).
if [[ -n "${TOUCH_FLIP:-}" || -n "${TOUCH_ROTATE:-}" ]]; then
  echo "🖐  Applying touchscreen calibration (flip=${TOUCH_FLIP:-} rotate=${TOUCH_ROTATE:-})..."
  curl -fsSL "$RAW_BASE/scripts/touch_fix.sh" -o /tmp/touch_fix.sh
  FLIP="${TOUCH_FLIP:-}" ROTATE="${TOUCH_ROTATE:-}" bash /tmp/touch_fix.sh \
    || echo "⚠️  Touch calibration failed — run scripts/touch_fix.sh manually."
fi

echo ""
echo "==============================="
echo "✅ Tablet tweaks applied"
if [[ "$ORIENTATION_LOCK" == "true" ]]; then
  echo "   Rotation:  LOCKED to current orientation (wall-mount mode)"
else
  echo "   Rotation:  automatic — screen and touch follow how the tablet is held"
fi
echo "   Keyboard:  on-screen keyboard enabled for portal inputs"
echo "   Suspend:   disabled at GNOME + systemd level"
echo "==============================="
