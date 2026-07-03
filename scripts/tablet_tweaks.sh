#!/usr/bin/env bash
set -euo pipefail

# tablet_tweaks.sh
# ---------------------------------------------------------------------------
# Tablet-specific hardening for kiosk viewer devices. Run by tablet-setup.sh
# (deliberately NOT numbered so the full IPC setup.sh doesn't pick it up).
#
#   - Locks screen auto-rotation (warehouse tablets get bumped and flipped)
#   - Keeps the on-screen keyboard AVAILABLE (no physical keyboard — portal
#     text fields must pop the OSK)
#   - No notification banners over the kiosk
#   - Suspend is impossible: power button ignored, sleep targets masked
#   - No screen dimming on battery
#   - Removes the GNOME first-login welcome tour
#
# If a tablet is mounted portrait, rotate once in Settings -> Displays
# (the lock only stops the accelerometer from flipping it afterwards).
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
echo "🖥️  Writing system-wide GNOME tablet settings..."
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
if [[ ! -f /etc/dconf/profile/user ]]; then
  printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
  echo 'system-db:local' >> /etc/dconf/profile/user
fi

cat > /etc/dconf/db/local.d/01-tablet-kiosk <<'EOF'
[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=true

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
echo "✅ rotation locked, OSK on, banners off, power/idle hardened"

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

echo ""
echo "==============================="
echo "✅ Tablet tweaks applied"
echo "   Rotation:  locked (rotate once in Settings->Displays if portrait)"
echo "   Keyboard:  on-screen keyboard enabled for portal inputs"
echo "   Suspend:   disabled at GNOME + systemd level"
echo "==============================="
