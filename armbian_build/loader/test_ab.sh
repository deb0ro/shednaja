#!/bin/bash
# Offline test of the loader's A/B selection (the "A/B of the Debian root" block of loader/init),
# run with the loader's own busybox under qemu-arm. Usage (WSL): bash armbian_build/loader/test_ab.sh
# Without a Buildroot target (CI) it runs with the host's busybox (busybox-static) instead.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=${BR_OUT:-$HOME/kobra/rootfs-out}/target
Q=$(command -v qemu-arm-static || command -v qemu-arm || true)
if [ -x "$T/bin/busybox" ] && [ -n "$Q" ]; then
	BB=("$Q" -L "$T" "$T/bin/busybox")
elif command -v busybox > /dev/null; then
	BB=("$(command -v busybox)"); echo "(no Buildroot target: the host's busybox runs the loader blocks)"
else
	echo "needs the Buildroot target ($T) with qemu-arm, or busybox on the host" >&2; exit 1
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# the block from "# ---- A/B" up to the line that sets R, AB pointed at the test dir
sed -n '/^# ---- A\/B of the Debian root/,/^R=\/mnt\/useremain\/\$ROOTDIR/p' "$HERE/init" |
	sed "s#^AB=/mnt/useremain/armbian#AB=\$TESTAB#" > "$W/block.sh"
# the kernel block (kexec of the root's kernel), run on the chosen test root with stubs for the
# boot partition (dd -> $TESTHDR), mounts and the root's commands (chroot -> CMD lines)
sed -n '/^# ---- kernel of the chosen root/,/^kexec_root$/p' "$HERE/init" > "$W/kernel.sh"
cat > "$W/run.sh" <<'EOF'
log() { echo "LOG: $*"; }
to_stock() { echo "TO_STOCK: $1"; exit 0; }
kroot=$KROOT
. "$1"
echo "BOOT: $ROOTDIR"
[ -n "$2" ] || exit 0
R=$TESTAB/root_$rs; slot=b; DEV=/dev
part() { echo mmcblk0p7; }
dd() { cat "$TESTHDR"; }
mount() { echo "MOUNT $*"; }
umount() { :; }
sync() { :; }
cp() { :; }
chroot() {
	shift; echo "CMD $*" >&2
	case "$1 $2" in "fdtget -t") [ "$3" = x ] && echo "0 10000000" ;; esac
	[ "$1 $2" != "kexec -l" ] || [ -z "$KEXEC_L_FAILS" ]
}
. "$2"
EOF

fail=0
mkroot() { mkdir -p "$1/sbin"; ln -sf ../lib/systemd/systemd "$1/sbin/init"; }
state() { mkdir -p "$TESTAB/ab"; printf 'ACTIVE=%s\nTRY=%s\nTRIES=%s\n' "$1" "$2" "$3" > "$TESTAB/ab/state"; }
check() {  # check <name> <expected output regex> <expected state or ->
	local out st
	out=$(TESTAB=$TESTAB "${BB[@]}" sh "$W/run.sh" "$W/block.sh" 2>&1)
	st=$( { tr '\n' ' ' < "$TESTAB/ab/state"; } 2>/dev/null || echo "-")
	if grep -qE "$2" <<< "$out" && { [ "$3" = - ] || [ "$st" = "$3" ]; }; then
		echo "ok   $1"
	else
		echo "FAIL $1"; echo "     out: $(tr '\n' '|' <<< "$out")"; echo "     state: $st (want $3)"; fail=1
	fi
}
new() { TESTAB=$W/ab$1; rm -rf "$TESTAB"; mkdir -p "$TESTAB"; }

new 1; mkroot "$TESTAB/root"
check "single root -> renamed to root_a, boots a" "BOOT: armbian/root_a$" "ACTIVE=a TRY= TRIES=0 "
[ -L "$TESTAB/root_a/sbin/init" ] && [ ! -e "$TESTAB/root" ] || { echo "FAIL root not renamed"; fail=1; }

new 2; mkroot "$TESTAB/root_a"; mkroot "$TESTAB/root_b"; state a b 3
check "TRY=b with 3 tries -> boots b, 2 left" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=2 "
check "... next boot -> b, 1 left" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=1 "
check "... next boot -> b, 0 left" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=0 "
check "... tries used up -> rollback to a" "BOOT: armbian/root_a$" "ACTIVE=a TRY= TRIES=0 "
[ "$(cat "$TESTAB/ab/last-rollback")" = b ] || { echo "FAIL last-rollback"; fail=1; }

new 3; mkroot "$TESTAB/root_b"; state a "" 0
check "ACTIVE=a has no init -> boots b" "BOOT: armbian/root_b$" "ACTIVE=a TRY= TRIES=0 "

new 4; mkroot "$TESTAB/root_a"; state a b 3
check "TRY=b has no init -> boots a, TRY cleared" "BOOT: armbian/root_a$" "ACTIVE=a TRY= TRIES=0 "

new 5; state a "" 0
check "no root at all -> stock" "TO_STOCK: no Debian root" -

new 6; mkroot "$TESTAB/root_a"; mkroot "$TESTAB/root_b"; mkdir -p "$TESTAB/ab"
printf 'ACTIVE=x
TRY=z
TRIES=99
evil=$(reboot)
' > "$TESTAB/ab/state"
check "garbage state -> defaults (a)" "BOOT: armbian/root_a$" -

new 7; mkroot "$TESTAB/root_a"; mkroot "$TESTAB/root_b"
check "no state file -> a" "BOOT: armbian/root_a$" -

new 8; mkroot "$TESTAB/root_a"; mkroot "$TESTAB/root_b"; state a b 2
KROOT=b check "second pass after kexec (kobra.root=b) -> b, no try spent" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=2 "
KROOT=a check "second pass for the ACTIVE root -> a" "BOOT: armbian/root_a$" "ACTIVE=a TRY=b TRIES=2 "

new 15; I=$TESTAB/install; mkdir -p "$I/dropbear" "$W/r15/sbin" "$W/r15/etc"
ln -sf ../lib/systemd/systemd "$W/r15/sbin/init"; echo 'root:IMAGE:1::::::' > "$W/r15/etc/shadow"
echo 'ID=debian' > "$W/r15/etc/os-release"
tar -czf "$I/rootfs.tar.gz" -C "$W/r15" .; echo key > "$I/dropbear/dropbear_ed25519_host_key"
echo 'LITEHASH' > "$I/root.hash"; echo b123 > "$I/BUILD_ID"
check "first install from install/rootfs.tar.gz -> root_a" "first install: root_a ready" "ACTIVE=a TRY= TRIES=0 "
{ [ -L "$TESTAB/root_a/sbin/init" ] && [ ! -e "$I" ] && grep -q '^root:LITEHASH:' "$TESTAB/root_a/etc/shadow" &&
  grep -q '^BUILD_ID=b123$' "$TESTAB/root_a/etc/os-release" &&
  [ -f "$TESTAB/root_a/etc/dropbear/dropbear_ed25519_host_key" ]; } || { echo "FAIL first install result"; fail=1; }

new 16; mkdir -p "$TESTAB/install"; echo garbage > "$TESTAB/install/rootfs.tar.gz"
check "first install with a broken archive -> stock" "TO_STOCK: first install" -

# back to an Armbian that is installed already (REBOOT_TO_STOCK, then the installer stick)
installed() {	# installed <root dir> <build id>: a confirmed root with this board's identity
	mkroot "$1"; mkdir -p "$1/etc/dropbear" "$1/root/.ssh"
	echo 'root:BOARDHASH:1::::::' > "$1/etc/shadow"; printf 'ID=debian\nBUILD_ID=%s\n' "$2" > "$1/etc/os-release"
	echo boardkey > "$1/etc/dropbear/dropbear_ed25519_host_key"; echo boardid > "$1/etc/machine-id"
	echo 'ssh-ed25519 AAAA owner' > "$1/root/.ssh/authorized_keys"
}
stick() {	# stick <build id> [lite]: what an installer leaves in install/
	mkdir -p "$TESTAB/install"; tar -czf "$TESTAB/install/rootfs.tar.gz" -C "$W/r15" .
	echo "$1" > "$TESTAB/install/BUILD_ID"
	[ "${2:-}" = lite ] && echo LITEHASH > "$TESTAB/install/root.hash"
	true
}
new 17; installed "$TESTAB/root_a" old1; state a "" 0; stick new2
check "installed root_a, stick with another build -> root_b on trial" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=2 "
{ grep -q '^root:BOARDHASH:' "$TESTAB/root_b/etc/shadow" && grep -q '^BUILD_ID=new2$' "$TESTAB/root_b/etc/os-release" &&
  [ "$(cat "$TESTAB/root_b/etc/dropbear/dropbear_ed25519_host_key")" = boardkey ] &&
  [ "$(cat "$TESTAB/root_b/etc/machine-id")" = boardid ] && [ -f "$TESTAB/root_b/root/.ssh/authorized_keys" ] &&
  grep -q '^BUILD_ID=old1$' "$TESTAB/root_a/etc/os-release" && [ ! -e "$TESTAB/install" ]; } ||
	{ echo "FAIL identity / old root after the trial install"; fail=1; }
check "... not confirmed 3 times -> back to root_a" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=1 "
check "..." "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=0 "
check "..." "BOOT: armbian/root_a$" "ACTIVE=a TRY= TRIES=0 "

new 18; installed "$TESTAB/root_b" same9; installed "$TESTAB/root_a" older; state b "" 0; stick same9
check "stick with the build root_b (ACTIVE) has -> kept, nothing unpacked" "already has build same9" "ACTIVE=b TRY= TRIES=0 "
{ [ ! -e "$TESTAB/install" ] && grep -q '^BUILD_ID=older$' "$TESTAB/root_a/etc/os-release"; } ||
	{ echo "FAIL the same build was unpacked again"; fail=1; }

new 19; installed "$TESTAB/root_a" old1; state a "" 0
mkdir -p "$TESTAB/install"; echo garbage > "$TESTAB/install/rootfs.tar.gz"
check "installed root_a, broken stick archive -> boots root_a, no stock" "BOOT: armbian/root_a$" "ACTIVE=a TRY= TRIES=0 "
[ ! -e "$TESTAB/install" ] && [ ! -e "$TESTAB/root_b" ] || { echo "FAIL broken archive left behind"; fail=1; }

new 20; installed "$TESTAB/root_a" old1; state a "" 0; stick new2 lite
check "from Lite onto an installed root_a -> Lite's password wins" "BOOT: armbian/root_b$" "ACTIVE=a TRY=b TRIES=2 "
grep -q '^root:LITEHASH:' "$TESTAB/root_b/etc/shadow" || { echo "FAIL Lite's password"; fail=1; }

new 21; installed "$TESTAB/root_a" old1; state a "" 0; stick 'x$(reboot)'
check "build id with shell characters is not written" "BOOT: armbian/root_b$" -
grep -q 'reboot' "$TESTAB/root_b/etc/os-release" && { echo "FAIL bad build id written"; fail=1; } || true

# ---- kernel block ----
kcheck() {  # kcheck <name> <expected output regex> <unexpected output regex or -> <kexec-fails or ->
	local out kf
	out=$(TESTAB=$TESTAB TESTHDR=$W/hdr KROOT=${KROOT:-} KEXEC_L_FAILS=${KEXEC_L_FAILS:-} \
		"${BB[@]}" sh "$W/run.sh" "$W/block.sh" "$W/kernel.sh" 2>&1 | tr '\n' '|')
	kf=$(cat "$TESTAB/ab/kexec-fails" 2>/dev/null || echo -)
	if grep -qE "$2" <<< "$out" && { [ "$3" = - ] || ! grep -qE "$3" <<< "$out"; } &&
			{ [ "$4" = - ] || [ "$kf" = "$4" ]; }; then
		echo "ok   $1"
	else
		echo "FAIL $1"; echo "     out: $(tr '\n' '|' <<< "$out")"; echo "     kexec-fails: $kf (want $4)"; fail=1
	fi
}
kroot_fs() {  # kroot_fs <root dir> <kernel content> [notools]
	mkroot "$1"; mkdir -p "$1/boot/dtb" "$1/usr/sbin" "$1/usr/bin" "$1/lib/modules/6.1.999"
	printf '%s' "$2" > "$1/boot/zImage"; printf 'dtb' > "$1/boot/dtb/rv1106g-kobra-s1-armbian.dtb"
	[ "${3:-}" = notools ] && return 0
	printf '#!/bin/sh\n' > "$1/usr/sbin/kexec"; printf '#!/bin/sh\n' > "$1/usr/bin/fdtput"
	chmod +x "$1/usr/sbin/kexec" "$1/usr/bin/fdtput"
}
hdr() {  # FIT header with the sha256 of the given kernel content and of the DTB "dtb"
	{ printf 'FITHEADER'; printf '%s' "$1" | sha256sum | cut -d' ' -f1 | xxd -r -p
	  printf 'xx'; printf 'dtb' | sha256sum | cut -d' ' -f1 | xxd -r -p; } > "$W/hdr"
}
KL='CMD kexec -l /boot/zImage --dtb=/run/k.dtb --command-line=.* kobra.root='

new 9; kroot_fs "$TESTAB/root_a" base; kroot_fs "$TESTAB/root_b" base; state a "" 0; hdr base
kcheck "root kernel == boot slot -> no kexec" "BOOT: armbian/root_a" "CMD kexec" -

new 10; kroot_fs "$TESTAB/root_a" newer; kroot_fs "$TESTAB/root_b" base; state a "" 0; hdr base
kcheck "root kernel differs -> fixups + kexec -l + kexec -e" \
	"CMD fdtput -t x /run/k.dtb /memory reg 0 10000000.*${KL}a.*CMD kexec -e" - 1
kcheck "... unconfirmed again -> kexec, 2 fails" "${KL}a" - 2
kcheck "... 2 unconfirmed kexec boots -> base kernel" "2 kexec boots without a confirm" "CMD kexec" 2

new 11; kroot_fs "$TESTAB/root_a" base; kroot_fs "$TESTAB/root_b" newer; state a b 3
echo 2 > "$TESTAB/ab/kexec-fails"; hdr base
kcheck "root on trial with 2 fails -> still kexec (tries decide)" "${KL}b" - 3

new 12; kroot_fs "$TESTAB/root_a" newer; state a "" 0; hdr base
KROOT=a kcheck "second pass (kobra.root=a) -> no kexec" "second pass after kexec" "CMD kexec" -

new 13; kroot_fs "$TESTAB/root_a" newer notools; state a "" 0; hdr base
kcheck "root without kexec/fdtput -> base kernel" "has no kexec/fdtput" "CMD kexec" -

new 14; kroot_fs "$TESTAB/root_a" newer; state a "" 0; hdr base
KEXEC_L_FAILS=1 kcheck "kexec -l fails -> base kernel" "kexec -l of root_a's kernel failed" "CMD kexec -e" 1

[ $fail = 0 ] && echo "all A/B loader tests passed" || { echo "A/B loader tests FAILED"; exit 1; }
