#!/usr/bin/env bash
set -e

# --- 1. Require or auto-elevate to sudo ---
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating privileges with sudo..."
  exec sudo bash "$0" "$@"
fi

# --- 2. Ensure curl is installed ---
if ! command -v curl >/dev/null 2>&1; then
  echo "⚙️  curl not found. Installing..."
  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  else
    echo "❌ Unable to install curl — unsupported package manager."
    exit 1
  fi
fi

# --- 3. Repo & paths ---
REPO="CleanEconomics/ubuntuscript2"
BRANCH="${1:-main}"   # optional branch argument
RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/setup.sh"

# Timestamped directory for each run
RUN_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BASE_DIR="/tmp/ubuntu-setup"
RUN_DIR="$BASE_DIR/$RUN_TIMESTAMP"

# --- 4. Prepare directories ---
mkdir -p "$RUN_DIR"

# --- 5. Logging setup ---
LOG_FILE="$RUN_DIR/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================="
echo "  🧰 Ubuntu Installer (remote)"
echo "==============================="
echo "📅 Run started: $RUN_TIMESTAMP"
echo "📁 Working directory: $RUN_DIR"
echo "🪵 Log file: $LOG_FILE"
echo "==============================="

# --- 6. Download setup.sh ---
SETUP_FILE="$RUN_DIR/setup.sh"
echo "⬇️  Downloading setup script from: $RAW_URL"
if curl -fsSL "$RAW_URL" -o "$SETUP_FILE"; then
  chmod +x "$SETUP_FILE"
else
  echo "❌ Failed to download setup script from $RAW_URL"
  exit 1
fi

# --- 7. Run setup.sh ---
echo "🚀 Executing setup.sh..."
INSTALL_RUN_DIR="$RUN_DIR" bash "$SETUP_FILE"

# --- 8. Post-run summary ---
echo ""
echo "==============================="
echo "✅ Setup complete!"
echo "🪵 Logs saved in: $RUN_DIR"
echo "==============================="
