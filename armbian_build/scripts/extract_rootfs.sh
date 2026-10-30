#!/bin/bash
# Take the root filesystem out of the Armbian image as a tarball for the directory on
# useremain (docs/research/armbian-rv1106.md, section 3). Nothing here touches a board.
#   wsl -d Ubuntu-24.04 -u root -- bash armbian_build/scripts/extract_rootfs.sh [image.img]
# Needs root (losetup/mount, file owners). Default image: the newest *.img in $AB/output/images/.
# Writes build/armbian/rootfs-<release>.tar.zst (+ .sha256, .packages.txt: Debian package versions)
# and build/armbian/rootfs-report.txt.
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    envs=(); for v in AB; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -u root -- env "${envs[@]}" bash "$wpath/armbian_build/scripts/extract_rootfs.sh" "$@" ;;
esac

[ "$(id -u)" = 0 ] || { echo "needs root (wsl -u root)" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AB=${AB:-/home/adam/kobra/armbian-build}
OUT=$ROOT/build/armbian

img=${1:-$(ls -t "$AB"/output/images/*.img 2>/dev/null | head -1)}
[ -f "$img" ] || { echo "no image (run scripts/build.sh)" >&2; exit 1; }
release=$(basename "$img" | grep -oE '_(trixie|forky|bookworm|noble|resolute)_' | tr -d _ || echo rootfs)

M=$(mktemp -d); dev=""
cleanup() { mountpoint -q "$M" && umount "$M"; [ -n "$dev" ] && losetup -d "$dev"; rmdir "$M"; }
trap cleanup EXIT

dev=$(losetup --find --show --read-only --partscan "$img")
part=""
for p in "$dev"p*; do
  [ "$(blkid -o value -s TYPE "$p" 2>/dev/null)" = ext4 ] && part=$p
done
[ -n "$part" ] || { echo "no ext4 partition in $img" >&2; lsblk "$dev" >&2; exit 1; }
mount -o ro "$part" "$M"

mkdir -p "$OUT"
tarball=$OUT/rootfs-$release.tar.zst
tar --numeric-owner --xattrs --xattrs-include='*' --acls -C "$M" -cpf - . | zstd -q -T0 -19 -o "$tarball" -f
(cd "$OUT" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256")
# Debian packages are not pinned (the build installs from the current trixie mirror): their exact
# versions go next to the tarball, to compare two builds or to repeat one from snapshot.debian.org
awk '/^Package: /{p=$2} /^Version: /{v=$2} /^$/{if (p) print p, v; p=v=""} END{if (p) print p, v}' \
	"$M/var/lib/dpkg/status" | sort > "$OUT/rootfs-$release.packages.txt"

{
  echo "image:    $(basename "$img")"
  echo "rootfs:   $part ($(blkid -o value -s TYPE "$part"))"
  echo "used:     $(du -sh --apparent-size "$M" | cut -f1) apparent, $(df -h --output=used "$M" | tail -1 | tr -d ' ') on the fs"
  echo "tarball:  $(basename "$tarball") $(du -h "$tarball" | cut -f1)"
  echo "os:       $(. "$M/etc/os-release"; echo "$PRETTY_NAME")"
  echo "kernel:   $(ls "$M/lib/modules")"
  echo "packages: $(grep -c '^Package:' "$M/var/lib/dpkg/status")"
  echo "libc:     $(ls "$M"/usr/lib/arm-linux-gnueabihf/libc.so.* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo "systemd:  $(awk '/^Package: /{p=$2} p=="systemd" && /^Version: /{print $2; exit}' "$M/var/lib/dpkg/status")"
  echo "firmware: $(du -sh "$M/usr/lib/firmware" 2>/dev/null | cut -f1)"
  echo "python3:  $(ls "$M"/usr/bin/python3.* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo
  echo "largest directories:"
  du -x --max-depth=2 -m "$M" 2>/dev/null | sort -rn | head -15
  echo
  echo "masked units: $(find "$M/etc/systemd/system" -maxdepth 1 -lname /dev/null -printf '%f ' )"
  echo "enabled units (multi-user + sysinit + timers):"
  for w in multi-user.target.wants sysinit.target.wants timers.target.wants getty.target.wants; do
    [ -d "$M/etc/systemd/system/$w" ] && ls "$M/etc/systemd/system/$w" | sed "s|^|  $w/|"
  done
  echo
  echo "kobra files:"
  for f in etc/modprobe.d/kobra-wifi.conf etc/modprobe.d/kobra-blacklist.conf etc/udev/rules.d/60-kobra-by-name.rules \
           etc/systemd/journald.conf.d/kobra.conf etc/systemd/network/20-wlan0.network etc/wpa_supplicant/wpa_supplicant-wlan0.conf; do
    if [ -e "$M/$f" ] || [ -L "$M/$f" ]; then echo "  ok      /$f"; else echo "  MISSING /$f"; fi
  done
  echo "  8723ds.ko: $(find "$M/lib/modules" -name 8723ds.ko | sed "s|$M||")"
  echo "  fstab:"; sed 's/^/    /' "$M/etc/fstab"
} | tee "$OUT/rootfs-report.txt"
