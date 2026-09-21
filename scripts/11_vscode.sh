#!/usr/bin/env bash
set -euo pipefail

# 11_vscode.sh
# ---------------------------------------------------------------------------
# Install Visual Studio Code from Microsoft's signed apt repo (with a direct
# .deb fallback). Runs in both the IPC and tablet profiles so a tech can edit
# the dashboard/scanner code on the device itself (over RustDesk, or with a
# keyboard on a bench unit).
#
# VS Code is NOT auto-started and never shows inside the kiosk. To work on
# the device: RustDesk in, then run  /opt/kiosk/dev-mode.sh  (written by
# 08_kiosk.sh) — it pauses the kiosk and opens a terminal + VS Code. Run
# /opt/kiosk/kiosk-mode.sh (or reboot) to go back to the kiosk.
# ---------------------------------------------------------------------------

echo "==============================="
echo " 🧑‍💻 Installing Visual Studio Code"
echo "==============================="

if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  exec sudo -E bash "$0" "$@"
fi

if command -v code >/dev/null 2>&1; then
  echo "ℹ️  VS Code already installed: $(code --version 2>/dev/null | head -1 || true)"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"   # amd64 or arm64
export DEBIAN_FRONTEND=noninteractive

install_via_repo() {
  apt install -y wget gpg apt-transport-https ca-certificates >/dev/null 2>&1 || true
  install -d -m 0755 /etc/apt/keyrings
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg 2>/dev/null || return 1
  chmod 0644 /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
  apt update -y || true
  apt install -y code
}

install_via_deb() {
  local url="https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-${ARCH/amd64/x64}"
  local deb="/tmp/vscode-${ARCH}.deb"
  echo "⬇️  Repo install failed — downloading .deb directly..."
  wget -qO "$deb" "$url" || return 1
  apt install -y "$deb" || { dpkg -i "$deb" || true; apt -f install -y || true; }
  rm -f "$deb"
  command -v code >/dev/null 2>&1
}

if install_via_repo || install_via_deb; then
  echo "✅ VS Code installed: $(code --version 2>/dev/null | head -1 || echo ok)"
  # No update nags on an appliance (apt automation is already off in step 10).
  mkdir -p /etc/skel/.config/Code/User
else
  echo "⚠️  VS Code install failed — continuing (not required for the kiosk)."
fi
echo "==============================="
