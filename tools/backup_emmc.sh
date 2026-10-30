#!/usr/bin/env bash
# Read-only backup of the Kobra S1 eMMC partitions over SSH, from stock with Rinkhals or from
# ShedNaja (Lite or Armbian). Nothing on the printer is written. docs/backup.md is the guide.
#   bash tools/backup_emmc.sh <printer-ip> [--useremain]
#     --useremain   also the data partition (print files, configs; ~6 GB, ~25 min over Wi-Fi;
#                   it is mounted and changes while it is read, see docs/backup.md)
#   KEY=<private key>        SSH key to use (default: your SSH agent / ~/.ssh keys, else password)
#   KNOWN_HOSTS=<file>       known_hosts file (default: your normal one)
# Writes dumps/emmc_<timestamp>/<name>.img plus md5.txt, checked against the printer.
set -euo pipefail
cd "$(dirname "$0")/.."
IP="${1:?usage: backup_emmc.sh <printer-ip> [--useremain]}"
PARTS=(env idblock uboot_a uboot_b misc boot_a boot_b system_a system_b oem_a oem_b userdata ac_lib_a ac_lib_b ac_app_a ac_app_b)
[ "${2:-}" = --useremain ] && PARTS+=(useremain)
OUT="dumps/emmc_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

# One SSH connection for all reads where the client can share it (asks for the password once);
# otherwise every step asks again.
CTL=$(mktemp -u "${TMPDIR:-/tmp}/kobra-backup-XXXXXX")
SSH=(ssh -o ConnectTimeout=10 -o LogLevel=ERROR -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=120)
[ -n "${KEY:-}" ] && SSH+=(-i "$KEY")
[ -n "${KNOWN_HOSTS:-}" ] && SSH+=(-o "UserKnownHostsFile=$KNOWN_HOSTS")
SSH+=("root@$IP")
trap 'ssh -o "ControlPath=$CTL" -O exit "root@$IP" 2>/dev/null || true' EXIT

"${SSH[@]}" 'cat /proc/partitions; echo; cat /proc/cmdline; echo; cat /sys/block/mmcblk0/device/cid; echo; cat /useremain/dev/version 2>/dev/null' > "$OUT/layout.txt"
# first 32 KB of the raw disk (before env)
"${SSH[@]}" 'dd if=/dev/mmcblk0 bs=32k count=1 2>/dev/null' > "$OUT/raw_head_0-32K.img"

: > "$OUT/md5.txt"
bad=0
for p in "${PARTS[@]}"; do
  start=$(date +%s)
  "${SSH[@]}" "dd if=/dev/block/by-name/$p bs=64k 2>/dev/null" > "$OUT/$p.img"
  remote=$("${SSH[@]}" "md5sum /dev/block/by-name/$p" | cut -d' ' -f1)
  local_=$(md5sum "$OUT/$p.img" | cut -d' ' -f1)
  size=$(stat -c %s "$OUT/$p.img")
  status=OK
  if [ -z "$remote" ] || [ "$remote" != "$local_" ]; then
    # useremain is mounted and written while it is read: a different sum is expected there
    if [ "$p" = useremain ]; then status="CHANGED (mounted, expected)"; else status=MISMATCH; bad=$((bad + 1)); fi
  fi
  printf '%-10s %10d B  %3ds  %s  %s\n' "$p" "$size" $(( $(date +%s) - start )) "$local_" "$status" | tee -a "$OUT/md5.txt"
done
if [ $bad != 0 ]; then
  echo "FAILED: $bad partition(s) do not match the printer - this backup is NOT usable for a restore: $OUT"
  exit 1
fi
echo "Done: $OUT (all partitions verified)"
