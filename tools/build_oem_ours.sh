#!/usr/bin/env bash
# Build an oem image for the slot that will run our own kernel: the stock oem squashfs
# with RTL8723DS.ko, hci_uart.ko and cfg80211.ko replaced by the modules built against
# our kernel (build/kernel/oem-ko/). Everything else keeps its content; the stock
# security.selinux xattrs are dropped (our kernel has no SELinux / SQUASHFS_XATTR).
#   bash tools/build_oem_ours.sh [stock_oem.img] [out.img]       (runs in WSL)
set -euo pipefail
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    here=$(cd "$(dirname "$0")/.." && pwd)
    wpath="/mnt/$(echo "${here:1:1}" | tr 'A-Z' 'a-z')${here:2}"
    MSYS_NO_PATHCONV=1 exec wsl -d Ubuntu-24.04 -- bash "$wpath/tools/build_oem_ours.sh" "$@" ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN=${1:-$ROOT/build/stock/oem.img}     # tools/fetch_stock.sh
OUT=${2:-$ROOT/build/kernel/oem_ours.img}
KO=$ROOT/build/kernel/oem-ko
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "== stock superblock"
unsquashfs -stat "$IN" | grep -E "Compression|Block size|Filesystem size|Number of inodes|xattr|Mkfs time" || true
unsquashfs -no-xattrs -no-progress -quiet -d "$W/root" "$IN" >/dev/null

echo "== owners in stock image (uid/gid)"
unsquashfs -lln "$IN" | awk '{print $2}' | sort | uniq -c

for m in RTL8723DS.ko hci_uart.ko cfg80211.ko; do
    [ -f "$W/root/usr/ko/$m" ] || { echo "stock image has no usr/ko/$m"; exit 1; }
    printf '%-14s stock %8d B -> ours %8d B\n' "$m" "$(stat -c %s "$W/root/usr/ko/$m")" "$(stat -c %s "$KO/$m")"
    cp -f "$KO/$m" "$W/root/usr/ko/$m"
    chmod 644 "$W/root/usr/ko/$m"
done

# keep stock mode/ownership for every entry (174x 0/0, 10x 1000/1000 libdrm/libkms/modetest)
# via a mksquashfs pseudo file "path m mode uid gid"; paths are relative to the image root
unsquashfs -lln -d "" "$IN" | awk '$6 != "" && $6 != "/" {
    split($2, o, "/"); p = substr($6, 2)
    m = $1; mode = 0
    for (i = 2; i <= 10; i++) { c = substr(m, i, 1); if (c != "-") mode += 2^(10 - i) }
    if (substr(m, 4, 1) == "s") mode += 2048
    if (substr(m, 7, 1) == "s") mode += 1024
    printf "%s m %o %s %s\n", p, mode, o[1], o[2] }' > "$W/owners.pseudo"
echo "pseudo entries: $(wc -l < "$W/owners.pseudo"), non-root: $(grep -vc ' 0 0$' "$W/owners.pseudo")"

# same compressor/block size as stock (xz, 128 KiB), fixed timestamps
mkdir -p "$(dirname "$OUT")"
mksquashfs "$W/root" "$OUT" -noappend -comp xz -b 131072 -no-xattrs -root-uid 0 -root-gid 0 -root-mode 0755 -no-progress -quiet \
    -pf "$W/owners.pseudo" \
    -mkfs-time "$(unsquashfs -mkfs-time "$IN")" -all-time "$(unsquashfs -mkfs-time "$IN")" >/dev/null

echo "== result"
unsquashfs -stat "$OUT" | grep -E "Compression|Block size|Filesystem size|Number of inodes"
echo "files differing from stock (content):"
unsquashfs -no-xattrs -no-progress -quiet -d "$W/check" "$OUT" >/dev/null
unsquashfs -no-xattrs -no-progress -quiet -d "$W/stock" "$IN" >/dev/null
diff -rq "$W/stock" "$W/check" || true
echo "metadata (mode/owner/name) differences vs stock:"
diff <(unsquashfs -lln -d "" "$IN" | awk '{print $1, $2, $6}' | sort -k3) \
     <(unsquashfs -lln -d "" "$OUT" | awk '{print $1, $2, $6}' | sort -k3) || true
ls -l "$OUT"; sha256sum "$OUT"
