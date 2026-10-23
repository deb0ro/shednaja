#!/usr/bin/env bash
# Write a kernel FIT into the INACTIVE boot slot of a Kobra S1 host board over SSH and
# make that slot active for the next boot (A/B retry mode -> automatic fallback).
#
#   bash tools/flash_boot_slot.sh <board-ip> <boot.img>            # dry run: checks only
#   bash tools/flash_boot_slot.sh <board-ip> <boot.img> --write    # really write + switch slot
#
# Development tool from before the installer: runs only against the stock firmware, and
# refuses to touch the slot the board is currently running from.
set -euo pipefail
cd "$(dirname "$0")/.."
IP="$1"; IMG="$2"; MODE="${3:-}"
SSH=(ssh -i keys/kobra_ed25519 -o BatchMode=yes -o UserKnownHostsFile=keys/known_hosts -o LogLevel=ERROR "root@$IP")

[ -f "$IMG" ] || { echo "no image $IMG"; exit 1; }
SIZE=$(stat -c %s "$IMG")
MD5=$(md5sum "$IMG" | cut -d' ' -f1)

# Only from the stock firmware (SSH via Rinkhals): on a board running ShedNaja the inactive
# slot holds stock, which this would overwrite. ShedNaja updates itself (kobra-update).
if "${SSH[@]}" 'grep -q "^ID=shednaja" /etc/os-release' 2>/dev/null; then
    echo "the board runs ShedNaja: its inactive slot is the stock firmware - refusing"
    echo "(update ShedNaja with kobra-update, see docs/update.md)"; exit 1
fi
"${SSH[@]}" 'command -v rk_ota' >/dev/null 2>&1 || { echo "no rk_ota on the board - not the stock firmware, refusing"; exit 1; }
root=$("${SSH[@]}" 'cat /proc/cmdline' | tr ' ' '\n' | sed -n 's#^root=/dev/mmcblk0p##p')
case "$root" in
  8) cur=a; other=b ;;
  9) cur=b; other=a ;;
  *) echo "unknown root partition p$root – aborting"; exit 1 ;;
esac
echo "running slot: $cur (root=p$root) -> target slot: boot_$other"
"${SSH[@]}" "rk_ota --misc=display 2>&1 | grep -E 'slot|priority|tries|successful'" || true

part_size=$("${SSH[@]}" "blockdev --getsize64 /dev/block/by-name/boot_$other 2>/dev/null || echo \$(( \$(cat /sys/class/block/\$(basename \$(readlink -f /dev/block/by-name/boot_$other))/size) * 512 ))")
echo "image $SIZE B, boot_$other partition $part_size B, md5 $MD5"
[ "$SIZE" -le "$part_size" ] || { echo "image larger than partition"; exit 1; }

mkdir -p dumps
"${SSH[@]}" "dd if=/dev/block/by-name/boot_$other bs=64k 2>/dev/null" > "dumps/boot_${other}_before_flash_$(date +%Y%m%d_%H%M%S).img"
echo "saved current boot_$other to dumps/"

if [ "$MODE" != "--write" ]; then echo "dry run only – add --write to flash"; exit 0; fi

"${SSH[@]}" "cat > /tmp/boot_new.img" < "$IMG"
"${SSH[@]}" "md5sum /tmp/boot_new.img" | grep -q "$MD5" || { echo "upload md5 mismatch"; exit 1; }
"${SSH[@]}" "dd if=/tmp/boot_new.img of=/dev/block/by-name/boot_$other bs=64k conv=fsync 2>&1 && sync"
back=$("${SSH[@]}" "dd if=/dev/block/by-name/boot_$other bs=$SIZE count=1 iflag=fullblock 2>/dev/null | md5sum" | cut -d' ' -f1 || true)
if [ "$back" != "$MD5" ]; then
  back=$("${SSH[@]}" "head -c $SIZE /dev/block/by-name/boot_$other | md5sum" | cut -d' ' -f1)
fi
[ "$back" = "$MD5" ] || { echo "readback md5 mismatch ($back) – NOT switching slot"; exit 1; }
echo "boot_$other written and verified"

"${SSH[@]}" "rk_ota --misc=other --mode=retry 2>&1 | tail -5; rk_ota --misc=display 2>&1 | grep -E 'slot|priority|tries|successful'"
echo "Slot $other is set for the next boot. Start the UART logger (115200) on J1, then reboot the board."
