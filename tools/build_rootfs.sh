#!/usr/bin/env bash
# Reproducible minimal rootfs (squashfs) for the Kobra S1 system_a/system_b slot.
#
#   bash tools/build_rootfs.sh           # from Git Bash (re-runs itself in WSL) or WSL/Linux
#
# Buildroot 2023.02.6 from the pinned Luckfox Pico SDK + our BR2_EXTERNAL tree rootfs/
# (configs/kobra_s1_defconfig, overlay, packages kobra-abctl + rtk-hciattach), with the
# SDK's uClibc toolchain (same as the kernel). Inputs from this repo:
#   build/kernel/modules-5.10.160.tar.gz   (tools/build_kernel.sh)
#   SSH_KEY=<file.pub> (optional, development builds only): baked into root's
#                                          authorized_keys; the build id gets "+devkey".
#                                          Without it (release builds) root's keys live in
#                                          /userdata/shednaja/ssh, set up by the owner.
#   Nothing from the stock firmware: the root password hash is generated (default password
#   "rockchip", as stock) and the Bluetooth firmware in the image is Realtek's public copy
#   (S42bluetooth copies the printer's own stock one from its ac_lib partition at boot).
# Output: build/rootfs/rootfs.squashfs (+ manifest, size report). Nothing is flashed.
#
# Environment overrides: SDK_DIR, BT_DIR, BR_OUT (~/kobra/rootfs-out), BR_DL (~/kobra/br-dl),
#   JOBS, CLEAN=1 (wipe BR_OUT first), SSH_KEY, ALLOW_UNPINNED=1 (build even if the SDK
#   checkout is not at its pinned commit; the build id gets "+unpinned").
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    # Git Bash variables do not reach WSL: pass the overrides explicitly
    envs=(); for v in CLEAN JOBS SDK_DIR BT_DIR BR_OUT BR_DL SSH_KEY ALLOW_UNPINNED; do [ -n "${!v:-}" ] && envs+=("$v=${!v}"); done
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- env "${envs[@]}" bash "$wpath/tools/build_rootfs.sh" "$@" ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK_COMMIT=824b817f889c2cbff1d48fcdb18ab494a68f69d1      # same pin as tools/build_kernel.sh
SDK_DIR=${SDK_DIR:-$HOME/kobra/luckfox-pico}
BT_URL=https://github.com/radxa/rkwifibt.git
BT_COMMIT=b61a1e8499a4f1956ef417cbcfaa6c2cf805ce08       # same pin as tools/build_kernel.sh
BT_DIR=${BT_DIR:-$HOME/kobra/rkwifibt}
BR_VER=buildroot-2023.02.6
BR_TGZ_SHA256=087d0514696d191142f5d421c0e6d01575816499f75d7a5672b899e4393f6331
BR_SRC=$HOME/kobra/br/$BR_VER
BR_OUT=${BR_OUT:-$HOME/kobra/rootfs-out}
BR_DL=${BR_DL:-$HOME/kobra/br-dl}
JOBS=${JOBS:-$(nproc)}
OUT=$ROOT/build/rootfs
KREL=5.10.160
SYSTEM_PART_BYTES=$((48 * 1024 * 1024))                 # system_a/system_b
IN=$HOME/kobra/rootfs-in
log() { printf '\n=== %s\n' "$*"; }
# A source checkout must be at its pin; ALLOW_UNPINNED=1 lets a development build go on
pin_check() {	# pin_check <name> <dir> <commit>
  local head; head=$(git -C "$2" rev-parse HEAD)
  [ "$head" = "$3" ] && return 0
  if [ "${ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "WARNING: $1 is at $head, expected $3 (ALLOW_UNPINNED=1)"; UNPINNED=1; return 0
  fi
  echo "$1 in $2 is at $head, expected $3:"
  echo "  git -C $2 checkout $3    (or ALLOW_UNPINNED=1 for a development build)"
  exit 1
}
UNPINNED=0

# ---- 1. sources --------------------------------------------------------------
[ -d "$SDK_DIR/.git" ] || { echo "no SDK at $SDK_DIR - run tools/build_kernel.sh first"; exit 1; }
pin_check "Luckfox Pico SDK" "$SDK_DIR" "$SDK_COMMIT"
BR_TGZ=$SDK_DIR/sysdrv/tools/board/buildroot/$BR_VER.tar.gz
if [ ! -f "$BR_TGZ" ]; then
  log "adding sysdrv/tools/board/buildroot to the SDK sparse checkout"
  git -C "$SDK_DIR" sparse-checkout add sysdrv/tools/board/buildroot
fi
echo "$BR_TGZ_SHA256  $BR_TGZ" | sha256sum -c --quiet
if [ ! -f "$BR_SRC/.kobra-extracted" ]; then
  log "extracting $BR_VER (pristine, from the SDK tarball)"
  rm -rf "$BR_SRC"; mkdir -p "$(dirname "$BR_SRC")"
  tar -xzf "$BR_TGZ" -C "$(dirname "$BR_SRC")"
  touch "$BR_SRC/.kobra-extracted"
fi

if [ ! -d "$BT_DIR/.git" ]; then
  log "fetching radxa/rkwifibt $BT_COMMIT"
  git clone --filter=blob:none --no-checkout "$BT_URL" "$BT_DIR"
  git -C "$BT_DIR" sparse-checkout init --cone
fi
git -C "$BT_DIR" sparse-checkout add drivers/bluetooth_uart_driver tools/rtk_hciattach firmware/realtek/RTL8723DS
git -C "$BT_DIR" checkout -q "$BT_COMMIT"

# ---- 2. inputs from the repo / dumps ------------------------------------------
MOD_TAR=$ROOT/build/kernel/modules-$KREL.tar.gz
[ -f "$MOD_TAR" ] || { echo "missing $MOD_TAR - run tools/build_kernel.sh first"; exit 1; }
if [ -f "$ROOT/build/kernel/UNPINNED" ]; then
  echo "WARNING: build/kernel comes from an unpinned kernel build (ALLOW_UNPINNED=1)"; UNPINNED=1
fi
tar -tzf "$MOD_TAR" "lib/modules/$KREL/extra/RTL8723DS.ko" "lib/modules/$KREL/extra/hci_uart.ko" >/dev/null
PUBKEY=""
if [ -n "${SSH_KEY:-}" ]; then
  case "$SSH_KEY" in /*) PUBKEY=$SSH_KEY ;; *) PUBKEY=$ROOT/$SSH_KEY ;; esac
  [ -f "$PUBKEY" ] || { echo "missing $PUBKEY"; exit 1; }
fi

rm -rf "$IN"; mkdir -p "$IN/rtlbt"
# default root password "rockchip" (the stock one; the owner changes it with passwd).
# md5crypt like stock (busybox login and dropbear verify it); fixed salt = reproducible
ROOT_HASH=$(openssl passwd -1 -salt shednaja rockchip)
case "$ROOT_HASH" in '$1$shednaja$'*) ;; *) echo "openssl passwd failed"; exit 1 ;; esac
# fallback Bluetooth firmware: Realtek's, redistributable (radxa/rkwifibt); the printer's
# own stock firmware is used when S42bluetooth finds it in the stock ac_lib partition
cp "$BT_DIR/firmware/realtek/RTL8723DS/rtl8723d_fw" "$BT_DIR/firmware/realtek/RTL8723DS/rtl8723d_config" "$IN/rtlbt/"
BTFW_SRC="radxa/rkwifibt $BT_COMMIT (fallback)"

export KOBRA_TOOLCHAIN=$SDK_DIR/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf
export KOBRA_DL_DIR=$BR_DL
export KOBRA_RKWIFIBT_DIR=$BT_DIR KOBRA_RKWIFIBT_COMMIT=$BT_COMMIT
export KOBRA_MODULES_TAR=$MOD_TAR KOBRA_BTFW_DIR=$IN/rtlbt KOBRA_AUTHORIZED_KEYS=$PUBKEY
export KOBRA_ROOT_HASH=$ROOT_HASH
export KOBRA_VERSION=0.1
export KOBRA_BUILD_ID=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo unknown)
# a developer's key in the image must never look like a release
[ -n "$PUBKEY" ] && KOBRA_BUILD_ID=$KOBRA_BUILD_ID+devkey
[ "$UNPINNED" = 1 ] && KOBRA_BUILD_ID=$KOBRA_BUILD_ID+unpinned
unset ARCH CROSS_COMPILE PERL_MM_OPT
# Buildroot refuses a PATH with spaces/current dir (WSL appends the Windows PATH)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- 3. build -------------------------------------------------------------------
[ "${CLEAN:-0}" = 1 ] && rm -rf "$BR_OUT"
# Buildroot does not rebuild packages when only their options change: start from a clean
# output dir whenever the defconfig (or the busybox fragment) differs from the last build.
cfg_sum=$(cat "$ROOT/rootfs/configs/kobra_s1_defconfig" "$ROOT/rootfs/board/kobra_s1/busybox.fragment" | sha256sum | cut -d' ' -f1)
if [ -d "$BR_OUT" ] && [ "$(cat "$BR_OUT/.kobra-config-sum" 2>/dev/null)" != "$cfg_sum" ]; then
  log "defconfig changed since the last build - clean rebuild (downloads stay in $BR_DL)"
  rm -rf "$BR_OUT"
fi
mkdir -p "$BR_OUT" "$BR_DL" "$OUT"
echo "$cfg_sum" > "$BR_OUT/.kobra-config-sum"
B=(make -C "$BR_SRC" O="$BR_OUT" BR2_EXTERNAL="$ROOT/rootfs")
log "configure: kobra_s1_defconfig"
"${B[@]}" -s kobra_s1_defconfig
# packages from the local tree must be rebuilt when their sources change: every package
# with SITE_METHOD = local (a hand-kept list missed kobra-webcam)
local_pkgs=$(grep -l '_SITE_METHOD *= *local' "$ROOT"/rootfs/package/*/*.mk | xargs -n1 basename | sed 's/\.mk$/-dirclean/')
"${B[@]}" -s $local_pkgs >/dev/null 2>&1 || true
log "build (-j$JOBS; first run downloads sources to $BR_DL and takes a while)"
# WSL2's clock is pulled back by the host every few tens of seconds ("Time jumped
# backwards" in the journal). That trips autoconf's "newly created file is older than
# distributed files" check, or makes make re-extract a package on top of itself
# ("duplicate filename" patch error). OpenSSL's install step also relinks in parallel and
# sometimes links against a half-written libcrypto.so ("file not recognized") or loses a
# dependency file ("mv: cannot stat '*.d.tmp'"). None of
# these is a real build problem: wipe only the affected package's build dir and resume, a
# few times at most. Parallel jobs print the cause well before the end of the log.
: > "$OUT/build.log"
for attempt in 1 2 3 4 5 6; do
  if "${B[@]}" -j"$JOBS" >> "$OUT/build.log" 2>&1; then break; fi
  pkgdir=$(tail -150 "$OUT/build.log" | sed -n 's#.*\(/build/[^/ ]*\)/\.stamp_[a-z_]*\].*#\1#p' | tail -1)
  if [ "$attempt" -lt 6 ] && [ -n "$pkgdir" ] &&
     tail -150 "$OUT/build.log" | grep -qE "Check your system clock|duplicate filename|clock skew|modification time .* in the future|file not recognized: file truncated|cannot stat .*\.d\.tmp"; then
    echo "  transient failure in ${pkgdir#/build/} (WSL clock jump or parallel-make race) - wiping it and retrying ($attempt/5)"
    rm -rf "$BR_OUT$pkgdir"
    continue
  fi
  tail -40 "$OUT/build.log"; exit 1
done

# ---- 4. artifacts + report ---------------------------------------------------------
IMG=$BR_OUT/images/rootfs.squashfs
cp "$IMG" "$OUT/rootfs.squashfs"
cp "$BR_OUT/.config" "$OUT/buildroot.config"
"${B[@]}" -s savedefconfig BR2_DEFCONFIG="$OUT/kobra_s1_defconfig.saved" >/dev/null
size=$(stat -c %s "$OUT/rootfs.squashfs")
[ "$size" -le "$SYSTEM_PART_BYTES" ] || { echo "rootfs.squashfs ($size B) does not fit system_x ($SYSTEM_PART_BYTES B)"; exit 1; }

T=$BR_OUT/target
{
  echo "# Kobra S1 rootfs manifest ($(date -u -d @"$(stat -c %Y "$IMG")" +%F), build id $KOBRA_BUILD_ID)"
  echo "buildroot: $BR_VER (SDK $SDK_COMMIT), external: rootfs/"
  echo "rkwifibt (rtk_hciattach): $BT_COMMIT"
  echo "bt firmware: $BTFW_SRC ($(cd "$IN/rtlbt" && md5sum rtl8723d_fw rtl8723d_config | tr '\n' ' '))"
  echo "kernel modules: $(basename "$MOD_TAR") sha256 $(sha256sum "$MOD_TAR" | cut -d' ' -f1)"
  echo
  echo "## size"
  printf 'rootfs.squashfs   %10d B  (%.1f MiB)\n' "$size" "$(echo "$size/1048576" | bc -l)"
  printf 'system partition  %10d B  (48.0 MiB)\n' "$SYSTEM_PART_BYTES"
  printf 'left              %10d B  (%.1f MiB)\n' $((SYSTEM_PART_BYTES - size)) "$(echo "($SYSTEM_PART_BYTES-$size)/1048576" | bc -l)"
  printf 'target dir (uncompressed) %s\n' "$(du -sh --apparent-size "$T" | cut -f1)"
  echo
  echo "## installed size per package (uncompressed, from packages-file-list.txt)"
  awk -F, -v T="$T" '{ f=T"/"$2; cmd="stat -c %s \""f"\" 2>/dev/null"; s=0; cmd | getline s; close(cmd); sz[$1]+=s }
       END { for (p in sz) printf "%10d  %s\n", sz[p], p }' "$BR_OUT/build/packages-file-list.txt" | sort -rn
  echo
  echo "## packages (name version)"
  "${B[@]}" -s show-info 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for k, v in sorted(d.items()):
    if v.get("type") == "target" and v.get("virtual") is not True:
        print(k, v.get("version", ""))'
} > "$OUT/manifest.txt"
(cd "$OUT" && sha256sum rootfs.squashfs > SHA256SUMS)
echo "$KOBRA_BUILD_ID" > "$OUT/BUILD_ID"	# read by tools/make_update_bundle.sh
sed -n '/^## size/,/^$/p' "$OUT/manifest.txt"
echo "done: $OUT/rootfs.squashfs"
