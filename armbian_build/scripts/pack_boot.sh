#!/bin/bash
# Pack Armbian's 6.1 kernel into ShedNaja's FIT boot image (stock U-Boot boots it, as with
# tools/build_kernel.sh). Writes build/armbian/boot.img, which is installed like any
# ShedNaja boot image (update bundle, our slot only). Nothing here touches a board.
#   bash armbian_build/scripts/pack_boot.sh [linux-image-*.deb]
# Default .deb: the newest linux-image-vendor-rockchip-rv1106_*.deb in $AB/output/debs/.
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    envs=(); for v in AB TEMPLATE; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/armbian_build/scripts/pack_boot.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AB=${AB:-$HOME/kobra/armbian-build}
TEMPLATE=${TEMPLATE:-$ROOT/build/stock/boot.img}
DTB_NAME=rv1106g-kobra-s1-armbian.dtb
OUT=$ROOT/build/armbian

deb=${1:-$(ls -t "$AB"/output/debs/linux-image-vendor-rockchip-rv1106_*.deb 2>/dev/null | head -1)}
[ -f "$deb" ] || { echo "no linux-image .deb (run scripts/build.sh kernel)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "no $TEMPLATE (run tools/fetch_stock.sh)" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
dpkg-deb -x "$deb" "$T"
zimage=$(ls "$T"/boot/vmlinuz-* | head -1)
dtb=$(find "$T/usr/lib" -name "$DTB_NAME" | head -1)
[ -n "$dtb" ] || { echo "$DTB_NAME not in $deb" >&2; exit 1; }
file -b "$zimage" | grep -q 'zImage' || { echo "$zimage is not an ARM zImage: $(file -b "$zimage")" >&2; exit 1; }
# stock U-Boot: zImage at kernel_addr_c=0x00808000, DTB at fdt_addr_r=0x00C00000 (Luckfox U-Boot
# include/configs/rv1106_common.h). A bigger zImage overwrites the DTB: silent hang before earlycon.
max=$((0x00C00000 - 0x00808000)); size=$(stat -c %s "$zimage")
[ "$size" -le "$max" ] || { echo "zImage $size B > $max B: would overwrite the DTB at 0xC00000 (use KERNEL_XZ, trim built-ins)" >&2; exit 1; }
echo "zImage $size B of max $max B ($(( (max - size) / 1024 )) KiB left)"
# The decompressed kernel goes to 0x8000; if it reaches the zImage at 0x808000, the decompressor
# relocates itself past the kernel end, onto the DTB at 0xC00000. Size without BSS: _text.._edata.
map=$(ls "$T"/boot/System.map-* | head -1)
t0=$(grep -w _text "$map" | cut -d' ' -f1); te=$(grep -w _edata "$map" | cut -d' ' -f1)
dsize=$(( 0x$te - 0x$t0 )); dmax=$((0x00808000 - 0x8000))
[ "$dsize" -le "$dmax" ] || { echo "decompressed kernel $dsize B > $dmax B: decompressor would relocate onto the DTB (trim built-ins)" >&2; exit 1; }
echo "decompressed kernel $dsize B of max $dmax B ($(( (dmax - dsize) / 1024 )) KiB left)"

mkdir -p "$OUT"
cp "$zimage" "$OUT/zImage"; cp "$dtb" "$OUT/$DTB_NAME"
cp "$T"/boot/config-* "$OUT/config" 2>/dev/null || true
python3 -I "$ROOT/tools/mkboot_kernel.py" --logo "$ROOT/kernel/logo/boot_logo.bmp" \
  "$TEMPLATE" "$OUT/zImage" "$OUT/$DTB_NAME" "$OUT/boot.img"
echo "kernel: $(basename "$zimage") from $(basename "$deb")"
(cd "$OUT" && sha256sum boot.img zImage "$DTB_NAME" | tee SHA256SUMS)
