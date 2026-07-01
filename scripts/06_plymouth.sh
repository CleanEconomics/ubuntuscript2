#!/usr/bin/env bash
echo "🎨 Installing Plymouth theme..."
sudo apt install -y plymouth plymouth-themes
THEME_NAME="client-brand"
THEME_DIR="/usr/share/plymouth/themes/$THEME_NAME"
THEME_REPO_URL="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/client-brand"

sudo mkdir -p "$THEME_DIR"
sudo curl -fsSL "$THEME_REPO_URL/$THEME_NAME.plymouth" -o "$THEME_DIR/$THEME_NAME.plymouth"
sudo curl -fsSL "$THEME_REPO_URL/$THEME_NAME.script" -o "$THEME_DIR/$THEME_NAME.script"
sudo curl -fsSL "$THEME_REPO_URL/logo.png" -o "$THEME_DIR/logo.png"
sudo curl -fsSL "$THEME_REPO_URL/background.png" -o "$THEME_DIR/background.png"


sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$THEME_DIR/$THEME_NAME.plymouth" 100
sudo update-alternatives --set default.plymouth "$THEME_DIR/$THEME_NAME.plymouth"
sudo update-initramfs -u

