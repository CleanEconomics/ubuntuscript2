#!/usr/bin/env bash
set -e
echo "🖼️ Setting wallpaper..."

# Wallpaper URL and filename
WALLPAPER_URL="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/background2.png"

# Detect the GUI user (never root). SUDO_USER is the reliable one under
# `curl | sudo bash`; logname often fails in GUI terminals. Last resort: the
# first regular account.
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || who | awk '{print $1; exit}')}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
  REAL_USER="$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')"
fi
if [[ -z "$REAL_USER" ]]; then
  echo "⚠️  Could not determine a GUI user — skipping wallpaper."
  exit 0
fi
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
WALLPAPER_PATH="$USER_HOME/Pictures/ubuntu-background.png"
USER_ID=$(id -u "$REAL_USER")

# Ensure Pictures folder exists
sudo -u "$REAL_USER" mkdir -p "$USER_HOME/Pictures"

# Download wallpaper (as user, to their home)
echo "⬇️  Downloading wallpaper..."
if sudo -u "$REAL_USER" curl -fsSL "$WALLPAPER_URL" -o "$WALLPAPER_PATH"; then
  echo "✅ Wallpaper downloaded to $WALLPAPER_PATH"
else
  echo "⚠️  Failed to download wallpaper from $WALLPAPER_URL"
  exit 0
fi

# Apply wallpaper using user's DBus session
if command -v gsettings >/dev/null 2>&1; then
  echo "🎨 Applying wallpaper via gsettings (as $REAL_USER)..."
  sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER_PATH" || true
  sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_PATH" || true
  echo "✅ Wallpaper applied successfully."
else
  echo "⚙️  GNOME desktop not detected — skipping wallpaper setup."
fi
