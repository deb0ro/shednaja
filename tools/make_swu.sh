#!/usr/bin/env bash
# Pack a directory with update.sh (+ payload) into a Kobra S1 USB update package.
#   bash tools/make_swu.sh swu/ks1_backup_wifi build/ks1_backup_wifi.swu
# Layout expected by the stock /userdata/channel.sh:
#   zip (ZipCrypto, password below) -> update_swu/setup.tar.gz -> update.sh + files
# Copy the result to the USB stick (FAT32) as  aGVscF9zb3Nf/update.swu
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$1"; OUT="$2"
# password from the stock /userdata/channel.sh (also published by the Rinkhals project)
PASS='U2FsdGVkX1+lG6cHmshPLI/LaQr9cZCjA8HZt6Y8qmbB7riY'
# 7-Zip on Windows (Git Bash), Info-ZIP zip elsewhere; both write ZipCrypto by default
SEVENZIP="/c/Program Files/7-Zip/7z.exe"

[ -f "$SRC/update.sh" ] || { echo "no $SRC/update.sh"; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$WORK/payload" "$WORK/zip/update_swu"
cp -r "$SRC"/. "$WORK/payload/"
# shell scripts must have LF line endings on the printer
find "$WORK/payload" -name '*.sh' -exec sed -i 's/\r$//' {} +
chmod 755 "$WORK/payload/update.sh"
tar --owner=0 --group=0 -czf "$WORK/zip/update_swu/setup.tar.gz" -C "$WORK/payload" .
rm -f "$OUT"; mkdir -p "$(dirname "$OUT")"
if [ -x "$SEVENZIP" ]; then
	( cd "$WORK/zip" && "$SEVENZIP" a -tzip -mem=ZipCrypto -p"$PASS" "$(cygpath -w "$PWD/../out.zip")" update_swu >/dev/null )
else
	command -v zip >/dev/null || { echo "needs zip (or 7-Zip on Windows)"; exit 1; }
	( cd "$WORK/zip" && zip -q -r -P "$PASS" ../out.zip update_swu )
fi
mv "$WORK/out.zip" "$OUT"
echo "built $OUT"
unzip -l "$OUT"
tar -tzvf "$WORK/zip/update_swu/setup.tar.gz"
rm -rf "$WORK"
