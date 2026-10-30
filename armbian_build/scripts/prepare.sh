#!/bin/bash
# Prepare an Armbian build tree for the Kobra S1 in WSL/Linux. Builds nothing.
#   wsl -d Ubuntu-24.04 -- bash armbian_build/scripts/prepare.sh   # from Windows (Git Bash works too)
#
# - armbian/build at ARMBIAN_COMMIT -> $AB (Linux fs: the build needs device nodes and
#   ownership in its chroot, which /mnt/d cannot do)
# - armbian/rtl8723ds at RTL8723DS_COMMIT and the two wireless Makefile/Kconfig of the pinned
#   vendor kernel -> $SRC, then userpatches/kernel/rv1106-vendor-6.1/0001-wireless-add-rtl8723ds.patch
# - kernel/dts/rv1106g-kobra-s1.dts -> userpatches/kernel/rv1106-vendor-6.1/dt/
# - armbian_build/userpatches -> $AB/userpatches (rsync, --delete)
#
# Environment: AB (default ~/kobra/armbian-build), SRC (default ~/kobra/armbian-src)
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/../.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    envs=(); for v in AB SRC STOCK BR_DL; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/armbian_build/scripts/prepare.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/armbian_build
AB=${AB:-$HOME/kobra/armbian-build}
SRC=${SRC:-$HOME/kobra/armbian-src}

# ---- pins (bump together; the kernel pin is also in userpatches/config/boards/kobra-s1.csc)
ARMBIAN_COMMIT=fac57a02f1c6ff2221a3f3099a1094dcdf41be26   # armbian/build main, 2026-10-23
KERNEL_REPO=https://github.com/armbian/linux-rockchip.git
KERNEL_COMMIT=d3d527fca68e0db93aa802692e82b9e3b10cef8d    # rk-6.1-rkr7.2, 2026-10-23
RTL8723DS_COMMIT=b5c8a00c52918c2f98c000551b0c5fc5e365f87e # armbian/rtl8723ds, 2026-09-09 (= Armbian's harness pin)

log() { echo "== $*"; }
KP=$HERE/userpatches/kernel/rv1106-vendor-6.1

fetch() {  # fetch <url> <dir> <commit>: shallow fetch of exactly one commit
  local url=$1 dir=$2 commit=$3
  if [ ! -d "$dir/.git" ]; then git init -q "$dir"; git -C "$dir" remote add origin "$url"; fi
  if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" != "$commit" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
  fi
  echo "$dir @ $(git -C "$dir" rev-parse --short HEAD)"
}

log "armbian/build -> $AB"
fetch https://github.com/armbian/build.git "$AB" "$ARMBIAN_COMMIT"

log "rtl8723ds + kernel wireless Kconfig/Makefile -> $SRC"
mkdir -p "$SRC"
fetch https://github.com/armbian/rtl8723ds.git "$SRC/rtl8723ds" "$RTL8723DS_COMMIT"
K=$SRC/linux-rockchip-6.1
if [ ! -d "$K/.git" ]; then
  git init -q "$K"; git -C "$K" remote add origin "$KERNEL_REPO"
  git -C "$K" config core.sparseCheckout true
fi
printf '%s\n' /drivers/net/wireless/Kconfig /drivers/net/wireless/Makefile \
  /arch/arm/boot/dts/ /include/dt-bindings/ /include/uapi/linux/input-event-codes.h > "$K/.git/info/sparse-checkout"
if [ "$(git -C "$K" rev-parse -q --verify HEAD 2>/dev/null)" != "$KERNEL_COMMIT" ]; then
  git -C "$K" fetch -q --depth 1 --filter=blob:none origin "$KERNEL_COMMIT"
  git -C "$K" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
fi
git -C "$K" read-tree -mu HEAD
echo "$K @ $(git -C "$K" rev-parse --short HEAD) (sparse)"

log "kernel patch: rtl8723ds"
bash "$HERE/scripts/make_rtl8723ds_patch.sh" "$K" "$SRC/rtl8723ds" "$KP/0001-wireless-add-rtl8723ds.patch"

log "kobra-abctl (static) for the boot marking"
bash "$HERE/scripts/build_abctl.sh"

log "Klipper stack (pinned sources from the Buildroot download dir)"
BR_DL=${BR_DL:-$HOME/kobra/br-dl} bash "$HERE/scripts/stage_stack.sh"

# RTL8723DS Bluetooth firmware from the official update (as ShedNaja's rootfs: the stock config
# has two board entries the public copies lack). Names as btrtl expects them for the UART part.
STOCK=${STOCK:-$ROOT/build/stock}
FW=$HERE/userpatches/overlay/usr/lib/firmware/rtl_bt
if [ -f "$STOCK/rtlbt/rtl8723d_fw" ]; then
  log "BT firmware from $STOCK/rtlbt"
  mkdir -p "$FW"
  cp "$STOCK/rtlbt/rtl8723d_fw" "$FW/rtl8723ds_fw.bin"
  cp "$STOCK/rtlbt/rtl8723d_config" "$FW/rtl8723ds_config.bin"
elif [ -f "${BT_DIR:=$HOME/kobra/rkwifibt}/firmware/realtek/RTL8723DS/rtl8723d_fw" ]; then
  # fallback as in Lite's rootfs: Realtek's public copy (radxa/rkwifibt, fetched by
  # tools/build_rootfs.sh)
  log "BT firmware from $BT_DIR (Realtek's public copy, no $STOCK/rtlbt)"
  mkdir -p "$FW"
  cp "$BT_DIR/firmware/realtek/RTL8723DS/rtl8723d_fw" "$FW/rtl8723ds_fw.bin"
  cp "$BT_DIR/firmware/realtek/RTL8723DS/rtl8723d_config" "$FW/rtl8723ds_config.bin"
else
  echo "no $STOCK/rtlbt and no $BT_DIR (tools/build_rootfs.sh, or STOCK=...): image without BT firmware"
fi

log "device tree: kernel/dts -> userpatches dt/ (trial compile against the pinned 6.1 dtsi)"
mkdir -p "$KP/dt"
cp "$ROOT/kernel/dts/rv1106g-kobra-s1.dts" "$HERE"/dts/*.dts "$KP/dt/"
if [ -x "${DTC:-$HOME/kobra/kernel-out/scripts/dtc/dtc}" ] || command -v dtc >/dev/null; then
  DTC=${DTC:-$( [ -x "$HOME/kobra/kernel-out/scripts/dtc/dtc" ] && echo "$HOME/kobra/kernel-out/scripts/dtc/dtc" || command -v dtc)} \
    bash "$HERE/scripts/dtcheck.sh" "$K" "$KP/dt/rv1106g-kobra-s1-armbian.dts" "$SRC/rv1106g-kobra-s1-armbian.dtb"
else
  echo "no dtc found (sudo apt install device-tree-compiler): DTS not checked"
fi

log "userpatches -> $AB/userpatches"
rsync -a --delete --filter="P /atf/" --filter="P /boot0/" --filter="P /fsbl/" --filter="P /misc/" --filter="P /opensbi/" --filter="P /u-boot/" --filter="P /config-example.conf" "$HERE/userpatches/" "$AB/userpatches/"   # P: dirs Armbian creates there (root)

log "ready. Build (not started here):  bash armbian_build/scripts/build.sh"
