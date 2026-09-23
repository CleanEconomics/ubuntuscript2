#!/usr/bin/env bash
# kbfix.sh — bring an already-set-up kiosk tablet's keyboard handling up to
# date: Onboard touch keyboard, Chrome under X11 (so USB and touch keyboards
# type into the dashboard), USB autosuspend off. Then reboots.
# Short name on purpose: it has to be typed on the on-screen keyboard, which
# makes symbols hard. From a terminal on the tablet:
#   wget raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/kbfix.sh
#   sudo bash kbfix.sh
# It re-runs the current 08_kiosk.sh and tablet_tweaks.sh with the dashboard
# address already saved on this tablet, so nothing else has to be typed.
# Safe to run more than once.
set -u

RAW_BASE="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main"
LAUNCHER=/opt/kiosk/start-kiosk.sh

if [[ $EUID -ne 0 ]]; then
  echo "Run it with sudo:  sudo bash kbfix.sh"
  exit 1
fi

# The launcher stores the dashboard address as URL="${KIOSK_URL:-<address>}".
URL=""
if [[ -f "$LAUNCHER" ]]; then
  URL="$(sed -n 's/^URL="\${KIOSK_URL:-\(.*\)}"$/\1/p' "$LAUNCHER" | head -n1)"
fi
if [[ -z "$URL" ]]; then
  echo "❌ No kiosk address found in $LAUNCHER — run the full tablet setup instead."
  exit 1
fi
echo "🌐 Dashboard: $URL"

KIOSK_USER="${SUDO_USER:-}"
if [[ -z "$KIOSK_USER" || "$KIOSK_USER" == "root" ]]; then
  KIOSK_USER="$(stat -c %U "$LAUNCHER")"
fi

status=0
curl -fsSL "$RAW_BASE/scripts/08_kiosk.sh" | KIOSK_URL="$URL" KIOSK_USER="$KIOSK_USER" bash || status=1
curl -fsSL "$RAW_BASE/scripts/tablet_tweaks.sh" | bash || status=1

if [[ $status -ne 0 ]]; then
  echo "⚠️  A step failed — scroll up for the error. Not rebooting."
  exit 1
fi
echo "✅ Done. Rebooting in 5 seconds..."
sleep 5
reboot
