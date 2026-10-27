#!/usr/bin/env bash
# Smoke test of a printer running ShedNaja, after an install or update (read-only: it
# starts no print, moves nothing and changes no file).
#   bash tools/printer_smoke.sh <printer-ip> [expected build id]
# Environment: SSH_KEY (default keys/kobra_ed25519), KNOWN_HOSTS (default
#   keys/known_hosts_shednaja, else ssh's own), WAIT (seconds for Klipper, default 120).
# Prints PASS / WARN / FAIL / INFO lines; exit status 1 if anything failed.
set -euo pipefail
cd "$(dirname "$0")/.."
IP="${1:?usage: printer_smoke.sh <printer-ip> [expected build id]}"
EXPECT="${2:-}"
KEY=${SSH_KEY:-keys/kobra_ed25519}
KH=${KNOWN_HOSTS:-keys/known_hosts_shednaja}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
[ -f "$KEY" ] && SSH+=(-i "$KEY")
[ -f "$KH" ] && SSH+=(-o UserKnownHostsFile="$KH")

# the checks run on the printer (busybox sh); the result is the only output
"${SSH[@]}" "root@$IP" "EXPECT='$EXPECT' WAIT='${WAIT:-120}' sh -s" <<'REMOTE'
FAILS=0
pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "INFO  $*"; }
api() { wget -qO- "http://127.0.0.1:7125$1" 2>/dev/null; }

# build
. /etc/os-release 2>/dev/null
if [ "${ID:-}" != shednaja ]; then echo "FAIL  not ShedNaja (os-release ID=${ID:-none})"; exit 1; fi
if [ -n "$EXPECT" ] && [ "$BUILD_ID" != "$EXPECT" ]; then fail "build $BUILD_ID, expected $EXPECT"
else pass "build $BUILD_ID"; fi
case "$BUILD_ID" in *devkey*|*unpinned*|*dirty*) warn "build id marks a development build: $BUILD_ID" ;; esac

# A/B: the running slot boots first and was re-armed by kobra-bootok
s=$(/usr/libexec/kobra/current-slot)
if [ -z "$s" ]; then fail "running slot unknown (/proc/cmdline)"
else
	ab=$(kobra-abctl display 2>&1)
	me=$(echo "$ab" | sed -n "s/^slot $s: priority \([0-9]*\) tries_remaining \([0-9]*\).*/\1 \2/p")
	o=$([ "$s" = a ] && echo b || echo a)
	other=$(echo "$ab" | sed -n "s/^slot $o: priority \([0-9]*\).*/\1/p")
	set -- $me
	if [ -n "${1:-}" ] && [ -n "$other" ] && [ "$1" -gt "$other" ]; then pass "slot $s boots first (priority $1, other $other)"
	else fail "slot $s is not the highest priority: $(echo "$ab" | head -2 | tr '\n' ';')"; fi
	if dmesg | grep -q 'kobra-bootok: slot re-armed'; then
		[ "${2:-}" = 7 ] && pass "slot $s re-armed (tries 7)" || fail "slot $s tries_remaining ${2:-?} after kobra-bootok"
	else fail "kobra-bootok has not run (boot not finished or failed)"; fi
fi

# storage
for m in /userdata /useremain; do
	if grep -q " $m [^ ]* rw[ ,]" /proc/mounts; then pass "$m mounted rw"; else fail "$m not mounted rw"; fi
done
info "/useremain free: $(df -h /useremain | tail -n 1 | awk '{ print $(NF - 2) }')"

# Klipper and Moonraker
i=0; st=""
while [ $i -lt "$WAIT" ]; do
	st=$(api '/printer/objects/query?webhooks=state' | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
	[ "$st" = ready ] && break
	sleep 3; i=$((i + 3))
done
if [ "$st" = ready ]; then pass "Klipper ready"
else
	msg=$(api '/printer/info' | sed -n 's/.*"state_message": *"\([^"]*\)".*/\1/p' | cut -c1-160)
	fail "Klipper ${st:-not answering} after ${WAIT}s: $msg"
fi
si=$(api /server/info)
if [ -z "$si" ]; then fail "Moonraker not answering"
else
	fc=$(echo "$si" | sed -n 's/.*"failed_components": *\[\([^]]*\)\].*/\1/p')
	[ -z "$fc" ] && pass "Moonraker: no failed components" || fail "Moonraker failed components: $fc"
	wn=$(echo "$si" | sed -n 's/.*"warnings": *\[\([^]]*\)\].*/\1/p' | cut -c1-200)
	[ -z "$wn" ] || warn "Moonraker warnings: $wn"
fi
ps_=$(api '/printer/objects/query?print_stats=state' | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
info "print state: ${ps_:-unknown}"

# web UI and display
if wget -qO- http://127.0.0.1/ 2>/dev/null | grep -qi mainsail; then pass "Mainsail served by lighttpd"
else fail "Mainsail not served on port 80"; fi
if ps | grep -v grep | grep -q '/opt/helixscreen/bin/helix-screen'; then pass "HelixScreen running"
else fail "HelixScreen not running"; fi

# camera (only when enabled in webcam.conf)
if grep -q '^WEBCAM_ENABLE=0' /useremain/shednaja/printer_data/config/webcam.conf 2>/dev/null; then
	info "camera disabled in webcam.conf"
elif wget -qO /tmp/.smoke.jpg 'http://127.0.0.1/webcam/?action=snapshot' 2>/dev/null &&
	[ "$(head -c 2 /tmp/.smoke.jpg | od -An -tx1 | tr -d ' ')" = ffd8 ]; then
	pass "camera snapshot ($(wc -c < /tmp/.smoke.jpg) B JPEG)"
else fail "no camera snapshot"; fi
rm -f /tmp/.smoke.jpg
w=$(dmesg | grep 'webcam: ignoring' | tail -1)
[ -z "$w" ] || warn "webcam.conf (since boot): ${w#*] }"

# network and Bluetooth
wip=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
[ -n "$wip" ] && pass "Wi-Fi wlan0 $wip" || warn "wlan0 has no IPv4 address"
if [ -e /sys/class/bluetooth/hci0 ]; then pass "Bluetooth hci0 (firmware: $(readlink /run/rtlbt))"
else fail "no Bluetooth hci0"; fi

# config and security notes
C=/useremain/shednaja/printer_data/config
if grep -q '^\[include /usr/share/shednaja/klipper/' $C/printer.cfg 2>/dev/null; then
	pass "printer.cfg includes the image's Klipper config"
else warn "printer.cfg does not include /usr/share/shednaja/klipper (old layout or edited)"; fi
# copies still included by bare name (edited, so kobra-config-migrate left them)
k=""
for f in mainsail.cfg kobra_s1.cfg kobra_macros.cfg kobra_peripherals.cfg; do
	grep -qE "^[[:space:]]*\[include[[:space:]]+$(echo $f | sed 's/\./\\./')[[:space:]]*\]" $C/printer.cfg 2>/dev/null && k="$k $f"
done
[ -z "$k" ] || warn "own copies in use, no updates for them:$k (kobra-config-migrate --force)"
r=$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow 2>/dev/null)
d=$(sed -n 's/^root:\([^:]*\):.*/\1/p' /usr/share/shednaja/shadow.default 2>/dev/null)
[ -n "$r" ] && [ "$r" = "$d" ] && warn "root still has the default password" || pass "root password changed"
info "uptime $(cut -d' ' -f1 /proc/uptime) s"

if [ $FAILS = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($FAILS)"; exit 1; fi
REMOTE
