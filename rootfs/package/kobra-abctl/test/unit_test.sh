#!/usr/bin/env bash
# kobra-abctl on hand-made misc images, no stock firmware needed (CI). The comparison with
# the stock rk_ota is compare_with_rk_ota.sh.
#
#   bash rootfs/package/kobra-abctl/test/unit_test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
gcc -O2 -Wall -Wextra -Werror -o "$W/abctl" "$ROOT/rootfs/package/kobra-abctl/src/kobra-abctl.c"

mk() {	# mk <prio a> <tries a> <succ a> <prio b> <tries b> <succ b>: write $W/misc
	python3 -I - "$W/misc" "$@" <<'PY'
import struct, sys, zlib
v = [int(x) for x in sys.argv[2:8]]
d = bytearray(b'\0AB0' + bytes([1, 0, 0, 0]) + bytes(v[0:3] + [0] + v[3:6] + [0]) + bytes(12))
d += struct.pack('>I', zlib.crc32(bytes(d)))
open(sys.argv[1], 'wb').write(bytes(2048) + d + bytes(1000))
PY
}
state() {	# "prio tries succ prio tries succ last_boot", fails on a bad crc
	python3 -I - "$W/misc" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()[2048:2080]
assert struct.unpack('>I', d[28:32])[0] == zlib.crc32(d[:28]), 'crc'
print(*(list(d[8:11]) + list(d[12:15]) + [d[16]]))
PY
}
fail=0
check() {	# check <name> <command...> -- <expected state>
	local name=$1; shift; local args=()
	while [ "$1" != -- ]; do args+=("$1"); shift; done; shift
	"$W/abctl" "${args[@]}" "$W/misc" > /dev/null
	local got; got=$(state)
	if [ "$got" = "$*" ]; then echo "ok   $name"; else echo "FAIL $name: got [$got], want [$*]"; fail=1; fi
}

# normal boot from A: now re-arms A
mk 15 5 1 14 7 1; check "now, A highest"            now            -- 15 7 0 14 7 1 0
# switch to the other slot
mk 15 7 1 14 7 1; check "other, A highest"          other          -- 14 7 1 15 7 0 0
# after a fallback: B (highest) out of tries, we run from A
mk 14 7 0 15 0 0; check "now --slot=a after fallback"   now --slot=a   -- 14 7 0 15 0 0 0
mk 14 7 0 15 0 0; check "other --slot=a after fallback" other --slot=a -- 14 7 0 15 7 0 0
# without --slot it acts on the highest priority, like rk_ota
mk 14 7 0 15 0 0; check "now without --slot (rk_ota)"   now            -- 14 7 0 15 7 0 1
mk 14 7 0 15 0 0; check "other without --slot (rk_ota)" other          -- 15 7 0 14 0 0 0
mk 14 7 0 15 2 0; check "now --slot=b"                  now --slot=b   -- 14 7 0 15 7 0 1

# refusals: bad crc, bad magic, bad arguments
mk 15 7 1 14 7 1; printf 'x' | dd of="$W/misc" bs=1 seek=2056 conv=notrunc 2>/dev/null
if "$W/abctl" now "$W/misc" 2>/dev/null; then echo "FAIL bad crc accepted"; fail=1; else echo "ok   bad crc refused"; fi
dd if=/dev/zero of="$W/misc" bs=4096 count=1 2>/dev/null
if "$W/abctl" display "$W/misc" 2>/dev/null; then echo "FAIL no magic accepted"; fail=1; else echo "ok   no AvbABData refused"; fi
for bad in "now --slot=c" "now --bogus" "now x y" "frob"; do
	rc=0; "$W/abctl" $bad 2>/dev/null || rc=$?
	if [ $rc = 2 ]; then echo "ok   usage: $bad"; else echo "FAIL usage: $bad (exit $rc)"; fail=1; fi
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
