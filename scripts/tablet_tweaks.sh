#!/usr/bin/env bash
set -euo pipefail

# tablet_tweaks.sh
# ---------------------------------------------------------------------------
# Tablet-specific hardening for kiosk viewer devices. Run by tablet-setup.sh
# (deliberately NOT numbered so the full IPC setup.sh doesn't pick it up).
#
#   - Rotation LOCKED by default: kiosk tablets sit in one place, and a
#     tablet whose accelerometer is mounted differently than Linux assumes
#     flips the screen on its own a few seconds after boot. For a handheld
#     unit that should follow how it is held:  LOCK_ROTATION=0 ./tablet_tweaks.sh
#     (iio-sensor-proxy is installed either way).
#   - Keeps the on-screen keyboard AVAILABLE (no physical keyboard — portal
#     text fields must pop the OSK)
#   - No notification banners over the kiosk
#   - Suspend is impossible: power button ignored, sleep targets masked
#   - No screen dimming on battery
#   - Removes the GNOME first-login welcome tour
#   - Optional BOOT_ROTATION=left|right|inverted|normal fixes a panel mounted
#     rotated (splash + login + session + touch) and clears older, now
#     conflicting rotation/touch fixes — see section 4
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
# dconf-cli provides `dconf update` (not guaranteed on a minimal desktop).
apt install -y iio-sensor-proxy dconf-cli 2>/dev/null || true

# Rotation is locked by default (see header); LOCK_ROTATION=0 lets screen +
# touch follow the accelerometer instead.
ORIENTATION_LOCK="true"
if [[ "${LOCK_ROTATION:-}" == "0" ]]; then
  ORIENTATION_LOCK="false"
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
  echo "✅ rotation LOCKED (default; LOCK_ROTATION=0 for auto-rotate), OSK on, banners off, power/idle hardened"
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

# --- 3b. Remove Firefox (the kiosk uses Chrome only) ---------------------------
# On Ubuntu 24.04 Firefox is a snap; the apt "firefox" package only reinstalls
# the snap, so purge it, remove the snap, and pin apt so it can't come back.
echo "🦊 Removing Firefox..."
apt purge -y firefox 2>/dev/null || true
snap remove --purge firefox 2>/dev/null || true
cat > /etc/apt/preferences.d/no-firefox <<'EOF'
Package: firefox*
Pin: release *
Pin-Priority: -1
EOF
if command -v firefox >/dev/null 2>&1 || snap list firefox >/dev/null 2>&1; then
  echo "⚠️  Firefox is still installed — remove it with: sudo snap remove --purge firefox"
else
  echo "✅ Firefox removed (and blocked from reinstalling)"
fi

# --- 4. Fixed boot orientation (BOOT_ROTATION=left|right|inverted|normal) ------
# Sets the panel orientation at the KERNEL level, so the boot splash, the
# login screen, the GNOME session, AND the touch mapping all come up rotated
# together. left = portrait with the top toward the tablet's left edge; if
# yours lands upside down, use right instead.
#
# Only set it when the picture is wrong BEFORE any fix — judge by the boot
# splash or the installed system's login screen, NOT the Ubuntu installer
# (it follows the tilt sensor, so it can look right on an inverted panel).
# The S101AYCR110 needs left; tablet-setup.sh sets that by default.
# Forcing a value on a correct panel turns it sideways or upside down.
# Sideways needs left/right (90 deg); inverted (180) can never fix sideways.
#
# Because the kernel rotation already carries touch and the splash with it,
# earlier per-layer fixes would now double-correct. When BOOT_ROTATION is
# applied, this also clears: the touch_fix.sh udev rule, the rotate_fix.sh
# sensor hwdb, and saved GNOME monitors.xml rotations (backed up, not
# deleted). TOUCH_FLIP/TOUCH_ROTATE/ACCEL_FIX below re-add fixes if passed.
clear_stale_rotation_fixes() {
  local stamp f
  stamp="$(date +'%Y%m%d-%H%M%S')"

  if [[ -f /etc/udev/rules.d/99-kiosk-touch.rules ]]; then
    rm -f /etc/udev/rules.d/99-kiosk-touch.rules
    udevadm control --reload-rules 2>/dev/null || true
    echo "🧹 Removed old touch calibration (99-kiosk-touch.rules)"
  fi
  if [[ -f /etc/udev/hwdb.d/61-kiosk-sensor.hwdb ]]; then
    rm -f /etc/udev/hwdb.d/61-kiosk-sensor.hwdb
    systemd-hwdb update 2>/dev/null || true
    echo "🧹 Removed old accelerometer correction (61-kiosk-sensor.hwdb)"
  fi

  # A saved monitors.xml transform is applied ON TOP of the panel orientation,
  # which is how a correct BOOT_ROTATION still comes up sideways/upside down.
  for f in /home/*/.config/monitors.xml /root/.config/monitors.xml \
           /var/lib/gdm3/.config/monitors.xml; do
    [[ -f "$f" ]] || continue
    mv "$f" "$f.bak-$stamp"
    echo "🧹 Cleared saved display layout: $f (backup: $f.bak-$stamp)"
  done
}

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
        clear_stale_rotation_fixes
      else
        echo "⚠️  Could not edit GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub — boot rotation not applied."
      fi
    fi
  fi
fi

# --- 4b. Keep USB keyboards/mice powered ---------------------------------------
# USB autosuspend powers down idle USB devices; on these tablets a plugged-in
# keyboard or mouse can go dead and stay dead. usbcore.autosuspend=-1 turns
# it off. USB_AUTOSUSPEND=1 leaves the kernel default alone.
if [[ "${USB_AUTOSUSPEND:-0}" != "1" ]] && ! grep -q 'usbcore.autosuspend' /etc/default/grub; then
  sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")/\1usbcore.autosuspend=-1 /' /etc/default/grub
  if grep -q 'usbcore.autosuspend=-1' /etc/default/grub; then
    update-grub
    echo "✅ USB autosuspend off (keyboards/mice stay powered; applies after reboot)"
  else
    echo "⚠️  Could not edit /etc/default/grub — USB autosuspend unchanged."
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

# --- 6. Optional accelerometer correction (ACCEL_FIX=180|90|270) ---------------
# For models whose accelerometer is mounted rotated: auto-rotate flips the
# screen upside down (or 90 deg off) in every position a few seconds after
# boot. The fix is keyed to this hardware model via DMI.
if [[ -n "${ACCEL_FIX:-}" ]]; then
  echo "🧭 Applying accelerometer mount correction (MODE=$ACCEL_FIX)..."
  curl -fsSL "$RAW_BASE/scripts/rotate_fix.sh" -o /tmp/rotate_fix.sh
  MODE="$ACCEL_FIX" bash /tmp/rotate_fix.sh \
    || echo "⚠️  Accelerometer correction failed — run scripts/rotate_fix.sh manually."
fi

echo ""
echo "==============================="
echo "✅ Tablet tweaks applied"
if [[ "$ORIENTATION_LOCK" == "true" ]]; then
  echo "   Rotation:  LOCKED to current orientation (wall-mount mode)"
else
  echo "   Rotation:  automatic — screen and touch follow how the tablet is held"
fi
echo "   Keyboard:  Onboard pops up for portal inputs (08_kiosk.sh); USB autosuspend off"
echo "   Suspend:   disabled at GNOME + systemd level"
echo "==============================="
