#!/bin/bash
# Armbian image customization for the Kobra S1 (runs in the image chroot; userpatches/overlay
# is bind-mounted at /tmp/overlay). Arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
set -e

BOARD=$3
[[ "$BOARD" == "kobra-s1" ]] || exit 0

# config files from the overlay (modprobe, udev by-name links, journald)
cp -rv --no-preserve=mode,ownership /tmp/overlay/etc/. /etc/   # mode: the overlay comes from NTFS with +x
# boot marking (A/B): kobra-abctl is built by scripts/build_abctl.sh (prepare.sh)
install -m 755 /tmp/overlay/usr/local/sbin/kobra-abctl /tmp/overlay/usr/local/sbin/kobra-bootok /tmp/overlay/usr/local/sbin/kobra-ab /usr/local/sbin/
systemctl enable kobra-bootok.service
# ShedNaja's Klipper stack (staged by scripts/stage_stack.sh): built here, nothing on the printer
if [ -x /tmp/overlay/kobra-stack/install-stack.sh ] || [ -f /tmp/overlay/kobra-stack/install-stack.sh ]; then
	bash /tmp/overlay/kobra-stack/install-stack.sh /tmp/overlay/kobra-stack
fi
# RTL8723DS Bluetooth firmware (stock, copied by scripts/prepare.sh)
if [ -d /tmp/overlay/usr/lib/firmware/rtl_bt ]; then
	mkdir -p /usr/lib/firmware/rtl_bt
	install -m 644 /tmp/overlay/usr/lib/firmware/rtl_bt/* /usr/lib/firmware/rtl_bt/
fi

# kexec-tools is only for the loader (kernel of the chosen root): reboots stay real reboots
# (trixie's kexec-tools loads a kernel for the next reboot through kexec-load.service)
systemctl mask kexec-load.service 2>/dev/null || true

# /etc/fstab and the unit tweaks are in the .csc (pre_umount_final_image): Armbian writes
# the fstab and enables its services after this script runs.
mkdir -p /userdata /useremain

# Wi-Fi uses the stock config on /userdata (shared with stock while it is on the eMMC)
mkdir -p /etc/wpa_supplicant
ln -sf /userdata/wifi_cfg/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl enable wpa_supplicant@wlan0.service || true
# DHCP: busybox udhcpc (overlay kobra-dhcp@.service, ~0.5 MB) instead of systemd-networkd +
# systemd-resolved (~6 MB); NETWORKING_STACK=none leaves netplan out. The udhcpc script writes
# /etc/resolv.conf itself as long as there is no resolvconf (systemd-resolved would provide one).
# Clients identify by MAC like stock/Lite (networkd's DUID got another lease: .248 instead of .247).
systemctl enable kobra-dhcp@wlan0.service
apt-get -y purge systemd-resolved netplan.io netplan-generator 2>/dev/null || true
systemctl mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
	systemd-network-generator.service systemd-resolved.service
# /etc/resolv.conf becomes a plain file in the .csc's final hook (the build still needs DNS here)

# SSH: dropbear as in Lite (listener ~0.5 MB, a session ~0.7 MB; OpenSSH 1.6 + 3.9 MB). Root with
# key and password. openssh-sftp-server (in PACKAGE_LIST_BOARD: purging openssh-server lets the
# autoremove take it) for scp/sftp, dropbear runs /usr/lib/sftp-server.
# Host keys: none in the image (the .csc's final hook deletes them), -R makes them on the first
# connection; kobra-ab install carries a board's keys over to the new root.
apt-get -y purge openssh-server
grep -q '^DROPBEAR_EXTRA_ARGS=' /etc/default/dropbear &&
	sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-R"/' /etc/default/dropbear ||
	echo 'DROPBEAR_EXTRA_ARGS="-R"' >> /etc/default/dropbear
systemctl enable dropbear.service

# No logind sessions: Moonraker runs with "provider: none" and nothing else needs logind. Without
# pam_systemd a root login (SSH, serial) starts no user@0.service (systemd --user + sd-pam, ~4 MB)
# and logind (~1.5 MB) has nothing to do. Not masked: systemctl reboot asks logind over D-Bus and
# prints "Call to Reboot failed" when it is masked; this /dev/null link only drops Debian's
# multi-user.target.wants, so logind starts by D-Bus activation when a reboot asks for it.
pam-auth-update --disable systemd
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn /dev/null /etc/systemd/system/multi-user.target.wants/systemd-logind.service

# no Bluetooth until the serdev DT node exists (README, open items)
systemctl disable bluetooth.service 2>/dev/null || true
