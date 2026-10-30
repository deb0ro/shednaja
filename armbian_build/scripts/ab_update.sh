#!/usr/bin/env bash
# A/B updates of the Armbian root on the TEST BOARD, from the PC (Git Bash). See userpatches/overlay/usr/local/sbin/kobra-ab.
#   bash armbian_build/scripts/ab_update.sh <ip> status
#   bash armbian_build/scripts/ab_update.sh <ip> loader [--write]   once: A/B loader into the running
#        system slot + kobra-ab/kobra-bootok onto the board, reboot (the loader renames root -> root_a)
#   bash armbian_build/scripts/ab_update.sh <ip> boot [--write]     build/armbian/boot.img into the running
#        boot slot (the base kernel; the old slot is saved to build/armbian/ first), no reboot. Kernel
#        updates normally come with the root (the loader kexecs the root's kernel), this is the rare case.
#   bash armbian_build/scripts/ab_update.sh <ip> install [--write]  build/armbian/rootfs-trixie.tar.zst
#        into the other root slot; the board reboots into it, kobra-bootok confirms it, else rollback
# Environment: KNOWN_HOSTS (default keys/known_hosts_armbian).
set -euo pipefail
IP=${1:?usage: ab_update.sh <ip> status|loader|boot|install [--write]}; CMD=${2:-status}; WRITE=${3:-}
REPO=/d/KobraS1_OpenFW
W=$(cd "$(dirname "$0")/../.." && pwd)
A=$W/build/armbian
O=$W/armbian_build/userpatches/overlay/usr/local/sbin
KH=${KNOWN_HOSTS:-$REPO/keys/known_hosts_armbian}
SSH=(ssh -i "$REPO/keys/kobra_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
     -o ServerAliveInterval=15 -o UserKnownHostsFile="$KH" "root@$IP")
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

info=$("${SSH[@]}" 'echo "cid=$(cat /sys/block/mmcblk0/device/cid)"; . /etc/os-release; echo "id=$ID"
  echo "root=$(findmnt -n -o SOURCE /)"; echo "cmdline_root=$(tr " " "\n" < /proc/cmdline | sed -n "s/^root=//p")"')
grep -q 'cid=d6010330384133393110bedbd1e15b6f' <<< "$info" || die "not the test board (eMMC CID)"
grep -q '^id=debian' <<< "$info" || die "board does not run the Armbian (Debian) root"
root=$(sed -n 's/^root=//p' <<< "$info")
case "$root" in */armbian/root\]|*/armbian/root_a\]|*/armbian/root_b\]) ;; *) die "unexpected root $root" ;; esac

case "$CMD" in
status)
	echo "$info"
	"${SSH[@]}" '[ -x /usr/local/sbin/kobra-ab ] && kobra-ab status; kobra-abctl display' ;;
loader)
	(cd "$A" && sha256sum -c --quiet loader.squashfs.sha256) || die "loader checksum (scripts/build_loader.sh)"
	sys=$(sed -n 's/^cmdline_root=//p' <<< "$info")
	case "$sys" in /dev/mmcblk0p8) part=system_a ;; /dev/mmcblk0p9) part=system_b ;; *) die "running slot unknown ($sys)" ;; esac
	log "plan: loader.squashfs -> $part (the slot running now), kobra-ab + kobra-bootok -> /usr/local/sbin, reboot"
	[ "$WRITE" = --write ] || { log "dry run, nothing written (add --write)"; exit 0; }
	for f in kobra-ab kobra-bootok; do
		"${SSH[@]}" "cat > /usr/local/sbin/$f.new && chmod 755 /usr/local/sbin/$f.new && mv /usr/local/sbin/$f.new /usr/local/sbin/$f" < "$O/$f"
	done
	"${SSH[@]}" 'cat > /tmp/loader.squashfs' < "$A/loader.squashfs"
	want=$(cut -d' ' -f1 "$A/loader.squashfs.sha256")
	"${SSH[@]}" "set -e; [ \"\$(sha256sum /tmp/loader.squashfs | cut -d' ' -f1)\" = $want ]
	  umount -l /mnt 2>/dev/null || true      # the previous loader (old root after pivot_root)
	  dd if=/tmp/loader.squashfs of=/dev/disk/by-partname/$part bs=64k conv=fsync status=none
	  sync; echo 3 > /proc/sys/vm/drop_caches
	  [ \"\$(head -c \$(stat -c %s /tmp/loader.squashfs) /dev/disk/by-partname/$part | sha256sum | cut -d' ' -f1)\" = $want ]
	  echo '$part written and verified'; rm /tmp/loader.squashfs; systemctl reboot" || true
	log "rebooting; the loader renames /useremain/armbian/root to root_a on this boot" ;;
boot)
	(cd "$A" && grep ' boot.img$' SHA256SUMS | sha256sum -c --quiet) || die "boot.img checksum (scripts/pack_boot.sh)"
	sys=$(sed -n 's/^cmdline_root=//p' <<< "$info")
	case "$sys" in /dev/mmcblk0p8) part=boot_a ;; /dev/mmcblk0p9) part=boot_b ;; *) die "running slot unknown ($sys)" ;; esac
	bak=$A/${part}_before_$(date +%Y%m%d-%H%M%S).img
	log "plan: save $part -> $(basename "$bak"), boot.img -> $part (the slot running now), no reboot"
	[ "$WRITE" = --write ] || { log "dry run, nothing written (add --write)"; exit 0; }
	"${SSH[@]}" "cat /dev/disk/by-partname/$part" > "$bak"
	[ "$(stat -c %s "$bak")" -eq 16777216 ] || die "backup of $part incomplete ($bak)"
	"${SSH[@]}" 'cat > /tmp/boot.img' < "$A/boot.img"
	want=$(grep ' boot.img$' "$A/SHA256SUMS" | cut -d' ' -f1)
	"${SSH[@]}" "set -e; [ \"\$(sha256sum /tmp/boot.img | cut -d' ' -f1)\" = $want ]
	  dd if=/tmp/boot.img of=/dev/disk/by-partname/$part bs=64k conv=fsync status=none
	  sync; echo 3 > /proc/sys/vm/drop_caches
	  [ \"\$(head -c \$(stat -c %s /tmp/boot.img) /dev/disk/by-partname/$part | sha256sum | cut -d' ' -f1)\" = $want ]
	  rm /tmp/boot.img; echo '$part written and verified (active on the next boot)'" ;;
install)
	(cd "$A" && sha256sum -c --quiet rootfs-trixie.tar.zst.sha256) || die "rootfs checksum"
	case "$root" in */armbian/root\]) die "still the single root: run 'loader --write' first" ;; esac
	"${SSH[@]}" 'kobra-ab status'
	[ "$WRITE" = --write ] || { log "dry run, nothing written (add --write)"; exit 0; }
	log "streaming the root into the other slot (~670 MB unpacked)"
	wpath="/mnt/$(echo "${A:1:1}" | tr 'A-Z' 'a-z')${A:2}"
	MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -- zstd -dc "$wpath/rootfs-trixie.tar.zst" | "${SSH[@]}" 'kobra-ab install -' || true
	log "rebooting into the new root; kobra-bootok confirms it, otherwise the loader rolls back after 3 boots" ;;
*) die "unknown command $CMD" ;;
esac
