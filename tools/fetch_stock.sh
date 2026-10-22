#!/usr/bin/env bash
# Stock files used only by development tools, taken from the official Anycubic update
# KS1_2.7.2.7.swu (never from this repository: Anycubic's files are not ours to
# redistribute). The images ShedNaja installs contain none of them.
#
#   bash tools/fetch_stock.sh [KS1_2.7.2.7.swu]     # from Git Bash (re-runs itself in WSL) or WSL/Linux
#
# Without an argument the .swu is downloaded from the Rinkhals project's archive of the
# official stock updates. Either way its sha256 must match the pin below.
# Output: build/stock/
#   boot.img     stock boot image: layout template for our FIT image (tools/build_kernel.sh;
#                only its header structure is reused, kernel/DTB/logo are ours)
#   oem.img      stock oem squashfs: base of oem_ours.img (tools/build_oem_ours.sh, optional,
#                development only: ShedNaja does not install an oem image)
#   firmware_v1.4.3_20260303.bin   Anycubic MCU firmware (both MCUs run it)
#   firmware_v1.4.3.dict           its Klipper data dictionary (rootfs/tests/offline_check.sh)
# Needs: unzip, python3, curl.
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    args=(); for a in "$@"; do args+=("$(cd "$(dirname "$a")" && pwd -W | sed 's|^\(.\):|/mnt/\L\1|')/$(basename "$a")"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- bash "$wpath/tools/fetch_stock.sh" "${args[@]}" ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/stock
SWU_NAME=KS1_2.7.2.7.swu
SWU_URL="https://rinkhals.firmwareforge.org/firmware/Kobra%20S1/$SWU_NAME"
SWU_SHA256=e3f2218461fd3bb041b75a34b13318ff61d40bfd5f67abdc67d531bdb9af148b
# zip password of the stock USB update (from the stock /userdata/channel.sh, also
# published by the Rinkhals project); same as tools/make_swu.sh
PASS='U2FsdGVkX1+lG6cHmshPLI/LaQr9cZCjA8HZt6Y8qmbB7riY'
declare -A PIN=(
  [boot.img]=2da14364feb97e870613c1cbd77d7a7b372727f33c139d81bab0f8b388209f11
  [oem.img]=f551a5649357024037e3916c1ee19d03995dccdb41ed71708ad75c5cf6e8879f
  [firmware_v1.4.3_20260303.bin]=ddca449586e15f08e59f8af3a409ac5a90500a93f9cede5d0dd692145c8e5367
)

mkdir -p "$OUT"
SWU=${1:-$OUT/$SWU_NAME}
if [ ! -f "$SWU" ]; then
  echo "downloading $SWU_NAME"
  curl -fL --retry 3 -o "$SWU.part" "$SWU_URL"
  mv "$SWU.part" "$SWU"
fi
echo "$SWU_SHA256  $SWU" | sha256sum -c --quiet || { echo "$SWU is not the official $SWU_NAME"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
unzip -q -P "$PASS" -p "$SWU" update_swu/setup.tar.gz > "$W/setup.tar.gz"
tar -xzf "$W/setup.tar.gz" -C "$W" ./update_ota.tar ./firmware_v1.4.3_20260303.bin
tar -xf "$W/update_ota.tar" -C "$W" boot.img oem.img
for f in "${!PIN[@]}"; do
  echo "${PIN[$f]}  $W/$f" | sha256sum -c --quiet || { echo "unexpected $f in $SWU_NAME"; exit 1; }
  cp "$W/$f" "$OUT/$f"
done

python3 -I "$ROOT/tools/mcu_dict.py" "$OUT/firmware_v1.4.3_20260303.bin" "$OUT/firmware_v1.4.3.dict"
(cd "$OUT" && sha256sum boot.img oem.img firmware_v1.4.3* > SHA256SUMS)
echo "done: $OUT"
