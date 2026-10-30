#!/bin/bash
# Stage the Klipper stack for the Armbian image: the same pinned sources as ShedNaja (Lite), taken
# from the Buildroot download dir and checked against the Buildroot .hash files, plus Lite's own
# files (Klipper extras, helper and init scripts, default configs, lighttpd.conf). Output:
# armbian_build/userpatches/overlay/kobra-stack/ (generated, not in git); customize-image.sh runs
# kobra-stack/install-stack.sh in the image chroot. Run in WSL/Linux (prepare.sh calls it).
# Environment: BR_DL (default ~/kobra/br-dl, filled by tools/build_rootfs.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DL=${BR_DL:-$HOME/kobra/br-dl}
PKG=$ROOT/rootfs/package
BOARD=$ROOT/rootfs/board/kobra_s1
OUT=$ROOT/armbian_build/userpatches/overlay/kobra-stack
mkver() { sed -n "s/^$1 *= *//p" "$PKG/$2/$2.mk" | head -1; }

rm -rf "$OUT"; mkdir -p "$OUT/src" "$OUT/lite" "$OUT/patches/klipper" "$OUT/patches/sfd"

# file from the download dir; checked against <pkg>.hash when the file is listed there
take() {  # take <pkg> <file>
	local f=$DL/$1/$2 h=$PKG/$1/$1.hash want
	[ -f "$f" ] || { echo "missing $f (run tools/build_rootfs.sh once)" >&2; exit 1; }
	if [ -f "$h" ] && want=$(awk -v n="$2" '$1=="sha256" && $3==n {print $2}' "$h") && [ -n "$want" ]; then
		[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] || { echo "sha256 mismatch: $f" >&2; exit 1; }
	fi
	cp "$f" "$OUT/src/"
	echo "  $1: $2 $(sha256sum "$f" | cut -c1-16)"
}
KV=$(mkver KLIPPER_VERSION klipper)
take klipper "klipper-$KV-br1.tar.gz"
take moonraker "moonraker-$(mkver MOONRAKER_VERSION moonraker)-br1.tar.gz"
take mainsail mainsail.zip
take mainsail-config "mainsail-config-$(mkver MAINSAIL_CONFIG_VERSION mainsail-config)-br1.tar.gz"
take helixscreen "helixscreen-ad5m-v$(mkver HELIXSCREEN_VERSION helixscreen).tar.gz"
take kobra-acepro "kobra-acepro-$(mkver KOBRA_ACEPRO_VERSION kobra-acepro).tar.gz"
take mjpg-streamer "$(ls "$DL/mjpg-streamer" | grep '^mjpg-streamer-.*\.tar\.gz$' | head -1)"
take python-streaming-form-data "streaming-form-data-$(mkver PYTHON_STREAMING_FORM_DATA_VERSION python-streaming-form-data).tar.gz"
take kobra-pywheels inotify_simple-2.0.1-py3-none-any.whl

# patches as in Buildroot (it applies every *.patch of a package, in name order)
cp "$PKG"/klipper/*.patch "$OUT/patches/klipper/"
cp "$PKG"/python-streaming-form-data/*.patch "$OUT/patches/sfd/"

# root's default password as on Lite ("rockchip", md5crypt with Lite's fixed salt, see
# tools/build_rootfs.sh) and Lite's login prompt that asks for a new one while it is set
ROOT_HASH=$(openssl passwd -1 -salt shednaja rockchip)
case "$ROOT_HASH" in '$1$shednaja$'*) ;; *) echo "openssl passwd failed" >&2; exit 1 ;; esac
echo "$ROOT_HASH" > "$OUT/root.hash"
mkdir -p "$OUT/lite/profile.d"
cp "$BOARD/overlay/etc/profile.d/shednaja-password.sh" "$OUT/lite/profile.d/"

# versions the install script needs
cat > "$OUT/versions" <<EOF
KLIPPER_VERSION=$KV
KLIPPER_DESCRIBE=$(mkver KLIPPER_DESCRIBE klipper)
MOONRAKER_RELEASE=$(mkver MOONRAKER_RELEASE moonraker)
HELIXSCREEN_VERSION=$(mkver HELIXSCREEN_VERSION helixscreen)
EOF

# Lite's files, unchanged
O=$BOARD/overlay
mkdir -p "$OUT/lite/extras" "$OUT/lite/libexec" "$OUT/lite/init" "$OUT/lite/sbin" "$OUT/lite/etc"
cp "$O"/usr/lib/klipper/klippy/extras/*.py "$OUT/lite/extras/"
cp "$O"/usr/libexec/kobra/{current-slot,helix-defaults,printer-data-init} "$OUT/lite/libexec/"
cp "$O"/usr/sbin/{kobra-config-migrate,kobra-update} "$OUT/lite/sbin/"
cp "$O"/etc/init.d/{S25kobra-usb,S27kobra-usbupdate,S60klipper,S61moonraker,S70helixscreen} "$OUT/lite/init/"
cp "$PKG/klipper-host-mcu/S59klipper-mcu" "$PKG/kobra-webcam/src/S65webcam" "$OUT/lite/init/"
cp "$O/etc/lighttpd/lighttpd.conf" "$OUT/lite/etc/"
cp -a "$BOARD/printer_data_defaults" "$OUT/lite/printer_data_defaults"
cp -a "$BOARD/klipper_config" "$OUT/lite/klipper_config"

# the install script and units
cp "$ROOT/armbian_build/stack/install-stack.sh" "$OUT/"
cp -a "$ROOT/armbian_build/stack/systemd" "$OUT/systemd"
cp "$ROOT"/armbian_build/stack/kobra-data-seed "$OUT/"
echo "staged into $OUT ($(du -sh "$OUT" | cut -f1))"
