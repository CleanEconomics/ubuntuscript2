#!/usr/bin/env bash
# kbfix.sh — USB keyboard/mouse fix for an already-set-up kiosk tablet.
# Short name on purpose: it has to be typed on the on-screen keyboard, which
# makes symbols hard. From a terminal on the tablet:
#   wget raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/kbfix.sh
#   sudo bash kbfix.sh
#
# 1. Removes Chrome's Wayland IME flags from the kiosk launcher, so a USB
#    keyboard types straight into the dashboard instead of through GNOME's
#    input method (which was swallowing keystrokes).
# 2. Turns off USB autosuspend (usbcore.autosuspend=-1), so USB keyboards and
#    mice aren't powered down and left dead.
# Then reboots. Safe to run more than once.
set -u

if [[ $EUID -ne 0 ]]; then
  echo "Run it with sudo:  sudo bash kbfix.sh"
  exit 1
fi

LAUNCHER=/opt/kiosk/start-kiosk.sh
if [[ -f "$LAUNCHER" ]]; then
  sed -i 's/ --enable-wayland-ime --wayland-text-input-version=3//' "$LAUNCHER"
  if grep -q -- '--enable-wayland-ime' "$LAUNCHER"; then
    echo "⚠️  Could not remove the IME flags from $LAUNCHER"
  else
    echo "✅ Kiosk Chrome: keyboard input goes straight to the page"
  fi
else
  echo "⚠️  $LAUNCHER not found — kiosk not set up? Skipping the Chrome part."
fi

if grep -q 'usbcore.autosuspend' /etc/default/grub; then
  echo "✅ USB autosuspend already off"
else
  sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")/\1usbcore.autosuspend=-1 /' /etc/default/grub
  if grep -q 'usbcore.autosuspend=-1' /etc/default/grub; then
    update-grub
    echo "✅ USB autosuspend off (applies after reboot)"
  else
    echo "⚠️  Could not edit /etc/default/grub — USB autosuspend unchanged"
  fi
fi

echo "Rebooting in 5 seconds..."
sleep 5
reboot
