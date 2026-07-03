#!/usr/bin/env bash
set -euo pipefail

# 10_disable_updates.sh
# ---------------------------------------------------------------------------
# Turn OFF all automatic/unattended updates. This is an OT appliance: updates
# happen deliberately during a maintenance window, never on their own.
#
# Disables:
#   - apt: unattended-upgrades + apt-daily timers + all periodic tasks
#   - snap: refreshes held indefinitely (covers the Chromium fallback)
#   - GNOME Software: background download/install of updates
#   - update-notifier popups and the "new Ubuntu release" upgrade prompt
#
# Google Chrome updates via apt on Linux, so with apt automation off it only
# updates when you run `apt upgrade` yourself. To also pin it against manual
# upgrades: apt-mark hold google-chrome-stable
#
# To update the machine later (maintenance window):
#   sudo apt update && sudo apt upgrade   # apt is still fully usable manually
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

echo "==============================="
echo " 🔒 Disabling automatic updates"
echo "==============================="

# --- Auto-elevate to root (works for ./file and curl|bash) -------------------
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  if [[ -r "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" == *.sh ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  exec sudo -E bash -c "curl -fsSL '$RAW_BASE/scripts/10_disable_updates.sh' | bash"
fi

# --- 1. APT: kill periodic tasks + unattended-upgrades -----------------------
echo "📦 Disabling apt periodic tasks and unattended-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
# Belt and braces: a later file wins over anything else that sets these.
cat > /etc/apt/apt.conf.d/99-appliance-no-auto-updates <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

for unit in apt-daily.timer apt-daily-upgrade.timer \
            apt-daily.service apt-daily-upgrade.service \
            unattended-upgrades.service fwupd-refresh.timer; do
  systemctl stop "$unit"    2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  systemctl mask "$unit"    2>/dev/null || true
done
echo "✅ apt automation off (apt-daily timers masked)"

# --- 2. Snap: hold all refreshes indefinitely --------------------------------
if command -v snap >/dev/null 2>&1; then
  echo "📦 Holding snap refreshes..."
  if snap refresh --hold >/dev/null 2>&1; then
    echo "✅ snap refreshes held indefinitely"
  else
    # Older snapd without --hold: defer as far as it allows and warn.
    snap set system refresh.hold="2099-01-01T00:00:00Z" 2>/dev/null || true
    echo "⚠️  snapd too old for a permanent hold — set a far-future refresh.hold instead"
  fi
fi

# --- 3. GNOME Software / update-notifier (system-wide dconf) ------------------
if command -v dconf >/dev/null 2>&1; then
  echo "🖥️  Disabling GNOME Software auto-updates and notifications..."
  mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
  if [[ ! -f /etc/dconf/profile/user ]]; then
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
  elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
    echo 'system-db:local' >> /etc/dconf/profile/user
  fi
  cat > /etc/dconf/db/local.d/00-no-auto-updates <<'EOF'
[org/gnome/software]
download-updates=false
allow-updates=false

[com/ubuntu/update-notifier]
no-show-notifications=true
EOF
  dconf update
  echo "✅ GNOME update downloads/notifications off"
fi

# --- 4. Never prompt for release upgrades (e.g. 24.04 -> 26.04) ---------------
if [[ -f /etc/update-manager/release-upgrades ]]; then
  sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades
else
  mkdir -p /etc/update-manager
  printf '[DEFAULT]\nPrompt=never\n' > /etc/update-manager/release-upgrades
fi
echo "✅ release-upgrade prompts off"

echo ""
echo "==============================="
echo "✅ Automatic updates disabled"
echo "   apt:   unattended-upgrades + daily timers masked"
echo "   snap:  refreshes held"
echo "   GNOME: update downloads + notifications off"
echo "   To update deliberately: sudo apt update && sudo apt upgrade"
echo "==============================="
