#!/bin/bash
# Static armhf build of kobra-abctl (rootfs/package/kobra-abctl/src) for the Armbian root, into
# userpatches/overlay/usr/local/sbin/ (generated, not in git). Built with the SDK uClibc toolchain,
# as for ShedNaja; the static binary runs under glibc too. Run in WSL/Linux.
set -euo pipefail
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- bash "$wpath/armbian_build/scripts/build_abctl.sh" "$@" ;;
esac
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/armbian_build/userpatches/overlay/usr/local/sbin
mkdir -p "$OUT"
TC=${TC:-$HOME/kobra/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-}
"${TC}gcc" -static -O2 -Wall -Wextra -o "$OUT/kobra-abctl" "$ROOT/rootfs/package/kobra-abctl/src/kobra-abctl.c"
"${TC}strip" "$OUT/kobra-abctl"
file "$OUT/kobra-abctl"; ls -l "$OUT/kobra-abctl"
