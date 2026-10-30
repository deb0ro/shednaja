#!/bin/bash
# Offline test of the loader's A/B selection (the "A/B of the Debian root" block of loader/init),
# run with the loader's own busybox under qemu-arm. Usage (WSL): bash armbian_build/loader/test_ab.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=${BR_OUT:-$HOME/kobra/rootfs-out}/target
Q=$(command -v qemu-arm-static || command -v qemu-arm)
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
	out=$(TESTAB=$TESTAB "$Q" -L "$T" "$T/bin/busybox" sh "$W/run.sh" "$W/block.sh" 2>&1)
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

# ---- kernel block ----
kcheck() {  # kcheck <name> <expected output regex> <unexpected output regex or -> <kexec-fails or ->
	local out kf
	out=$(TESTAB=$TESTAB TESTHDR=$W/hdr KROOT=${KROOT:-} KEXEC_L_FAILS=${KEXEC_L_FAILS:-} \
		"$Q" -L "$T" "$T/bin/busybox" sh "$W/run.sh" "$W/block.sh" "$W/kernel.sh" 2>&1 | tr '\n' '|')
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
