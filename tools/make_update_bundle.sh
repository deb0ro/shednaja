#!/usr/bin/env bash
# Pack a ShedNaja update bundle for kobra-update (on the printer) / a USB stick.
#
#   bash tools/make_update_bundle.sh                       # boot + system from build/
#   bash tools/make_update_bundle.sh --system build/rootfs/rootfs.squashfs   # only some
#   options: --boot FILE  --oem FILE  --system FILE  --out FILE
#
# Output: build/update/shednaja-update-<build_id>.tar (uncompressed tar: manifest +
# boot.img / oem.img / system.img). Install: copy it to the printer and run
# "kobra-update <file>", or put it in the root folder of a FAT/exFAT USB stick and reboot.
# See docs/update.md.
set -euo pipefail
cd "$(dirname "$0")/.."
declare -A SRC=()
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --boot|--oem|--system) SRC[${1#--}]="$2"; shift ;;
        --out) OUT="$2"; shift ;;
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
OUT=${OUT:-build/update/shednaja-update-$BID.tar}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{
    echo "format=1"
    echo "build_id=$BID"
    echo "created=$(date -u +%FT%TZ)"
} > "$W/manifest"
for part in boot oem system; do
    f=${SRC[$part]:-}; [ -n "$f" ] || continue
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
    cp "$f" "$W/$part.img"
    echo "image $part $part.img $(stat -c %s "$f") $(sha256sum "$f" | cut -d' ' -f1)" >> "$W/manifest"
done
mkdir -p "$(dirname "$OUT")"
files=(manifest); for part in boot oem system; do [ -f "$W/$part.img" ] && files+=("$part.img"); done
tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$OUT" -C "$W" "${files[@]}"
cat "$W/manifest"
ls -l "$OUT"; sha256sum "$OUT"
