#!/usr/bin/env bash
# Check that kobra-abctl changes the misc A/B data exactly like the stock rk_ota.
# Runs the stock /usr/bin/rk_ota under qemu-arm-static (WSL) on copies of our misc dump
# with several slot states, and compares the first 2080 bytes. (rk_ota opens the device
# with truncate; on a regular file that cuts it after its write, on a block device
# it does not, so only the bytes up to the end of AvbABData are compared.)
#
#   bash rootfs/package/kobra-abctl/test/compare_with_rk_ota.sh [dump dir]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
DUMP=${1:-$ROOT/dumps/emmc_20261020_095608}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
command -v qemu-arm-static >/dev/null || { echo "needs qemu-arm-static"; exit 1; }

# stock rk_ota + its uClibc libs as qemu sysroot; misc and cmdline faked in there
mkdir -p "$W/sys" "$W/r/dev/block/by-name" "$W/r/proc" "$W/r/usr/bin"
unsquashfs -q -no-xattrs -d "$W/sys/s" "$DUMP/system_a.img" lib usr/bin/rk_ota >/dev/null
cp -a "$W/sys/s/lib" "$W/r/"; cp "$W/sys/s/usr/bin/rk_ota" "$W/r/usr/bin/"
echo "root=/dev/mmcblk0p9" > "$W/r/proc/cmdline"
gcc -O2 -Wall -o "$W/abctl" "$ROOT/rootfs/package/kobra-abctl/src/kobra-abctl.c"

setstate() {	# <file> [a|b.prio|tries|succ=N ...]: edit AvbABData, fix crc (big endian)
	python3 -I - "$@" <<'EOF'
import struct, sys, zlib
f, sets = sys.argv[1], sys.argv[2:]
b = bytearray(open(f, 'rb').read()); o = 2048
for s in sets:
    slot, rest = s.split('.'); k, v = rest.split('=')
    b[o + 8 + (0 if slot == 'a' else 4) + {'prio': 0, 'tries': 1, 'succ': 2}[k]] = int(v)
struct.pack_into('>I', b, o + 28, zlib.crc32(bytes(b[o:o + 28])))
open(f, 'wb').write(b)
EOF
}

fail=0
M=$W/r/dev/block/by-name/misc
for st in "" "b.tries=5" "b.tries=0 b.succ=1" "b.prio=14 a.prio=15 a.tries=3" \
          "a.prio=15 b.prio=14 b.tries=0 b.succ=1" "a.tries=1 b.tries=2"; do
	for cmd in now other; do
		cp "$DUMP/misc.img" "$M"; setstate "$M" $st; cp "$M" "$W/ours.img"
		qemu-arm-static -L "$W/r" "$W/r/usr/bin/rk_ota" --misc=$cmd --mode=retry >/dev/null 2>&1
		"$W/abctl" $cmd "$W/ours.img" >/dev/null
		if cmp -s -n 2080 "$M" "$W/ours.img"; then r=same; else r=DIFF; fail=1; fi
		printf '%-44s %-6s %s\n' "[$st]" "$cmd" "$r"
	done
done
[ $fail = 0 ] && echo "PASS: kobra-abctl == rk_ota" || { echo "FAIL"; exit 1; }
