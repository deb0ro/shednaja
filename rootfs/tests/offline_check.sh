#!/usr/bin/env bash
# Offline checks of the built rootfs (Buildroot target dir) under qemu-arm-static, no board:
#  1. klippy loads the default printer.cfg in batch mode (-o/-d) against the MCU data
#     dictionaries (both MCUs: the Anycubic firmware v1.4.3 from build/stock, see below;
#     host: the klipper_mcu build) and runs a few G-codes.
#  2. Moonraker imports, starts with the default moonraker.conf and answers
#     /server/info on 127.0.0.1:7125 (no klippy connected).
#  3. lighttpd accepts /etc/lighttpd/lighttpd.conf (-tt).
#
#   bash rootfs/tests/offline_check.sh [target dir]      (WSL)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=${1:-$HOME/kobra/rootfs-out/target}
Q="qemu-arm-static -L $T"
W=$(mktemp -d); trap 'kill $MR_PID 2>/dev/null; rm -rf "$W"' EXIT
fail=0
# MCU dictionaries: the Anycubic firmware v1.4.3 the printer runs by default (from the
# official update, see docs/mcu.md), else the fork builds. Override with
# MCU_DICT / NOZZLE_DICT.
STOCK_DICT=$ROOT/build/stock/firmware_v1.4.3.dict	# tools/fetch_stock.sh
if [ -f "$STOCK_DICT" ]; then
	MCU_DICT=${MCU_DICT:-$STOCK_DICT}; NOZZLE_DICT=${NOZZLE_DICT:-$STOCK_DICT}
else
	MCU_DICT=${MCU_DICT:-$ROOT/build/mcu/klipper.dict}; NOZZLE_DICT=${NOZZLE_DICT:-$ROOT/build/mcu/cs1237/klipper.dict}
fi
# [mcu host] (klipper_mcu, kobra_peripherals.cfg): dictionary from the klipper-host-mcu build
HOSTDICT=$(ls -d "$T"/../build/klipper-host-mcu-*/out/klipper.dict 2>/dev/null | head -n 1)
pd=$W/printer_data; mkdir -p $pd/logs $pd/gcodes $pd/database
cp -a "$T/usr/share/shednaja/printer_data/config" $pd/
# printer.cfg includes the shipped files from the image: point it at the target dir's copy
sed -i -e "s|/useremain/shednaja/printer_data|$pd|" -e "s|/usr/share/shednaja/klipper/|$T/usr/share/shednaja/klipper/|" \
	$pd/config/printer.cfg

echo "== 1. klippy batch config check"
printf 'G28 X Y\nG1 X100 Y100 F6000\nM104 S0\nM140 S0\nM106 S128\nM106 P2 S100\nM107\nM107 P2\nQUERY_ENDSTOPS\n' > $W/test.gcode
krc=0
(cd "$T/usr/lib/klipper/klippy" && $Q "$T/usr/bin/python3" klippy.py $pd/config/printer.cfg \
	-i $W/test.gcode -o $W/out.serial -l $W/klippy.log \
	-d "$MCU_DICT" -d "nozzle_mcu=$NOZZLE_DICT" -d "host=$HOSTDICT") > $W/klippy.stdout 2>&1 || krc=$?
echo "   dictionaries: mcu $(basename "$MCU_DICT"), nozzle_mcu $(basename "$NOZZLE_DICT")"
if [ $krc != 0 ] || [ ! -s $W/out.serial ] ||
   grep -qiE "config error|error loading|Traceback|Unknown command|is not a valid" $W/klippy.log $W/klippy.stdout; then
	echo "FAIL: klippy exit $krc, $(stat -c %s $W/out.serial 2>/dev/null || echo 0) bytes of MCU commands"
	grep -iE -B2 -A6 "config error|error loading|Traceback|Unknown command|is not a valid" $W/klippy.log $W/klippy.stdout | head -40
	tail -5 $W/klippy.stdout; fail=1
else
	echo "OK: config loaded, $(stat -c %s $W/out.serial) bytes of MCU commands generated"
	grep -m3 -E "^Loaded MCU|Configured MCU|Starting Klippy" $W/klippy.log
fi

echo "== 2. moonraker start + /server/info"
sed -i "s|/tmp/klippy_uds|$W/klippy_uds|" $pd/config/moonraker.conf
(cd / && HOME=$W PYTHONPATH=/usr/lib/moonraker $Q "$T/usr/bin/python3" -m moonraker -d $pd > $W/moonraker.stdout 2>&1) &
MR_PID=$!
ok=0
for i in $(seq 1 60); do
	if curl -sf http://127.0.0.1:7125/server/info > $W/info.json 2>/dev/null; then ok=1; break; fi
	sleep 2
done
if [ $ok = 1 ]; then
	# a failed component is a failure; warnings are listed
	if python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["result"]; print("moonraker", r.get("moonraker_version"), "components:", len(r.get("components", [])), "failed:", r.get("failed_components"), "warnings:", len(r.get("warnings", []))); sys.exit(1 if r.get("failed_components") else 0)' $W/info.json > $W/mr.txt; then
		echo "OK: $(cat $W/mr.txt)"
	else
		echo "FAIL: $(cat $W/mr.txt)"; fail=1
	fi
	python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["result"]; [print("   warning:", w[:160]) for w in r.get("warnings", [])]' $W/info.json
else
	echo "FAIL: no answer from moonraker"; tail -30 $W/moonraker.stdout $pd/logs/moonraker.log 2>/dev/null; fail=1
fi
echo "== 3. lighttpd config + live proxy (port 8080 instead of 80, no user switch)"
mkdir -p $W/lt && sed -e "s|/useremain/shednaja/printer_data/logs|$W/lt|; s|/useremain/shednaja/tmp|$W/lt|; s|/usr/share/mainsail|$T/usr/share/mainsail|" \
	-e "s|^server.port .*|server.port = 8080|; /^server.username/d; /^server.groupname/d; s|/run/lighttpd.pid|$W/lt/pid|" \
	"$T/etc/lighttpd/lighttpd.conf" > $W/lt/lighttpd.conf
if $Q "$T/usr/sbin/lighttpd" -tt -f $W/lt/lighttpd.conf -m "$T/usr/lib/lighttpd" > $W/lt/out 2>&1; then
	echo "OK: lighttpd -tt"
	$Q "$T/usr/sbin/lighttpd" -D -f $W/lt/lighttpd.conf -m "$T/usr/lib/lighttpd" > $W/lt/run 2>&1 &
	LT_PID=$!; sleep 3
	c_index=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)
	c_spa=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/history)
	c_api=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/server/info)
	c_ws=$(curl -s -o /dev/null -m 3 -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
		-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:8080/websocket)
	kill $LT_PID 2>/dev/null
	echo "   / -> $c_index, /history (SPA) -> $c_spa, /server/info (proxy) -> $c_api, /websocket upgrade -> $c_ws"
	[ "$c_index" = 200 ] && [ "$c_spa" = 200 ] && [ "$c_api" = 200 ] && [ "$c_ws" = 101 ] && echo "OK: web + proxy" || { echo "FAIL: web/proxy"; cat $W/lt/run $W/lt/*.log 2>/dev/null | tail; fail=1; }
else
	echo "FAIL:"; cat $W/lt/out; fail=1
fi
kill $MR_PID 2>/dev/null

[ $fail = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
