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
# Armbian variant (manifest variant=armbian): the bundle also holds rootfs.tar.gz, the Debian
# root. boot/system (base kernel, loader) go into the slot as above; the root is moved to
# /useremain/armbian/install/ and unpacked by the Armbian loader on its first boot (stock's
# tar cannot keep numeric owners). Armbian's roots and data on useremain stay otherwise.
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
# Only stock 2.7.2.7 (and its MCU firmware) is tested; others are installed with a warning.
# The stock firmware keeps its version in /useremain/dev/version.
TESTED_STOCK=2.7.2.7
stock=$(tr -d ' \r\n' 2>/dev/null < /useremain/dev/version)
if [ "$stock" = "$TESTED_STOCK" ]; then
    echo "stock firmware $stock"
else
    echo "WARNING: stock firmware ${stock:-unknown}, ShedNaja is tested with $TESTED_STOCK only"
fi
command -v rk_ota >/dev/null || fail "rk_ota missing"
VARIANT=lite; grep -qx 'variant=armbian' "$HERE/manifest" && VARIANT=armbian
echo "variant $VARIANT"

# manifest: "image <part> <file> <size> <sha256>", md5sums: "<md5>  <file>" (stock busybox
# has no sha256sum)
WRITE=""
SEEN=""
while read -r kind part file size sum extra; do
    [ "$kind" = image ] || continue
    case "$part" in boot|oem|system|rootfs) ;; *) fail "unknown partition in manifest" ;; esac
    case " $SEEN " in *" $part "*) fail "partition $part twice in manifest" ;; esac
    SEEN="$SEEN $part"
    if [ "$part" = rootfs ]; then
        [ "$VARIANT" = armbian ] || fail "rootfs in a bundle that is not variant=armbian"
        [ "$file" = rootfs.tar.gz ] || fail "rootfs: image must be named rootfs.tar.gz"
    else
        [ "$file" = "$part.img" ] || fail "$part: image must be named $part.img"
    fi
    [ "$VARIANT" = armbian ] && [ "$part" = oem ] && fail "the Armbian variant does not use oem"
    case "$size" in ''|*[!0-9]*) fail "$part: bad size in manifest" ;; esac
    [ -z "$extra" ] || fail "$part: extra fields in manifest"
    f=$HERE/$file; dev=/dev/block/by-name/${part}_$T
    md5=$(sed -n "s/^\([0-9a-f]*\) [ *]*$file\$/\1/p" "$HERE/md5sums")
    [ -n "$md5" ] || fail "no md5 for $file"
    [ "$(wc -c < "$f")" = "$size" ] || fail "$file: wrong size"
    [ "$(md5sum "$f" | cut -d' ' -f1)" = "$md5" ] || fail "$file: md5 mismatch (damaged stick?)"
    if [ "$part" = rootfs ]; then ROOTFS=$f ROOTFS_SIZE=$size; echo "rootfs.tar.gz ($size B) checked"; continue; fi
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
NEED="boot system"; [ "$VARIANT" = armbian ] && NEED="boot system rootfs"
for part in $NEED; do
    case " $SEEN " in *" $part "*) ;; *) fail "incomplete bundle: no $part image (a first install needs $NEED)" ;; esac
done

# Armbian: everything about the root is checked before anything is written. The build id
# goes into the root's os-release, so only a plain one. The build the active Armbian root
# already has is not staged again (the loader would keep it anyway); any other root has to fit:
# the loader unpacks it next to the installed roots, about 3.5 times the archive, and goes
# back to stock (after this installer said done) when it does not fit.
STAGE_ROOT=1
if [ "$VARIANT" = armbian ]; then
    BID=$(sed -n 's/^build_id=//p' "$HERE/manifest")
    case "$BID" in ''|*[!A-Za-z0-9._+-]*) fail "bad build_id in manifest" ;; esac
    A=/useremain/armbian
    act=$(sed -n 's/^ACTIVE=\([ab]\)$/\1/p' $A/ab/state 2>/dev/null); act=${act:-a}
    if { [ -e $A/root_$act/sbin/init ] || [ -L $A/root_$act/sbin/init ]; } &&
            grep -qxF "BUILD_ID=$BID" $A/root_$act/etc/os-release 2>/dev/null; then
        STAGE_ROOT=0; echo "Armbian root_$act already has build $BID: only the slot is switched"
    else
        set -- $(df -k /useremain | sed -n '$p')
        avail=$(($4 * 1024)); need=$((ROOTFS_SIZE * 4))
        [ "$avail" -ge "$need" ] ||
            fail "not enough space on useremain for the Armbian root: $avail B free, $need B needed (delete print files or timelapses on stock)"
        echo "useremain: $avail B free, $need B needed"
    fi
fi

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

# Armbian: the root for the loader's first boot (same filesystem as the unpacked swu: a move)
if [ "$VARIANT" = armbian ] && [ "$STAGE_ROOT" = 1 ]; then
    I=/useremain/armbian/install
    rm -rf "$I"; mkdir -p "$I"
    mv "$ROOTFS" "$I/rootfs.tar.gz" || fail "cannot move the Armbian root to $I"
    echo "$BID" > "$I/BUILD_ID"; sync
    echo "Armbian root staged in $I (unpacked on the first Armbian boot)"
elif [ "$VARIANT" = armbian ]; then
    rm -rf /useremain/armbian/install    # nothing left from an earlier attempt
fi

# kobra-update / the USB updater on ShedNaja compare against this (Armbian: its data copy)
UPD=/useremain/shednaja/update; [ "$VARIANT" = armbian ] && UPD=/useremain/armbian/shednaja/update
mkdir -p "$UPD"
cp "$HERE/manifest" "$UPD/installed.manifest"

# A/B data in misc (Rockchip AvbABData at offset 2048, see kobra-abctl.c): magic "\0AB0",
# then priority/tries/successful per slot. Prints "<priority a> <priority b>", or nothing
# if it cannot be read. hexdump, not od: stock's busybox 1.27.2 od has no -A/-t.
ab_priorities() {
    dd if=/dev/block/by-name/misc bs=1 skip=2048 count=16 2>/dev/null |
        hexdump -v -e '16/1 "%u " "\n"' 2>/dev/null |
        awk '$1 == 0 && $2 == 65 && $3 == 66 && $4 == 48 { print $9, $13 }'
}
rk_ota --misc=other --mode=retry > /tmp/shednaja-rk_ota.out 2>&1
rc=$?
grep -E 'A/B' /tmp/shednaja-rk_ota.out
rm -f /tmp/shednaja-rk_ota.out
rk_ota --misc=display 2>&1 | grep -E 'priority|tries|successful'
# the switch only counts if slot $T now has the highest priority (SPL boots that one);
# without a readable misc (no hexdump), rk_ota's exit status has to do
prio=$(ab_priorities)
if [ -n "$prio" ]; then
    set -- $prio
    if [ $T = a ]; then mine=$1 theirs=$2; else mine=$2 theirs=$1; fi
    [ "$mine" -gt "$theirs" ] ||
        fail "slot switch failed (rk_ota exit $rc, priority a/b: $1/$2) - ShedNaja is written to slot $T but not active"
else
    echo "cannot read the A/B data in misc, going by rk_ota's exit status ($rc)"
    [ $rc = 0 ] || fail "rk_ota --misc=other failed (exit $rc) - ShedNaja is written to slot $T but not active"
fi
echo "slot $T active - rebooting into ShedNaja $(date)"
cleanup
beep 3 600000
reboot
