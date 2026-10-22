#!/usr/bin/env bash
set -euo pipefail

# 12_rfid.sh
# ---------------------------------------------------------------------------
# USB PN532 NFC/RFID reader as a "keyboard": tap a card and it types
#   RFID:<card number><Enter>
# into the dashboard, exactly like the barcode scanner. No dashboard or
# browser setup needed. Runs as the kiosk-rfid service (root, for the virtual
# keyboard), finds the reader by itself and copes with it being unplugged.
#
# Settings: /etc/kiosk-rfid.conf (PREFIX, FORMAT=hex|dec, SUFFIX, REPEAT_SEC,
# PORT). Change one, then: sudo systemctl restart kiosk-rfid
# Test (shows taps, types nothing):
#   sudo systemctl stop kiosk-rfid; sudo /opt/kiosk/rfid-wedge.py --test
# Log: journalctl -u kiosk-rfid -f
# Reader board: set its switches/jumpers to HSU (UART) mode.
# Reads 13.56 MHz cards (MIFARE, NFC tags/cards); not 125 kHz proximity badges.
# ---------------------------------------------------------------------------

REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

echo "==============================="
echo " 🪪 Installing the RFID reader (PN532) keyboard service"
echo "==============================="

if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  exec sudo -E bash -c "curl -fsSL '$RAW_BASE/scripts/12_rfid.sh' | bash"
fi

export DEBIAN_FRONTEND=noninteractive
apt install -y python3-serial python3-evdev >/dev/null 2>&1 \
  || apt install -y python3-serial python3-evdev

mkdir -p /opt/kiosk
curl -fsSL "$RAW_BASE/scripts/rfid-wedge.py" -o /opt/kiosk/rfid-wedge.py
chmod 755 /opt/kiosk/rfid-wedge.py

if [[ ! -f /etc/kiosk-rfid.conf ]]; then
  cat > /etc/kiosk-rfid.conf <<'CONF'
# kiosk RFID reader settings (sudo systemctl restart kiosk-rfid after a change)
# Typed on each tap: PREFIX + card number + SUFFIX
PREFIX=RFID:
# hex = card UID in uppercase hex (e.g. 04A1B2C3D4E5F6); dec = one decimal number
FORMAT=hex
# enter | tab | none
SUFFIX=enter
# a card left on the reader is typed once; again only after it's been away this long (seconds)
REPEAT_SEC=3
# auto, or a fixed port such as /dev/ttyUSB0
PORT=auto
CONF
fi

# Keep ModemManager from probing USB-serial adapters (it can grab the reader).
cat > /etc/udev/rules.d/72-kiosk-rfid.rules <<'RULES'
# Written by 12_rfid.sh: USB-serial chips used on PN532 boards; not modems.
ATTRS{idVendor}=="1a86", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="067b", ENV{ID_MM_DEVICE_IGNORE}="1"
RULES
udevadm control --reload-rules 2>/dev/null || true

cat > /etc/systemd/system/kiosk-rfid.service <<'UNIT'
[Unit]
Description=Kiosk RFID reader (PN532) typed as a keyboard
After=systemd-udev-settle.service

[Service]
ExecStart=/usr/bin/python3 /opt/kiosk/rfid-wedge.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable kiosk-rfid.service >/dev/null 2>&1
systemctl restart kiosk-rfid.service || true

echo "✅ RFID reader service installed (kiosk-rfid). Taps type: RFID:<card number> + Enter"
echo "   Settings: /etc/kiosk-rfid.conf   Log: journalctl -u kiosk-rfid -f"
