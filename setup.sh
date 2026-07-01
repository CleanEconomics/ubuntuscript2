#!/usr/bin/env bash
set -e

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

# --------------------------------------------
# Detect parent run directory (from install.sh)
# --------------------------------------------
if [[ -n "$INSTALL_RUN_DIR" && -d "$INSTALL_RUN_DIR" ]]; then
  LOG_DIR="$INSTALL_RUN_DIR"
else
  # fallback if run standalone
  LOG_DIR="$HOME/setup_logs/$(date +'%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$LOG_DIR"
fi

LOG_FILE="$LOG_DIR/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================="
echo "  🧰 Remote Ubuntu Setup"
echo "==============================="
echo "📁 Logging to: $LOG_FILE"
echo "==============================="

# --------------------------------------------
# Function to fetch and execute a script from GitHub
# --------------------------------------------
run_remote_script() {
  local script_name="$1"
  local url="$RAW_BASE/scripts/$script_name"

  # individual script log inside same folder
  local log_name="${script_name%.sh}.log"
  local script_log="$LOG_DIR/$log_name"

  echo "▶️  Running $script_name ..."
  echo "📄 Logging to: $script_log"

  {
    echo "===== START $script_name $(date) ====="
    curl -fsSL "$url" | bash
    echo "===== END $script_name $(date) ====="
  } > >(tee -a "$script_log" "$LOG_FILE") 2>&1

  echo "✅ Finished $script_name"
  echo ""
}

# --------------------------------------------
# Run all numbered scripts in order
# --------------------------------------------
SCRIPT_LIST=$(curl -fsSL "https://api.github.com/repos/$REPO/contents/scripts?ref=$BRANCH" \
  | grep '"name":' | cut -d '"' -f 4 | grep '^[0-9][0-9]_.*\.sh' | sort)

for script in $SCRIPT_LIST; do
  run_remote_script "$script"
done

echo "==============================="
echo "🎯 Setup complete!"
echo "Logs saved to: $LOG_DIR"
echo "==============================="
