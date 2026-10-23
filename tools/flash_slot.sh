#!/usr/bin/env bash
# Write a boot image (and optionally an oem image and/or a system rootfs) into the
# INACTIVE A/B slot of a Kobra S1 host board over SSH, verify by readback md5, then make
# that slot active for the next boot (retry mode -> SPL falls back after failed boots).
#
#   bash tools/flash_slot.sh <ip> <boot.img|-> [oem.img] [--system rootfs.squashfs]           # dry run
#   bash tools/flash_slot.sh <ip> <boot.img|-> [oem.img] [--system rootfs.squashfs] --write   # write
#
# "-" as boot image skips boot_<slot>. The slot switch uses the stock rk_ota.
#
# Development tool from before the installer: runs only against the stock firmware, and
# refuses to touch the slot the board is currently running from. Before writing it saves
# the current contents of the target partitions to dumps/.
set -euo pipefail
cd "$(dirname "$0")/.."
IP="$1"; BOOT="$2"; shift 2
OEM=""; SYSTEM=""; MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --write) MODE=--write ;;
        --system) SYSTEM="$2"; shift ;;
        *) OEM="$1" ;;
    esac
    shift
done
SSH=(ssh -i keys/kobra_ed25519 -o BatchMode=yes -o UserKnownHostsFile=keys/known_hosts -o LogLevel=ERROR "root@$IP")

root=$("${SSH[@]}" 'cat /proc/cmdline' | tr ' ' '\n' | sed -n 's#^root=/dev/mmcblk0p##p')
case "$root" in
  8) cur=a; tgt=b ;;
  9) cur=b; tgt=a ;;
  *) echo "unknown root partition p$root - aborting"; exit 1 ;;
esac
echo "running slot: $cur (root=p$root) -> target slot: $tgt"
# Only from the stock firmware (SSH via Rinkhals): on a board running ShedNaja the inactive
# slot holds stock, which this would overwrite. ShedNaja updates itself (kobra-update).
if "${SSH[@]}" 'grep -q "^ID=shednaja" /etc/os-release' 2>/dev/null; then
    echo "the board runs ShedNaja: its inactive slot is the stock firmware - refusing"
    echo "(update ShedNaja with kobra-update, see docs/update.md)"; exit 1
fi
"${SSH[@]}" 'command -v rk_ota' >/dev/null 2>&1 || { echo "no rk_ota on the board - not the stock firmware, refusing"; exit 1; }
AB_SHOW="rk_ota --misc=display 2>&1 | grep -E 'priority|tries|successful'"
AB_OTHER="rk_ota --misc=other --mode=retry 2>&1 | grep -E 'A/B'"
"${SSH[@]}" "$AB_SHOW" || true

declare -A IMG=()
[ "$BOOT" != "-" ] && IMG[boot]="$BOOT"
[ -n "$OEM" ] && IMG[oem]="$OEM"
[ -n "$SYSTEM" ] && IMG[system]="$SYSTEM"
[ ${#IMG[@]} -gt 0 ] || { echo "nothing to write"; exit 1; }
stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p dumps
for part in "${!IMG[@]}"; do
    f=${IMG[$part]}; [ -f "$f" ] || { echo "no image $f"; exit 1; }
    dev=/dev/block/by-name/${part}_$tgt
    size=$(stat -c %s "$f")
    psize=$("${SSH[@]}" "cat /sys/class/block/\$(basename \$(readlink -f $dev))/size")
    psize=$((psize * 512))
    echo "$part: $f ($size B, md5 $(md5sum "$f" | cut -d' ' -f1)) -> $dev ($psize B)"
    [ "$size" -le "$psize" ] || { echo "image larger than partition"; exit 1; }
    if "${SSH[@]}" "grep -q \"^\$(readlink -f $dev) \" /proc/mounts"; then
        echo "$dev is mounted on the board - refusing"; exit 1
    fi
    "${SSH[@]}" "dd if=$dev bs=64k 2>/dev/null" > "dumps/${part}_${tgt}_before_flash_${stamp}.img"
    echo "  saved current ${part}_$tgt to dumps/${part}_${tgt}_before_flash_${stamp}.img"
done

if [ "$MODE" != "--write" ]; then echo "dry run only - add --write to flash"; exit 0; fi

for part in "${!IMG[@]}"; do
    f=${IMG[$part]}; dev=/dev/block/by-name/${part}_$tgt
    size=$(stat -c %s "$f"); md5=$(md5sum "$f" | cut -d' ' -f1)
    "${SSH[@]}" "cat > /tmp/slot_$part.img" < "$f"
    "${SSH[@]}" "md5sum /tmp/slot_$part.img" | grep -q "$md5" || { echo "$part upload md5 mismatch"; exit 1; }
    "${SSH[@]}" "dd if=/tmp/slot_$part.img of=$dev bs=64k conv=fsync 2>/dev/null && sync && rm -f /tmp/slot_$part.img"
    back=$("${SSH[@]}" "head -c $size $dev | md5sum" | cut -d' ' -f1)
    [ "$back" = "$md5" ] || { echo "$part readback md5 mismatch ($back) - NOT switching slot"; exit 1; }
    echo "${part}_$tgt written and verified"
done

"${SSH[@]}" "$AB_OTHER; $AB_SHOW"
echo "Slot $tgt is set for the next boot. Start the console logger, then reboot the board."
