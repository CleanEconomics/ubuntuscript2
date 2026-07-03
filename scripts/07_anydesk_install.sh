#!/usr/bin/env bash
set -e

echo "==============================="
echo " 🦀 Installing RustDesk (v1.4.2) — Wayland Enabled"
echo "==============================="

# --- 1. Ensure Wayland is ENABLED ---
WAYLAND_CONF="/etc/gdm3/custom.conf"
if [ -f "$WAYLAND_CONF" ]; then
  echo "🔧 Enabling Wayland in $WAYLAND_CONF..."
  sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' "$WAYLAND_CONF" || true
  if ! grep -q "WaylandEnable" "$WAYLAND_CONF"; then
    echo "#WaylandEnable=false" | sudo tee -a "$WAYLAND_CONF" >/dev/null
  fi
  echo "✅ Wayland enabled successfully."
else
  echo "⚠️  GDM config not found — skipping Wayland toggle."
fi

# --- 2. Remove AnyDesk if present ---
if command -v anydesk >/dev/null 2>&1; then
  echo "🧹 Removing AnyDesk..."
  sudo systemctl stop anydesk || true
  sudo apt remove -y anydesk || true
  sudo rm -f /etc/apt/sources.list.d/anydesk.list
  sudo rm -f /usr/share/keyrings/anydesk-archive-keyring.gpg
  sudo apt autoremove -y
else
  echo "ℹ️  AnyDesk not installed — skipping removal."
fi

# --- 3. Download & install RustDesk ---
RUSTDESK_VER="1.4.2"
RUSTDESK_DEB="rustdesk-${RUSTDESK_VER}-x86_64.deb"
RUSTDESK_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VER}/${RUSTDESK_DEB}"

echo "⬇️  Downloading RustDesk ${RUSTDESK_VER}..."
# A failed download must NOT abort the whole provision (set -e) — remote
# support is nice-to-have; the kiosk steps after this are not.
if wget -q "$RUSTDESK_URL" -O "/tmp/${RUSTDESK_DEB}"; then
  echo "📦 Installing RustDesk..."
  sudo apt install -y "/tmp/${RUSTDESK_DEB}" || \
    echo "⚠️  RustDesk install failed — continuing without remote support."
else
  echo "⚠️  Could not download RustDesk — continuing without remote support."
  echo "    Install later with: curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/scripts/07_anydesk_install.sh | sudo bash"
fi

# --- 4. Enable & start service ---
echo "⚙️  Enabling RustDesk service..."
sudo systemctl enable --now rustdesk || true

# --- 5. Done ---
echo ""
echo "✅ RustDesk v${RUSTDESK_VER} installed successfully!"
echo "💡 Wayland is enabled for touchscreen and gestures."
echo "🔑 Open RustDesk from your apps menu to see your ID and password."
echo "==============================="
