#!/usr/bin/env bash
# Pack a ShedNaja update bundle for kobra-update (on the printer) / a USB stick.
#
#   bash tools/make_update_bundle.sh                       # boot + system from build/
#   bash tools/make_update_bundle.sh --system build/rootfs/rootfs.squashfs   # only some
#   options: --boot FILE  --oem FILE  --system FILE  --out FILE
#   bash tools/make_update_bundle.sh --rootfs build/armbian/rootfs-trixie.tar.zst   # Armbian
#        (packed as rootfs.tar.gz: stock's and Lite's busybox tar have gzip, not zstd)
#        (+ --boot build/armbian/boot.img / --system build/armbian/loader.squashfs when the
#        base kernel or the loader changed) -> build/update/shednaja-armbian-update-<id>.tar
#   --armbian  mark a bundle without rootfs (only boot/system) as one for the Armbian variant
#   Manifest line variant=armbian for those; kobra-update refuses a bundle for the other
#   variant unless --to-lite / --to-armbian is given.
#
# Output: build/update/shednaja-update-<build_id>.tar (uncompressed tar: manifest +
# boot.img / oem.img / system.img). Install: copy it to the printer and run
# "kobra-update <file>", or put it in the root folder of a FAT/exFAT USB stick and reboot.
# See docs/update.md.
set -euo pipefail
cd "$(dirname "$0")/.."
declare -A SRC=()
OUT=""
ARMBIAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --boot|--oem|--system|--rootfs) SRC[${1#--}]="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --armbian) ARMBIAN=1 ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done
if [ ${#SRC[@]} -eq 0 ]; then
    # no oem: ShedNaja does not use the oem partition (stock's stays), and oem_ours.img is
    # Anycubic/Rockchip userspace that releases must not carry; --oem for development
    SRC=([boot]=build/kernel/boot.img [system]=build/rootfs/rootfs.squashfs)
fi
# build id of the rootfs build (with "+devkey" for a development build), else git
BID=$(cat build/rootfs/BUILD_ID 2>/dev/null || git describe --always --dirty 2>/dev/null || echo unknown)
NAME=shednaja-update
[ -n "${SRC[rootfs]:-}" ] && ARMBIAN=1
if [ "$ARMBIAN" = 1 ]; then
    # the Armbian variant: its own name (USB sticks), build id from git
    [ -z "${SRC[oem]:-}" ] || { echo "the Armbian variant does not use the oem partition"; exit 1; }
    # (git does not work everywhere, e.g. a worktree seen from WSL: then the rootfs sha256)
    NAME=shednaja-armbian-update
    BID=$(git describe --always --dirty 2>/dev/null ||
        echo "armbian-$(cat "${SRC[rootfs]:-${SRC[boot]:-${SRC[system]}}}" | sha256sum | cut -c1-12)")
fi
OUT=${OUT:-build/update/$NAME-$BID.tar}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{
    echo "format=1"
    echo "build_id=$BID"
    echo "created=$(date -u +%FT%TZ)"
    if [ "$ARMBIAN" = 1 ]; then echo "variant=armbian"; fi
} > "$W/manifest"
img() { [ "$1" = rootfs ] && echo rootfs.tar.gz || echo "$1.img"; }
# rootfs first: kobra-update installs in manifest order, the root before the base kernel/loader
for part in rootfs boot oem system; do
    f=${SRC[$part]:-}; [ -n "$f" ] || continue
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
    if [ "$part" = rootfs ] && [ "${f%.zst}" != "$f" ]; then
        # gzip, not zstd: stock's and Lite's busybox tar unpack only plain tar and gzip
        zstd -dc "$f" | gzip -6 > "$W/rootfs.tar.gz"; f=$W/rootfs.tar.gz
    else
        cp "$f" "$W/$(img "$part")"
    fi
    echo "image $part $(img "$part") $(stat -c %s "$f") $(sha256sum "$f" | cut -d' ' -f1)" >> "$W/manifest"
done
mkdir -p "$(dirname "$OUT")"
files=(manifest); for part in rootfs boot oem system; do [ -f "$W/$(img "$part")" ] && files+=("$(img "$part")"); done
tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$OUT" -C "$W" "${files[@]}"
cat "$W/manifest"
ls -l "$OUT"; sha256sum "$OUT"
