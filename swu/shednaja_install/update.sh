#!/bin/sh
# ShedNaja installer, run by the stock USB updater (/userdata/channel.sh) as root on
# the stock firmware. Stock may run from slot A or B (an official update moves it to the
# other slot), so the bundled boot/system images go into the slot stock is NOT running
# from; each one is verified by reading it back, then that slot becomes the boot slot and
# the printer reboots into it. The running stock slot and /userdata are never written.
# Images already in the target slot are not written again, so the same stick also
# switches back to ShedNaja after REBOOT_TO_STOCK.
# A first install needs the complete system: the bundle must hold boot and system (a
# partial update bundle would leave a mix of stock and ShedNaja in the target slot). The
# oem partition is not needed by ShedNaja and stays as stock left it, unless a (development)
# bundle carries an oem image.
# Log: shednaja-install.log on the USB stick.
# Beeps: 1 short = started, 3 long = done (rebooting), 5 short = error (nothing switched).

HERE=$(cd "$(dirname "$0")" && pwd)
USB=/mnt/udisk
LOG=$USB/shednaja-install.log
[ -d $USB ] || LOG=/useremain/shednaja-install.log

beep() {  # beep <count> <on-usec>
    i=0
    while [ $i -lt "$1" ]; do
        echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable; usleep "$2"
        echo 0 > /sys/class/pwm/pwmchip0/pwm0/enable; usleep 200000
        i=$((i + 1))
    done
}
cleanup() { cd /; rm -rf /useremain/update_swu; sync; }
fail() { echo "ERROR: $* - nothing activated, the printer stays on stock"; cleanup; beep 5 150000; exit 1; }

exec >> "$LOG" 2>&1
echo "===== $(date) ShedNaja installer $(sed -n 's/^build_id=//p' "$HERE/manifest")"
beep 1 150000

root=$(tr ' ' '\n' < /proc/cmdline | sed -n 's#^root=/dev/mmcblk0p##p')
case "$root" in
    8) T=b ;;	# stock in slot A (system_a) -> we go to slot B
    9) T=a ;;	# stock in slot B (system_b) -> we go to slot A
    *) fail "unknown root partition p$root" ;;
esac
echo "stock runs from root=p$root - installing into slot $T"
command -v rk_ota >/dev/null || fail "rk_ota missing"

# manifest: "image <part> <file> <size> <sha256>", md5sums: "<md5>  <file>" (stock busybox
# has no sha256sum)
WRITE=""
SEEN=""
while read -r kind part file size sum extra; do
    [ "$kind" = image ] || continue
    case "$part" in boot|oem|system) ;; *) fail "unknown partition in manifest" ;; esac
    case " $SEEN " in *" $part "*) fail "partition $part twice in manifest" ;; esac
    SEEN="$SEEN $part"
    [ "$file" = "$part.img" ] || fail "$part: image must be named $part.img"
    case "$size" in ''|*[!0-9]*) fail "$part: bad size in manifest" ;; esac
    [ -z "$extra" ] || fail "$part: extra fields in manifest"
    f=$HERE/$file; dev=/dev/block/by-name/${part}_$T
    md5=$(sed -n "s/^\([0-9a-f]*\) [ *]*$file\$/\1/p" "$HERE/md5sums")
    [ -n "$md5" ] || fail "no md5 for $file"
    [ "$(wc -c < "$f")" = "$size" ] || fail "$file: wrong size"
    [ "$(md5sum "$f" | cut -d' ' -f1)" = "$md5" ] || fail "$file: md5 mismatch (damaged stick?)"
    [ -b "$dev" ] || fail "missing $dev"
    psize=$(($(cat /sys/class/block/$(basename "$(readlink -f "$dev")")/size) * 512))
    [ "$size" -le "$psize" ] || fail "$file larger than ${part}_$T"
    grep -q "^$(readlink -f "$dev") " /proc/mounts && fail "${part}_$T is mounted"
    if [ "$(head -c "$size" "$dev" | md5sum | cut -d' ' -f1)" = "$md5" ]; then
        echo "${part}_$T already up to date"
    else
        WRITE="$WRITE $part:$file:$size:$md5"
    fi
done < "$HERE/manifest"
for part in boot system; do
    case " $SEEN " in *" $part "*) ;; *) fail "incomplete bundle: no $part image (a first install needs boot and system)" ;; esac
done

for item in $WRITE; do
    set -- $(echo "$item" | tr : ' ')
    part=$1 file=$2 size=$3 md5=$4 dev=/dev/block/by-name/$1_$T
    ok=0
    for try in 1 2; do
        dd if="$HERE/$file" of="$dev" bs=64k conv=fsync 2>/dev/null
        sync
        echo 3 > /proc/sys/vm/drop_caches
        if [ "$(head -c "$size" "$dev" | md5sum | cut -d' ' -f1)" = "$md5" ]; then ok=1; break; fi
        echo "${part}_$T: readback mismatch (try $try)"
    done
    [ $ok = 1 ] || fail "${part}_$T write failed"
    echo "${part}_$T written and verified"
done

# kobra-update / the USB updater on ShedNaja compare against this
mkdir -p /useremain/shednaja/update
cp "$HERE/manifest" /useremain/shednaja/update/installed.manifest

rk_ota --misc=other --mode=retry 2>&1 | grep -E 'A/B'
rk_ota --misc=display 2>&1 | grep -E 'priority|tries|successful'
echo "slot $T active - rebooting into ShedNaja $(date)"
cleanup
beep 3 600000
reboot
