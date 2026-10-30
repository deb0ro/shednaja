#!/bin/bash
# Build the Kobra S1 Armbian image (kernel 6.1 vendor + Debian 13 minimal) in WSL/Linux.
#   bash armbian_build/scripts/build.sh            # full image -> $AB/output/images/
#   bash armbian_build/scripts/build.sh kernel     # only the kernel .deb -> $AB/output/debs/
# Run scripts/prepare.sh first. Armbian needs sudo (loop devices, chroot) or Docker and
# downloads several GB into $AB/cache on the first run. Nothing here touches a board.
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    envs=(); for v in AB; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/armbian_build/scripts/build.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AB=${AB:-$HOME/kobra/armbian-build}
[ -f "$AB/userpatches/config-kobra-s1.conf" ] || { echo "run armbian_build/scripts/prepare.sh first" >&2; exit 1; }
# userpatches may have changed on D: since prepare.sh
rsync -a --delete --filter="P /atf/" --filter="P /boot0/" --filter="P /fsbl/" --filter="P /misc/" --filter="P /opensbi/" --filter="P /u-boot/" --filter="P /config-example.conf" "$ROOT/armbian_build/userpatches/" "$AB/userpatches/"

cd "$AB"
case "${1:-image}" in
  image)  exec ./compile.sh kobra-s1 ;;
  kernel) exec ./compile.sh kobra-s1 kernel ;;
  *) echo "usage: build.sh [image|kernel]" >&2; exit 2 ;;
esac
