#!/usr/bin/env bash
# Replace the Debian root of a board that already runs the Armbian test install (slot with the loader).
#   bash armbian_build/scripts/update_rootfs.sh <ip>            # dry run: checks only
#   bash armbian_build/scripts/update_rootfs.sh <ip> --write    # unpack, swap, reboot
# Unpacks build/armbian/rootfs-trixie.tar.zst into /useremain/armbian/root.new, carries over
# root's SSH key, the SSH host keys, /etc/machine-id (same DHCP lease, same known_hosts) and the
# key-only sshd drop-in, then root -> root.old (previous one deleted), root.new -> root, reboot.
# The running root stays mounted until the reboot (the bind mount follows the renamed directory).
# Data outside the root (/useremain/armbian/shednaja, Lite's files, stock) is not touched.
# Back: mv root.old root on the board (or from stock) and reboot.
set -euo pipefail
IP=${1:?usage: update_rootfs.sh <ip> [--write]}; WRITE=${2:-}
REPO=/d/KobraS1_OpenFW
W=$(cd "$(dirname "$0")/../.." && pwd)
A=$W/build/armbian
KH=${KNOWN_HOSTS:-$REPO/keys/known_hosts_armbian}
SSH=(ssh -i "$REPO/keys/kobra_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
     -o ServerAliveInterval=15 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new "root@$IP")
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

(cd "$A" && sha256sum -c --quiet rootfs-trixie.tar.zst.sha256) || die "rootfs checksum"
info=$("${SSH[@]}" 'echo "cid=$(cat /sys/block/mmcblk0/device/cid)"; . /etc/os-release; echo "id=$ID"
  echo "root=$(findmnt -n -o SOURCE /)"; echo "free_kb=$(df -k --output=avail /useremain | tail -1 | tr -d " ")"')
echo "$info"
grep -q 'cid=d6010330384133393110bedbd1e15b6f' <<< "$info" || die "not the test board (eMMC CID)"
grep -q '^id=debian' <<< "$info" || die "board does not run the Armbian (Debian) root"
grep -q 'root=/dev/mmcblk0p17\[/armbian/root\]' <<< "$info" || die "root is not /useremain/armbian/root"
[ "$(grep -o 'free_kb=[0-9]*' <<< "$info" | cut -d= -f2)" -gt 1048576 ] || die "less than 1 GiB free on useremain"
[ "$WRITE" = --write ] || { log "dry run, nothing written (add --write)"; exit 0; }

log "unpack into /useremain/armbian/root.new"
wpath="/mnt/$(echo "${A:1:1}" | tr 'A-Z' 'a-z')${A:2}"
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -- zstd -dc "$wpath/rootfs-trixie.tar.zst" \
  | "${SSH[@]}" 'set -e; rm -rf /useremain/armbian/root.new; mkdir -p /useremain/armbian/root.new
      tar -x --numeric-owner --xattrs --xattrs-include="*" -f - -C /useremain/armbian/root.new; sync'

log "carry over access and identity, swap, reboot"
"${SSH[@]}" 'set -e; N=/useremain/armbian/root.new
  mkdir -p $N/root/.ssh && chmod 700 $N/root/.ssh
  cp -a /root/.ssh/authorized_keys $N/root/.ssh/
  mkdir -p $N/etc/dropbear; for f in /etc/dropbear/dropbear_*_host_key /etc/ssh/ssh_host_*; do [ -f $f ] && cp -a $f $N$f; done
  [ -d $N/etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d/10-kobra-test.conf $N/etc/ssh/sshd_config.d/ || true
  cp -a /etc/machine-id $N/etc/machine-id
  rm -f $N/root/.not_logged_in_yet
  rm -f $N/etc/systemd/system/multi-user.target.wants/armbian-firstrun.service   # would regenerate the host keys

  [ -e $N/sbin/init ] || [ -L $N/sbin/init ]
  rm -rf /useremain/armbian/root.old
  mv /useremain/armbian/root /useremain/armbian/root.old
  mv $N /useremain/armbian/root
  sync; ls /useremain/armbian; systemctl reboot' || true
log "rebooting; the old root is /useremain/armbian/root.old"
