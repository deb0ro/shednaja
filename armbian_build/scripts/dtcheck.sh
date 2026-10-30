#!/bin/bash
# Trial compile of a DTS against a kernel tree's dtsi files (cpp + dtc). Usage: dtcheck.sh <kernel-tree> <dts> <out.dtb>
set -e
K=$1; DTS=$2; OUT=$3
DTC=${DTC:-$HOME/kobra/kernel-out/scripts/dtc/dtc}
T=$(mktemp -d)
cp "$DTS" "$T/board.dts"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
    -I "$(dirname "$DTS")" -I "$K/arch/arm/boot/dts" -I "$K/include" "$T/board.dts" -o "$T/board.pp"
"$DTC" -I dts -O dtb -W no-unit_address_vs_reg -o "$OUT" "$T/board.pp"
echo "OK: $OUT ($(stat -c %s "$OUT") bytes)"
rm -rf "$T"
