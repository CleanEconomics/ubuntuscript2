#!/bin/bash
# prep-disk.sh - get the tablet's internal drive ready for a clean Ubuntu install.
# Fixes "Mount failed: /dev/sdaX @ /target/" by releasing and wiping the old
# install before the installer partitions the drive.
#
#   Automatic install: run by autoinstall early-commands (make-kiosk-usb.ps1) as
#                      KIOSK_MODEL='S101AYCR110' bash /cdrom/kiosk/prep-disk.sh auto
#   By hand (Try Ubuntu session terminal):  sudo bash /cdrom/kiosk/prep-disk.sh
#
# In auto mode it POWERS THE TABLET OFF (erasing nothing) if the tablet is not
# the expected model or if it can't tell which drive is the internal one. So if
# the tablet switches itself off within a minute of the install starting, that's why.
# KIOSK_MODEL='' skips the model check.
set -u
MODE="${1:-manual}"
MODEL="${KIOSK_MODEL-S101AYCR110}"
LOG=/tmp/prep-disk.log
exec > >(tee -a "$LOG") 2>&1
echo "=== prep-disk ($MODE) $(date)"

stop() {
  echo "STOP: $*"
  if [[ "$MODE" == "auto" ]]; then sleep 10; poweroff -f; fi
  exit 1
}

ids="$(cat /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version 2>/dev/null | tr '\n' ' ')"
echo "Tablet reports: $ids"
if [[ -n "$MODEL" && "$ids" != *"$MODEL"* ]]; then
  if [[ "$MODE" == "auto" ]]; then stop "not an $MODEL tablet - refusing to erase it."; fi
  echo "WARNING: this doesn't report as an $MODEL."
fi

# The disk the installer booted from (the USB stick) must never be touched.
src="$(findmnt -no SOURCE /cdrom 2>/dev/null | head -n1)"
stick=""
[[ -n "$src" ]] && stick="/dev/$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
echo "USB stick: ${stick:-unknown}"

# Internal drive: a real, non-removable disk of 100 GB or more that isn't the stick.
mapfile -t cands < <(lsblk -dbnpo NAME,TYPE,RM,SIZE,TRAN | awk -v s="$stick" \
  '$2=="disk" && $3=="0" && $4>=100000000000 && $1!=s && $5!="usb" {print $1}')
if [[ ${#cands[@]} -ne 1 ]]; then
  lsblk -dpo NAME,SIZE,TYPE,RM,TRAN,MODEL
  stop "expected exactly one internal drive, found ${#cands[@]}: ${cands[*]:-none}"
fi
disk="${cands[0]}"
echo "Internal drive: $disk ($(lsblk -dno SIZE,MODEL "$disk"))"

if [[ "$MODE" != "auto" ]]; then
  lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINTS "$disk"
  read -r -p "Type ERASE to wipe $disk: " ans
  [[ "$ans" == "ERASE" ]] || { echo "Nothing changed."; exit 1; }
fi

# Let go of everything on the drive.
swapoff -a 2>/dev/null
umount -R /target 2>/dev/null
for p in $(lsblk -lnpo NAME "$disk" | tac); do
  for m in $(lsblk -lnpo MOUNTPOINTS "$p" 2>/dev/null); do umount -l "$m" 2>/dev/null; done
done
vgchange -an >/dev/null 2>&1
command -v mdadm >/dev/null && mdadm --stop --scan >/dev/null 2>&1

# Wipe signatures and the partition table (start and end of the drive).
for p in $(lsblk -lnpo NAME "$disk" | tail -n +2); do wipefs -af "$p" >/dev/null 2>&1; done
wipefs -af "$disk"
command -v sgdisk >/dev/null && sgdisk --zap-all "$disk" >/dev/null 2>&1
sectors=$(blockdev --getsz "$disk")
dd if=/dev/zero of="$disk" bs=1M count=16 conv=fsync status=none
dd if=/dev/zero of="$disk" bs=512 seek=$(( sectors - 32768 )) count=32768 conv=fsync status=none
partprobe "$disk" 2>/dev/null; blockdev --rereadpt "$disk" 2>/dev/null
udevadm settle
echo "Wiped. What's left on $disk:"
lsblk -po NAME,SIZE,FSTYPE "$disk"
echo "=== prep-disk done"
[[ "$MODE" == "auto" ]] || echo "Now open 'Install Ubuntu' from the desktop and install as usual."
exit 0
