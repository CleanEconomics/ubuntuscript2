#!/usr/bin/env bash
# kiosk-firstboot.sh — one-time kiosk provisioning after a USB autoinstall.
# Installed by the USB stick's autoinstall (usb/make-kiosk-usb.ps1) as
# /usr/local/sbin/kiosk-firstboot.sh and run by kiosk-firstboot.service on the
# first boot. It waits for the internet, runs the normal tablet setup
# (tablet.sh, always the latest from GitHub) with the settings the stick was
# made with, then disables itself and reboots into the kiosk.
# If there is no internet yet, it exits and tries again on the next boot.
# Progress: /var/log/kiosk-firstboot.log
set -u
LOG=/var/log/kiosk-firstboot.log
exec >>"$LOG" 2>&1
echo "=== kiosk first boot: $(date)"

ENV_FILE=/etc/kiosk-firstboot.env
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${APPLIANCE_URL:?APPLIANCE_URL missing from $ENV_FILE}"
KIOSK_USER="${KIOSK_USER:-operator}"
RAW_BASE="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main"

echo "Waiting for internet (Wi-Fi or Ethernet)..."
online=0
for _ in $(seq 1 180); do
  if curl -fsI --max-time 5 "$RAW_BASE/tablet.sh" >/dev/null 2>&1; then online=1; break; fi
  sleep 5
done
if [[ $online -ne 1 ]]; then
  echo "No internet after 15 minutes — will try again on the next boot."
  exit 1
fi

# Ubuntu's own background updates grab the apt lock on a fresh install; stop
# them so the setup's apt calls don't fail. 10_disable_updates.sh turns them
# off for good during the setup.
systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
  apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
for _ in $(seq 1 120); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  sleep 5
done

if ! curl -fsSL "$RAW_BASE/tablet.sh" -o /root/tablet.sh; then
  echo "Could not download tablet.sh — will try again on the next boot."
  exit 1
fi

# The setup expects to be run with sudo by the kiosk user; mimic that.
export HOME=/root SUDO_USER="$KIOSK_USER" KIOSK_USER APPLIANCE_URL
[[ -n "${RUSTDESK_PW:-}" ]] && export RUSTDESK_PW
[[ -n "${SPLASH_ROTATE:-}" ]] && export SPLASH_ROTATE
bash /root/tablet.sh
echo "=== setup finished (exit $?): $(date)"

systemctl disable kiosk-firstboot.service
echo "Rebooting into the kiosk..."
sleep 5
systemctl reboot
