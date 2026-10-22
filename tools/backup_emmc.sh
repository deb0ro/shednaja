#!/usr/bin/env bash
# Read-only backup of the Kobra S1 eMMC partitions over SSH (everything except useremain).
#   bash tools/backup_emmc.sh [printer-ip]
# Writes dumps/emmc_<timestamp>/<name>.img plus md5 check against the printer.
set -euo pipefail
cd "$(dirname "$0")/.."
IP="${1:?usage: backup_emmc.sh <printer-ip>}"
SSH=(ssh -i keys/kobra_ed25519 -o BatchMode=yes -o UserKnownHostsFile=keys/known_hosts -o LogLevel=ERROR "root@$IP")
PARTS=(env idblock uboot_a uboot_b misc boot_a boot_b system_a system_b oem_a oem_b userdata ac_lib_a ac_lib_b ac_app_a ac_app_b)
OUT="dumps/emmc_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

"${SSH[@]}" 'cat /proc/partitions; echo; cat /proc/cmdline; echo; cat /sys/block/mmcblk0/device/cid' > "$OUT/layout.txt"
# first 64 KB of the raw disk (GPT/MBR area, before env) and the gap up to idblock
"${SSH[@]}" 'dd if=/dev/mmcblk0 bs=32k count=1 2>/dev/null' > "$OUT/raw_head_0-32K.img"

: > "$OUT/md5.txt"
bad=0
for p in "${PARTS[@]}"; do
  start=$(date +%s)
  "${SSH[@]}" "dd if=/dev/block/by-name/$p bs=64k 2>/dev/null" > "$OUT/$p.img"
  remote=$("${SSH[@]}" "md5sum /dev/block/by-name/$p" | cut -d' ' -f1)
  local_=$(md5sum "$OUT/$p.img" | cut -d' ' -f1)
  size=$(stat -c %s "$OUT/$p.img")
  status=OK; [ -n "$remote" ] && [ "$remote" = "$local_" ] || { status=MISMATCH; bad=$((bad + 1)); }
  printf '%-10s %10d B  %3ds  %s  %s\n' "$p" "$size" $(( $(date +%s) - start )) "$local_" "$status" | tee -a "$OUT/md5.txt"
done
if [ $bad != 0 ]; then
  echo "FAILED: $bad partition(s) do not match the printer - this backup is NOT usable for a restore: $OUT"
  exit 1
fi
echo "Done: $OUT (all partitions verified)"
