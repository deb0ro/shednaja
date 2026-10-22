#!/usr/bin/env bash
# Reproducible kernel + boot image build for the Kobra S1 host board (RV1106G3).
#
#   wsl -d Ubuntu-24.04 -- bash tools/build_kernel.sh        # from Windows (also works from Git Bash)
#   bash tools/build_kernel.sh                                # inside WSL / Linux
#
# Steps: fetch the Luckfox Pico SDK (kernel 5.10.160 + arm-rockchip830 gcc 8.3.0, pinned
# commit, sparse/blobless clone) -> copy our DTS + config fragment into the tree ->
# rv1106_defconfig + rv1106-evb.config + kobra_s1.config -> zImage, DTB, modules,
# out-of-tree RTL8723DS Wi-Fi (SDK vendor driver + kernel/patches/0002) and Realtek
# vendor hci_uart for BT (radxa/rkwifibt, pinned) -> FIT boot image from the stock
# boot.img as template.
# Nothing is flashed. Outputs go to build/kernel/ (see docs/kernel-build.md).
#
# Environment overrides:
#   SDK_DIR   SDK checkout             (default ~/kobra/luckfox-pico)
#   KOUT      kernel object dir        (default ~/kobra/kernel-out; keep it on the Linux fs)
#   TEMPLATE  stock boot.img for FIT   (default build/stock/boot.img, tools/fetch_stock.sh)
#   JOBS      parallel jobs            (default nproc)
#   CLEAN=1   wipe KOUT first
set -euo pipefail

# Started from Git Bash on Windows -> re-run inside WSL
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    # Git Bash variables do not reach WSL: pass the overrides explicitly
    envs=(); for v in CLEAN JOBS SDK_DIR BT_DIR KOUT TEMPLATE; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/tools/build_kernel.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK_URL=https://github.com/LuckfoxTECH/luckfox-pico.git
SDK_COMMIT=824b817f889c2cbff1d48fcdb18ab494a68f69d1      # main, 2026-03-22
SDK_DIR=${SDK_DIR:-$HOME/kobra/luckfox-pico}
# Realtek vendor Bluetooth UART driver (hci_uart 2.2.x with rtk_coex, as loaded by stock)
BT_URL=https://github.com/radxa/rkwifibt.git
BT_COMMIT=b61a1e8499a4f1956ef417cbcfaa6c2cf805ce08       # develop, 2026-04-14
BT_DIR=${BT_DIR:-$HOME/kobra/rkwifibt}
KOUT=${KOUT:-$HOME/kobra/kernel-out}
TEMPLATE=${TEMPLATE:-$ROOT/build/stock/boot.img}
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE - run tools/fetch_stock.sh first"; exit 1; }
JOBS=${JOBS:-$(nproc)}
OUT=$ROOT/build/kernel
DTS_NAME=rv1106g-kobra-s1
KREL=5.10.160

KSRC=$SDK_DIR/sysdrv/source/kernel
TC=$SDK_DIR/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin
CROSS=arm-rockchip830-linux-uclibcgnueabihf-
log() { printf '\n=== %s\n' "$*"; }

# ---- 1. SDK (kernel + toolchain only) --------------------------------------
if [ ! -f "$KSRC/Makefile" ]; then
  log "fetching Luckfox Pico SDK $SDK_COMMIT (kernel + toolchain, ~2 GB)"
  mkdir -p "$(dirname "$SDK_DIR")"
  git clone --filter=blob:none --no-checkout "$SDK_URL" "$SDK_DIR"
  git -C "$SDK_DIR" sparse-checkout init --cone
  git -C "$SDK_DIR" sparse-checkout set sysdrv/source/kernel \
      tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf
  git -C "$SDK_DIR" checkout -q "$SDK_COMMIT"
fi
if [ ! -f "$BT_DIR/drivers/bluetooth_uart_driver/hci_ldisc.c" ]; then
  log "fetching radxa/rkwifibt $BT_COMMIT (bluetooth_uart_driver only)"
  rm -rf "$BT_DIR"
  git clone --filter=blob:none --no-checkout "$BT_URL" "$BT_DIR"
  git -C "$BT_DIR" sparse-checkout init --cone
  git -C "$BT_DIR" sparse-checkout set drivers/bluetooth_uart_driver
  git -C "$BT_DIR" checkout -q "$BT_COMMIT"
fi
[ "$(git -C "$BT_DIR" rev-parse HEAD)" = "$BT_COMMIT" ] || echo "WARNING: rkwifibt is not at $BT_COMMIT"
head=$(git -C "$SDK_DIR" rev-parse HEAD)
[ "$head" = "$SDK_COMMIT" ] || echo "WARNING: SDK is at $head, expected $SDK_COMMIT"
export PATH=$TC:$PATH
"${CROSS}gcc" --version | head -1

# Reproducible build metadata: pinned to the SDK commit date
export KBUILD_BUILD_TIMESTAMP="$(git -C "$SDK_DIR" log -1 --format=%cD "$SDK_COMMIT")"
export KBUILD_BUILD_USER=kobra KBUILD_BUILD_HOST=shednaja SOURCE_DATE_EPOCH=$(git -C "$SDK_DIR" log -1 --format=%ct "$SDK_COMMIT")
# the "#N" in uname -v is a per-object-dir build counter (.version): pin it, otherwise
# every relink in the same KOUT changes the zImage
export KBUILD_BUILD_VERSION=1
# LOCALVERSION empty -> release "5.10.160" exactly, same vermagic as the stock modules
M=(make -C "$KSRC" O="$KOUT" ARCH=arm CROSS_COMPILE="$CROSS" LOCALVERSION= -j"$JOBS")

# ---- 2. our files into the tree --------------------------------------------
log "installing Kobra DTS and config fragment into the kernel tree"
install -m644 "$ROOT/kernel/dts/$DTS_NAME.dts" "$KSRC/arch/arm/boot/dts/$DTS_NAME.dts"
install -m644 "$ROOT/kernel/configs/kobra_s1.config" "$KSRC/arch/arm/configs/kobra_s1.config"
for p in "$ROOT"/kernel/patches/*.patch; do
  [ -e "$p" ] || continue
  if patch -p1 -R --dry-run -s -f -d "$KSRC" < "$p" >/dev/null 2>&1; then
    echo "  already applied: $(basename "$p")"
  else
    patch -p1 -N -s -d "$KSRC" < "$p" && echo "  applied: $(basename "$p")"
  fi
done

# ---- 3. config --------------------------------------------------------------
[ "${CLEAN:-0}" = 1 ] && rm -rf "$KOUT"
mkdir -p "$KOUT" "$OUT"
log "config: rv1106_defconfig + rv1106-evb.config + kobra_s1.config"
"${M[@]}" -s rv1106_defconfig rv1106-evb.config kobra_s1.config >/dev/null
# every option of our fragment must have survived Kconfig dependency resolution
bad=0
while IFS= read -r line; do
  case "$line" in CONFIG_*=*) ;; *) continue ;; esac
  grep -qx "$line" "$KOUT/.config" || { echo "  not applied: $line ($(grep "^${line%%=*}=" "$KOUT/.config" || echo unset))"; bad=1; }
done < "$ROOT/kernel/configs/kobra_s1.config"
[ $bad = 0 ] && echo "  all fragment options applied"

# ---- 4. kernel, DTB, modules -----------------------------------------------
log "building zImage, $DTS_NAME.dtb and modules (-j$JOBS)"
"${M[@]}" -s zImage modules "$DTS_NAME.dtb"
rel=$(cat "$KOUT/include/config/kernel.release")
[ "$rel" = "$KREL" ] || { echo "kernel release is '$rel', expected '$KREL'"; exit 1; }

log "building RTL8723DS Wi-Fi (SDK vendor driver + patch 0002) and Realtek hci_uart"
# Options as close to the stock RTL8723DS.ko as the strings/symbols show: generic Linux
# platform with the Rockchip hooks, cfg80211/nl80211, no WOWLAN/GPIO wakeup/debug,
# module named RTL8723DS (the Anycubic app does insmod /oem/usr/ko/RTL8723DS.ko).
# -Wno-*: vendor code; Rockchip's gcc-wrapper.py turns these warnings into errors.
WSRC=$KSRC/drivers/net/wireless/rockchip_wlan/rtl8723ds
WOUT=$KOUT/ext/rtl8723ds
rm -rf "$WOUT"; mkdir -p "$WOUT"; cp -a "$WSRC/." "$WOUT/"
find "$WOUT" \( -name '*.o' -o -name '.*.cmd' -o -name '*.ko' \) -delete   # stale objects shipped in the SDK copy
"${M[@]}" -s M="$WOUT" CONFIG_RTL8723DS=m CONFIG_PLATFORM_ARM_RK3188=n MODULE_NAME=RTL8723DS \
    CONFIG_RTW_DEBUG=n CONFIG_PROC_DEBUG=n CONFIG_WOWLAN=n CONFIG_GPIO_WAKEUP=n \
    USER_EFUSE_MAP_PATH=/system/etc/wifi/wifi_efuse_8723ds.map \
    USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN -DCONFIG_PLATFORM_ROCKCHIPS -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT -Wno-vla -Wno-implicit-fallthrough -Wno-unused-function" \
    modules > "$OUT/rtl8723ds.log" 2>&1 || { tail -30 "$OUT/rtl8723ds.log"; exit 1; }
BOUT=$KOUT/ext/hci_uart
rm -rf "$BOUT"; mkdir -p "$BOUT"; cp -a "$BT_DIR/drivers/bluetooth_uart_driver/." "$BOUT/"
"${M[@]}" -s M="$BOUT" modules > "$OUT/hci_uart.log" 2>&1 || { tail -30 "$OUT/hci_uart.log"; exit 1; }
ls -l "$WOUT"/RTL8723DS.ko "$BOUT"/hci_uart.ko

log "installing modules"
MODROOT=$KOUT/modroot
rm -rf "$MODROOT"
"${M[@]}" -s INSTALL_MOD_PATH="$MODROOT" INSTALL_MOD_STRIP=1 modules_install
for ext in "$WOUT" "$BOUT"; do
  "${M[@]}" -s M="$ext" INSTALL_MOD_PATH="$MODROOT" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra modules_install
done
# same files flat, as the stock userspace expects them in /oem/usr/ko/
rm -rf "$OUT/oem-ko"; mkdir -p "$OUT/oem-ko"
cp "$MODROOT/lib/modules/$rel/extra/RTL8723DS.ko" "$MODROOT/lib/modules/$rel/extra/hci_uart.ko" \
   "$MODROOT/lib/modules/$rel/kernel/net/wireless/cfg80211.ko" "$OUT/oem-ko/"
rm -f "$MODROOT/lib/modules/$rel/build" "$MODROOT/lib/modules/$rel/source"
tar -C "$MODROOT" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" -czf "$OUT/modules-$rel.tar.gz" lib
find "$MODROOT" -name '*.ko' -printf '%P\n' | sort > "$OUT/modules.txt"

# ---- 5. collect artifacts ---------------------------------------------------
log "collecting artifacts in build/kernel/"
cp "$KOUT/arch/arm/boot/zImage" "$OUT/zImage"
cp "$KOUT/arch/arm/boot/dts/$DTS_NAME.dtb" "$OUT/$DTS_NAME.dtb"
cp "$KOUT/System.map" "$OUT/System.map"
cp "$KOUT/.config" "$OUT/config"
"${M[@]}" -s savedefconfig >/dev/null && cp "$KOUT/defconfig" "$OUT/kobra_s1_defconfig"

# ---- 6. boot image (FIT + RSCE with stock logos) ---------------------------
log "boot image from template $(basename "$TEMPLATE")"
python3 -I "$ROOT/tools/mkboot_kernel.py" --logo "$ROOT/kernel/logo/boot_logo.bmp" \
	"$TEMPLATE" "$OUT/zImage" "$OUT/$DTS_NAME.dtb" "$OUT/boot.img"

# ---- 7. checks --------------------------------------------------------------
# stock DTB extracted from a boot image (docs/firmware-analysis.md); only on a dev machine
STOCK_DTB=$ROOT/analysis/boot_fdt.bin
if [ -f "$STOCK_DTB" ]; then
  log "DTB vs stock (informational: $OUT/dtb_vs_stock.diff)"
  python3 -I "$ROOT/tools/dtb_normalize.py" "$STOCK_DTB" > "$OUT/stock_dtb.txt"
  python3 -I "$ROOT/tools/dtb_normalize.py" "$OUT/$DTS_NAME.dtb" > "$OUT/kobra_dtb.txt"
  diff "$OUT/stock_dtb.txt" "$OUT/kobra_dtb.txt" > "$OUT/dtb_vs_stock.diff" || true
  echo "  $(grep -c '^<' "$OUT/dtb_vs_stock.diff") stock-only / $(grep -c '^>' "$OUT/dtb_vs_stock.diff") ours-only property lines"
fi

(cd "$OUT" && sha256sum zImage "$DTS_NAME.dtb" boot.img "modules-$rel.tar.gz" oem-ko/*.ko | tee SHA256SUMS)
echo "done: $OUT/boot.img  (kernel $rel, $(stat -c %s "$OUT/boot.img") B, boot partition 16 MiB)"
