#!/usr/bin/env bash
set -e

# -----------------------------------
# 🧰 Ubuntu Full Stack Setup with Logging
# -----------------------------------

LOG_DIR="$HOME/setup_logs"
LOG_FILE="$LOG_DIR/setup-$(date +'%Y%m%d-%H%M').log"
mkdir -p "$LOG_DIR"

# Redirect stdout (1) and stderr (2) to tee so it shows and logs
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================="
echo "  🧰 Ubuntu Full Stack Setup"
echo "  🕓 $(date)"
echo "  📁 Logging to: $LOG_FILE"
echo "==============================="

# Trap for any unexpected errors
trap 'echo "❌ ERROR: Command failed at line $LINENO. Check log: $LOG_FILE"' ERR

echo "==============================="
echo "  🧰 Ubuntu Full Stack Setup"
echo "==============================="

# Update & basic tools
echo "📦 Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y build-essential curl wget git unzip python3 python3-pip python3-venv python3-dev

# -------------------------------
# Node.js + npm + n
# -------------------------------
echo "🟢 Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g n
sudo n lts
hash -r

# -------------------------------
# React tooling
# -------------------------------
echo "⚛️ Installing React tooling..."
sudo npm install -g create-react-app vite

# -------------------------------
# Node-RED + PM2
# -------------------------------
echo "🔴 Installing Node-RED..."
sudo npm install -g --unsafe-perm node-red pm2
pm2 start $(which node-red) --name node-red
pm2 startup systemd -u $USER --hp $HOME
pm2 save

# -------------------------------
# Python packages
# -------------------------------
echo "🐍 Setting up Python environment..."
python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install paho-mqtt requests numpy pandas

# -------------------------------
# Docker + Compose
# -------------------------------
echo "🐳 Installing Docker..."
sudo apt install -y ca-certificates gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker <<EONG
docker --version
docker compose version
EONG

# -------------------------------
# Beremiz soft PLC runtime
# -------------------------------
echo "⚙️ Installing Beremiz (soft PLC)..."
if apt-cache show beremiz >/dev/null 2>&1; then
  sudo apt install -y beremiz
else
  echo "Beremiz not found in repo, building from source..."
  sudo apt install -y python3-wxgtk4.0 python3-lxml python3-pyro4 python3-zeroconf
  git clone https://github.com/beremiz/beremiz.git ~/beremiz || true
  echo "Run manually with: python3 ~/beremiz/Beremiz.py"
fi

# -------------------------------
# Version Summary
# -------------------------------
echo ""
echo "✅ INSTALLATION COMPLETE"
echo "-------------------------------"
node -v
npm -v
python3 --version
docker --version
docker compose version || true
echo "Node-RED is running via PM2 (port 1880)"
echo "-------------------------------"
echo "To launch Beremiz manually, run: beremiz &"
echo "To start a React app: npx create-react-app myapp"
echo "==============================="
echo "🎯 Done."



# -------------------------------
# 🖼️ Set Background Wallpaper
# -------------------------------

WALLPAPER_URL="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/refs/heads/main/background2.jpg"
WALLPAPER_PATH="$HOME/Pictures/ubuntu-background.jpg"

echo "🖼️ Setting background image..."

# Ensure Pictures directory exists
mkdir -p "$HOME/Pictures"

# Download wallpaper
if curl -fsSL "$WALLPAPER_URL" -o "$WALLPAPER_PATH"; then
  echo "Downloaded wallpaper to $WALLPAPER_PATH"
else
  echo "⚠️ Failed to download wallpaper. Skipping..."
  exit 0
fi

# Check if GNOME is running (for GUI systems)
if command -v gsettings >/dev/null 2>&1; then
  # Set both light and dark mode backgrounds
  gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER_PATH" || true
  gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_PATH" || true
  echo "✅ Wallpaper applied successfully."
else
  echo "⚙️ No GNOME desktop detected. Skipping wallpaper setup."
fi


# -------------------------------
# 🖥️ Plymouth Theme Installation
# -------------------------------
echo "🎨 Installing and setting up Plymouth theme..."

sudo apt install -y plymouth plymouth-themes

# Define theme name and paths
THEME_NAME="client-brand"
THEME_DIR="/usr/share/plymouth/themes/$THEME_NAME"
THEME_REPO_URL="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/plymouth-theme"

# Create theme directory
sudo mkdir -p "$THEME_DIR"

# Download theme files
echo "⬇️  Downloading theme files..."
sudo curl -fsSL "$THEME_REPO_URL/$THEME_NAME.plymouth" -o "$THEME_DIR/$THEME_NAME.plymouth"
sudo curl -fsSL "$THEME_REPO_URL/$THEME_NAME.script" -o "$THEME_DIR/$THEME_NAME.script"
sudo curl -fsSL "$THEME_REPO_URL/logo.png" -o "$THEME_DIR/logo.png"

# Verify files
if [ ! -f "$THEME_DIR/$THEME_NAME.plymouth" ]; then
  echo "⚠️  Plymouth theme download failed — skipping."
else
  echo "⚙️  Setting Plymouth theme..."
  sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$THEME_DIR/$THEME_NAME.plymouth" 100
  sudo update-alternatives --set default.plymouth "$THEME_DIR/$THEME_NAME.plymouth"
  sudo update-initramfs -u
  echo "✅ Plymouth theme applied: $THEME_NAME"
fi
