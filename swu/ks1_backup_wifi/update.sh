#!/bin/sh
# Kobra S1 test-board tool, run by the stock USB updater (/userdata/channel.sh) as root.
#  1. full eMMC backup (all partitions except useremain) to the USB stick, md5-verified
#  2. installs the bundled Wi-Fi config into /userdata/wifi_cfg (old one kept as .bak_tool)
#  3. brings wlan0 up and writes the obtained IP address to the USB stick
# The only eMMC write is the Wi-Fi config file on /userdata.
# Beeps: 1 short = started, 2 short = backup done, 3 long = all done, 5 short = error.

HERE=$(cd "$(dirname "$0")" && pwd)
USB=/mnt/udisk
SER=$(grep -m1 Serial /proc/cpuinfo | awk '{print $3}')
[ -n "$SER" ] || SER=unknown
OUT="$USB/kobra_backup_$SER"
PARTS="env idblock uboot_a uboot_b misc boot_a boot_b system_a system_b oem_a oem_b userdata ac_lib_a ac_lib_b ac_app_a ac_app_b"

beep() {  # beep <count> <on-usec>
    i=0
    while [ $i -lt "$1" ]; do
        echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable; usleep "$2"
        echo 0 > /sys/class/pwm/pwmchip0/pwm0/enable; usleep 200000
        i=$((i + 1))
    done
}

fail() { echo "ERROR: $*"; sync; beep 5 150000; exit 1; }

mkdir -p "$OUT" || { beep 5 150000; exit 1; }
exec >> "$OUT/tool.log" 2>&1
echo "===== $(date) kobra test-board tool"
beep 1 150000

echo "--- system info"
uname -a; cat /proc/cmdline; echo
cat /proc/partitions; echo
cat /sys/block/mmcblk0/device/cid 2>/dev/null
cat /useremain/dev/version 2>/dev/null; echo
head -5 /userdata/app/gk/version_log.txt 2>/dev/null
df -h "$USB"

echo "--- eMMC backup to $OUT"
: > "$OUT/md5.txt"
dd if=/dev/mmcblk0 of="$OUT/raw_head_0-32K.img" bs=32k count=1 2>/dev/null
for p in $PARTS; do
    dev=/dev/block/by-name/$p
    [ -e "$dev" ] || { echo "missing $dev"; continue; }
    dd if="$dev" of="$OUT/$p.img" bs=64k 2>/dev/null || fail "dd $p"
    sync
    src=$(md5sum "$dev" | cut -d' ' -f1)
    dst=$(md5sum "$OUT/$p.img" | cut -d' ' -f1)
    st=OK; [ "$src" = "$dst" ] || st=MISMATCH
    echo "$p $(wc -c < "$OUT/$p.img") $src $st" | tee -a "$OUT/md5.txt"
    [ "$st" = OK ] || fail "md5 mismatch on $p"
done
sync
beep 2 150000

echo "--- Wi-Fi config"
mkdir -p /userdata/wifi_cfg
[ -f /userdata/wifi_cfg/wpa_supplicant.conf ] && cp -f /userdata/wifi_cfg/wpa_supplicant.conf /userdata/wifi_cfg/wpa_supplicant.conf.bak_tool
cp -f "$HERE/wpa_supplicant.conf" /userdata/wifi_cfg/wpa_supplicant.conf || fail "copy wifi cfg"
chmod 644 /userdata/wifi_cfg/wpa_supplicant.conf
sync
echo "installed /userdata/wifi_cfg/wpa_supplicant.conf"

echo "--- bring up wlan0"
ifconfig wlan0 || echo "no wlan0 interface"
killall wpa_supplicant 2>/dev/null; sleep 1
wpa_supplicant -B -Dnl80211 -i wlan0 -c /userdata/wifi_cfg/wpa_supplicant.conf
n=0
while [ $n -lt 30 ]; do
    wpa_cli -i wlan0 status 2>/dev/null | grep -q "wpa_state=COMPLETED" && break
    sleep 1; n=$((n + 1))
done
wpa_cli -i wlan0 status 2>/dev/null | grep -E "ssid|wpa_state|ip_address"
udhcpc -i wlan0 -n -q -t 10 -x hostname:kobra-ks1-test 2>&1 | tail -3
ifconfig wlan0 | tee "$OUT/ip.txt"

echo "DONE $(date)"
echo done > "$OUT/DONE"
sync
beep 3 600000
