#!/usr/bin/env bash
set -e

LOG_DIR="$HOME/setup_logs"
LOG_FILE="$LOG_DIR/setup-$(date +'%Y%m%d-%H%M').log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "📁 Logging to: $LOG_FILE"
