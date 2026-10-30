#!/usr/bin/env bash
# First Armbian test install on the TEST BOARD (not the printer), from a running ShedNaja (Lite).
#   bash armbian_build/scripts/install_test.sh <ip>            # dry run: checks, shows the plan
#   bash armbian_build/scripts/install_test.sh <ip> --write    # does it
# Writes on the board:
#   1. /useremain/armbian/root   <- build/armbian/rootfs-trixie.tar.zst (new files only, no format)
#      + root's SSH key (keys/kobra_ed25519.pub), sshd key-only, no Armbian first-login wizard
#   2. boot_<slot> + system_<slot> of the RUNNING ShedNaja slot <- boot.img (6.1) + loader.squashfs,
#      through kobra-update (stage 2 from RAM, sha256 readback; oem_<slot> untouched), then reboot.
# Never touches the other (stock) slot, userdata or the rest of useremain. Run from Git Bash on Windows.
# Back: the loader switches to stock when the Debian root is missing/broken; SPL falls back to stock
# after 7 boots that are not marked good (nothing marks them yet); /useremain/armbian/disabled.
set -euo pipefail
IP=${1:?usage: install_test.sh <ip> [--write]}; WRITE=${2:-}
REPO=/d/KobraS1_OpenFW
W=$(cd "$(dirname "$0")/../.." && pwd)
A=$W/build/armbian
SSH=(ssh -i "$REPO/keys/kobra_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
     -o ServerAliveInterval=15 -o UserKnownHostsFile="$REPO/keys/known_hosts_shednaja" "root@$IP")
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for f in rootfs-trixie.tar.zst boot.img loader.squashfs; do [ -f "$A/$f" ] || die "missing $A/$f"; done
(cd "$A" && sha256sum -c --quiet rootfs-trixie.tar.zst.sha256 loader.squashfs.sha256) || die "artifact checksum"
PUB=$REPO/keys/kobra_ed25519.pub; [ -f "$PUB" ] || die "missing $PUB"

log "checks on $IP"
info=$("${SSH[@]}" '. /etc/os-release; echo "id=$ID build=$BUILD_ID slot=$(/usr/libexec/kobra/current-slot)
cid=$(cat /sys/block/mmcblk0/device/cid)
root_exists=$([ -e /useremain/armbian/root ] && echo yes || echo no)"
  # busybox df wraps the long by-name device onto its own line: take "Available" from the last line
  echo "free_kb=$(df -k /useremain | tail -1 | awk "{print \$(NF-2)}")"; kobra-abctl display')
echo "$info"
grep -q '^id=shednaja' <<< "$info" || die "board does not run ShedNaja"
grep -q "cid=d6010330384133393110bedbd1e15b6f" <<< "$info" || die "not the test board (eMMC CID) - refusing"
slot=$(grep -o 'slot=[ab]' <<< "$info" | head -1 | cut -d= -f2)
[ "$slot" = a ] || [ "$slot" = b ] || die "running slot unknown"
free_kb=$(grep -o 'free_kb=[0-9]*' <<< "$info" | cut -d= -f2)
[ "$free_kb" -gt 1572864 ] || die "less than 1.5 GiB free on useremain"
grep -q 'root_exists=no' <<< "$info" || die "/useremain/armbian/root exists already (remove it first)"

log "plan: Debian root -> /useremain/armbian/root; boot.img + loader -> boot_$slot/system_$slot (running slot); then reboot"
log "      the other slot (stock) is not written"
BUNDLE=$A/armbian-test-update.tar
(cd "$W" && bash tools/make_update_bundle.sh --boot "$A/boot.img" --system "$A/loader.squashfs" --out "$BUNDLE") >/dev/null
tar -tf "$BUNDLE" | tr '\n' ' '; echo
[ "$WRITE" = --write ] || { log "dry run, nothing written (add --write)"; exit 0; }

log "1/3 Debian root (streaming the uncompressed tar, ~560 MB)"
wpath="/mnt/$(echo "${A:1:1}" | tr 'A-Z' 'a-z')${A:2}"
n_tar=$(MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -- sh -c "zstd -dc '$wpath/rootfs-trixie.tar.zst' | tar -t | wc -l")
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -- zstd -dc "$wpath/rootfs-trixie.tar.zst" \
  | "${SSH[@]}" 'set -e; rm -rf /useremain/armbian/root.new; mkdir -p /useremain/armbian/root.new
      tar -x --numeric-owner -f - -C /useremain/armbian/root.new; sync'
n_board=$("${SSH[@]}" 'cd /useremain/armbian/root.new && find . | wc -l')
log "entries: tar $n_tar, board $n_board"
[ "$n_board" -ge "$n_tar" ] || die "extraction incomplete"

log "2/3 test access (SSH key, key-only sshd, no first-login wizard), then activate"
"${SSH[@]}" "set -e; R=/useremain/armbian/root.new
  mkdir -p \$R/root/.ssh; chmod 700 \$R/root/.ssh
  cat > \$R/root/.ssh/authorized_keys; chmod 600 \$R/root/.ssh/authorized_keys
  mkdir -p \$R/etc/ssh/sshd_config.d
  printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > \$R/etc/ssh/sshd_config.d/10-kobra-test.conf
  rm -f \$R/root/.not_logged_in_yet
  mv /useremain/armbian/root.new /useremain/armbian/root; sync
  ls -la /useremain/armbian; ls /useremain/armbian/root" < "$PUB"

log "3/3 boot + loader into slot $slot via kobra-update (reboots)"
scp -O -i "$REPO/keys/kobra_ed25519" -o BatchMode=yes -o LogLevel=ERROR -o UserKnownHostsFile="$REPO/keys/known_hosts_shednaja" \
  "$BUNDLE" "root@$IP:/useremain/shednaja/update/armbian-test-update.tar"
"${SSH[@]}" 'kobra-update --check /useremain/shednaja/update/armbian-test-update.tar'
"${SSH[@]}" 'kobra-update --yes /useremain/shednaja/update/armbian-test-update.tar' || true
log "handed over; watch the UART (COM3, 115200) for the loader and systemd"
