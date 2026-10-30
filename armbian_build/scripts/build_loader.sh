#!/bin/bash
# Build the Armbian loader squashfs for system_<slot>: busybox + kobra-abctl + e2fsck with their
# uClibc libraries, taken from ShedNaja's Buildroot output, and armbian_build/loader/init.
#   bash armbian_build/scripts/build_loader.sh      # -> build/armbian/loader.squashfs
# Environment: BR_OUT (default ~/kobra/rootfs-out, run tools/build_rootfs.sh first).
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    envs=(); for v in BR_OUT; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/armbian_build/scripts/build_loader.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=${BR_OUT:-$HOME/kobra/rootfs-out}/target
OUT=$ROOT/build/armbian
[ -x "$T/bin/busybox" ] || { echo "no Buildroot target in $T (tools/build_rootfs.sh)" >&2; exit 1; }

S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S"/{bin,sbin,usr/sbin,lib,dev,proc,sys,mnt/useremain,newroot}

cp -a "$T/bin/busybox" "$S/bin/"
for a in sh mount umount mkdir cat grep basename dirname sleep sync reboot chroot pivot_root uname echo mv printf \
		dd od tr sha256sum cp ls gzip tar sed rm wc; do
	ln -s busybox "$S/bin/$a"
done
cp -a "$T/usr/sbin/kobra-abctl" "$S/usr/sbin/"
cp -a "$T/sbin/e2fsck" "$S/sbin/"
install -m 755 "$ROOT/armbian_build/loader/init" "$S/sbin/init"

# shared libraries the three binaries need, recursively, with their symlinks
need() { readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'; }
todo="$S/bin/busybox $S/usr/sbin/kobra-abctl $S/sbin/e2fsck"
while [ -n "$todo" ]; do
	next=""
	for f in $todo; do
		for l in $(need "$f"); do
			[ -e "$S/lib/$l" ] && continue
			src=$(readlink -f "$T/lib/$l" 2>/dev/null || true); [ -f "$src" ] || src=$(readlink -f "$T/usr/lib/$l")
			[ -f "$src" ] || { echo "library $l not found in $T" >&2; exit 1; }
			cp -a "$src" "$S/lib/"; [ "$(basename "$src")" = "$l" ] || ln -s "$(basename "$src")" "$S/lib/$l"
			next="$next $S/lib/$l"
		done
	done
	todo=$next
done
# program interpreter (/lib/ld-uClibc.so.0 -> .so.1 -> real file)
interp=$(readelf -l "$S/bin/busybox" | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
[ -e "$S$interp" ] || ln -s "$(basename "$(readlink -f "$T$interp")")" "$S$interp"

mkdir -p "$OUT"
rm -f "$OUT/loader.squashfs"
mksquashfs "$S" "$OUT/loader.squashfs" -comp xz -all-root -noappend -quiet
(cd "$OUT" && sha256sum loader.squashfs > loader.squashfs.sha256)
echo "loader: $(stat -c %s "$OUT/loader.squashfs") B"; (cd "$S" && find . -type f -o -type l | sort | tr '\n' ' '); echo
