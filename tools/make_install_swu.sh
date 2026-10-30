#!/usr/bin/env bash
# Pack a ShedNaja update bundle into a USB installer for the stock firmware: the stock
# USB updater runs swu/shednaja_install/update.sh, which writes the slot stock is not
# running from and boots it.
#   bash tools/make_install_swu.sh [bundle.tar]     (default: newest in build/update)
# Output: build/install/aGVscF9zb3Nf/update.swu (an Armbian bundle: build/install-armbian/...)
# - copy the aGVscF9zb3Nf folder to the root
# of a FAT32 USB stick.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE="${1:-$(ls -t build/update/shednaja-update-*.tar | head -n 1)}"
[ -f "$BUNDLE" ] || { echo "no bundle $BUNDLE"; exit 1; }
# a first install writes the whole system (boot + system; oem is optional): refuse partial
# update bundles
for part in boot system; do
	tar -xOf "$BUNDLE" manifest | grep -q "^image $part $part.img " ||
		{ echo "$BUNDLE has no $part image - an installer needs a complete bundle"; exit 1; }
done
WORK=$(mktemp -d)
mkdir -p "$WORK/payload"
tar -xf "$BUNDLE" -C "$WORK/payload"
cp swu/shednaja_install/update.sh "$WORK/payload/"
# the installer checks the images with md5 (stock's busybox has no sha256sum): the md5 sums
# are made from images that match the manifest's sha256, so the two can never disagree
( cd "$WORK/payload" && awk '$1 == "image" {print $5 "  " $3}' manifest | sha256sum -c --quiet ) ||
	{ echo "$BUNDLE: an image does not match the sha256 in its manifest"; rm -rf "$WORK"; exit 1; }
( cd "$WORK/payload" && awk '$1 == "image" {print $3}' manifest | xargs md5sum > md5sums )
OUT=build/install/aGVscF9zb3Nf/update.swu
# the Armbian variant gets its own folder, so the two installers are not mixed up
case "$(tar -xOf "$BUNDLE" manifest)" in *variant=armbian*) OUT=build/install-armbian/aGVscF9zb3Nf/update.swu ;; esac
bash tools/make_swu.sh "$WORK/payload" "$OUT"
rm -rf "$WORK"
echo "installer for $(tar -xOf "$BUNDLE" manifest | sed -n 's/^build_id=//p'): $OUT"
