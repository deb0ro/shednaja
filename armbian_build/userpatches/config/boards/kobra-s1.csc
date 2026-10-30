# Anycubic Kobra S1 host board: Rockchip RV1106G3, single Cortex-A7, 256 MB DDR3 in package,
# 8 GB eMMC, RTL8723DS Wi-Fi (SDIO) + BT (UART1), 800x480 RGB panel, FocalTech touch.
# ShedNaja experiment, see armbian_build/README.md. Not an official Armbian board.
BOARD_NAME="Anycubic Kobra S1"
BOARD_VENDOR="anycubic"
BOARDFAMILY="rockchip-rv1106"
BOARD_MAINTAINER=""
INTRODUCED="2026"
BOOT_SOC="rv1106"
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="rv1106g-kobra-s1-armbian.dtb"   # armbian_build/dts: shared DTS + mainline Bluetooth

# Phase 1 keeps the stock SPL/U-Boot (A/B slots, unsigned FIT boot): Armbian must not
# build or write a bootloader. The kernel is packed into our FIT by scripts/pack_boot.sh.
BOOTCONFIG="none"

# eMMC uses blkdevparts= from the U-Boot env, not GPT; the image's own partition table
# only matters for extracting the rootfs (scripts/extract_rootfs.sh).
IMAGE_PARTITION_TABLE="msdos"

# 215 MB visible RAM: swapfile service, fixed /run, no ramlog/zram (extensions/lowmem.sh)
enable_extension "lowmem"

PACKAGE_LIST_BOARD="wpasupplicant iw udhcpc systemd-timesyncd dropbear openssh-sftp-server zstd kexec-tools device-tree-compiler"   # udhcpc: kobra-dhcp@ (timesyncd came with the networkd stack); kexec, fdtput: loader/init

# Pin the vendor kernel to the commit our DTS and the rtl8723ds patch were checked against
# (the family follows the branch head of rk-6.1-rkr7.2). Bump together with sources/.
function post_family_config_branch_vendor__kobra_s1_pin_kernel() {
	declare -g KERNELBRANCH='commit:d3d527fca68e0db93aa802692e82b9e3b10cef8d'
}

# Last changes to the image, after Armbian wrote /etc/fstab and enabled its services
# (customize-image.sh runs before both). The root lives in a directory on useremain
# (phase 1), not on this image's partition.
# 900_: after the lowmem extension (500_), which rewrites SWAP= in armbian-zram-config
function pre_umount_final_image__900_kobra_s1() {
	display_alert "${BOARD}" "fstab, units for the directory root on useremain" "info"
	# No / entry: the loader binds the root in place, a UUID line would make systemd wait for
	# (and fsck) a partition that does not exist on the printer. nofail, never format.
	cat > "${MOUNT}/etc/fstab" <<- 'EOF'
		# Kobra S1 (ShedNaja Armbian experiment): / is set up by the loader in the system slot
		tmpfs                        /tmp       tmpfs  defaults,nosuid  0 0
		/dev/disk/by-partname/userdata  /userdata  ext4   noatime,nofail   0 0
		# own copy of ShedNaja's data (kobra-data-seed), Lite's paths unchanged
		/useremain/armbian/shednaja  /useremain/shednaja  none  bind,nofail,x-systemd.requires=kobra-data-seed.service  0 0
	EOF
	# DNS from udhcpc (kobra-dhcp@.service writes it); here, because the build's chroot uses the
	# host's resolv.conf until the end
	rm -f "${MOUNT}/etc/resolv.conf"; : > "${MOUNT}/etc/resolv.conf"
	# no SSH host keys in the image (they would be the same on every board): dropbear -R creates them,
	# kobra-ab install carries them over
	rm -f "${MOUNT}"/etc/dropbear/dropbear_*_host_key "${MOUNT}"/etc/ssh/ssh_host_*
	# no Armbian first-login wizard (root password + user) and no armbian-firstrun (it would
	# regenerate OpenSSH keys we do not use): the password is Lite's default with Lite's prompt
	rm -f "${MOUNT}/root/.not_logged_in_yet" "${MOUNT}/etc/systemd/system/multi-user.target.wants/armbian-firstrun.service"
	# Serial console (ttyFIQ0, pad J1) with a login prompt: Armbian's build writes "--autologin root"
	# overrides that only armbian-firstlogin removes, and our installs skip it (root shell on UART
	# without a password, login + bash ~3 MB resident)
	rm -f "${MOUNT}/etc/systemd/system/serial-getty@.service.d/override.conf" \
		"${MOUNT}/etc/systemd/system/getty@.service.d/override.conf"
	rmdir "${MOUNT}/etc/systemd/system/serial-getty@.service.d" "${MOUNT}/etc/systemd/system/getty@.service.d" 2>/dev/null || true
	declare u w
	# would grow the partition the root sits on (useremain): never. e2scrub: LVM snapshot
	# checks, no LVM here (e2scrub_reap alone took 28 s of the boot)
	for u in armbian-resize-filesystem.service e2scrub_reap.service e2scrub_all.timer; do
		ln -sfn /dev/null "${MOUNT}/etc/systemd/system/${u}"
	done
	# swap in zram, not lowmem's 256 MB swapfile: useremain is ext2-style (no extents, fallocate
	# fails) and a swapfile wears the eMMC. zswap off, zram is the swap.
	rm -f "${MOUNT}/etc/systemd/system/multi-user.target.wants/lowmem-mkswap.service"
	sed -i 's/^SWAP=false/SWAP=true/' "${MOUNT}/etc/default/armbian-zram-config"
	cat >> "${MOUNT}/etc/default/armbian-zram-config" <<- 'EOF'
		# Kobra S1: swap in zram instead of a swapfile (useremain has no extents; no eMMC wear)
		ZRAM_PERCENTAGE=40
		MEM_LIMIT_PERCENTAGE=20
		SWAP_ALGORITHM=lzo-rle
	EOF
	printf '%s\n' "# zram is the swap: no zswap in front of it" "w /sys/module/zswap/parameters/enabled - - - - N" \
		> "${MOUNT}/etc/tmpfiles.d/kobra-zswap.conf"
	# Armbian's periodic jobs that do not belong on a printer: apt-get upgrade -s from cron
	# (armbian-updates, ~60 MB while it runs), a battery check, e2scrub, dpkg database backups
	rm -f "${MOUNT}"/etc/cron.d/armbian-updates "${MOUNT}"/etc/cron.d/armbian-check-battery \
		"${MOUNT}"/etc/cron.d/e2scrub_all "${MOUNT}/etc/systemd/system/timers.target.wants/dpkg-db-backup.timer"
	# no rsyslog (journald, volatile) and no cron (systemd timers: logrotate, fstrim, tmpfiles)
	rm -f "${MOUNT}/etc/systemd/system/multi-user.target.wants/rsyslog.service" \
		"${MOUNT}/etc/systemd/system/syslog.service" \
		"${MOUNT}/etc/systemd/system/multi-user.target.wants/cron.service"
	# no unattended apt/man-db runs on a printer (RAM, CPU, mid-print upgrades); no VT for tty1;
	# the generic D-Bus wpa_supplicant next to wpa_supplicant@wlan0
	for u in timers.target.wants/apt-daily.timer timers.target.wants/apt-daily-upgrade.timer \
		timers.target.wants/man-db.timer getty.target.wants/getty@tty1.service \
		multi-user.target.wants/wpa_supplicant.service multi-user.target.wants/armbian-resize-filesystem.service; do
		rm -f "${MOUNT}/etc/systemd/system/${u}"
	done
	return 0
}

# Armbian's Wi-Fi driver harness only adds rtl8723ds for rockchip64/d1; ours comes as
# userpatches/kernel/rv1106-vendor-6.1/0001-wireless-add-rtl8723ds.patch (scripts/prepare.sh)

function custom_kernel_config__kobra_s1() {
	# Stock U-Boot loads the zImage at kernel_addr_c=0x00808000 and the DTB at fdt_addr_r=0x00C00000:
	# a zImage over 4161536 B overwrites the DTB and the board hangs before earlycon (first 6.1 boot,
	# gzip zImage 5.1 MB). XZ as in 5.10/stock; scripts/pack_boot.sh checks the limit.
	opts_y+=(KERNEL_XZ)
	opts_n+=(KERNEL_GZIP KERNEL_LZ4 KERNEL_LZMA KERNEL_LZO)
	# The decompressed kernel (_text.._edata) must also end below the zImage (0x00808000, i.e. at most
	# 8388608 B from 0x8000), or the decompressor relocates itself past it, onto the DTB (second hang,
	# 8467104 B). Built-ins this board does not use: no audio, no NAND/SPI flash, host-only USB.
	opts_n+=(SND MTD UBIFS_FS USB_GADGET FTRACE)
	opts_m+=(NFS_FS)
	# console: FIQ debugger on UART2 m1 (pad J1), 8250 earlycon before it
	opts_y+=(FIQ_DEBUGGER FIQ_DEBUGGER_CONSOLE FIQ_DEBUGGER_CONSOLE_DEFAULT_ENABLE FIQ_DEBUGGER_NO_SLEEP)
	opts_y+=(SERIAL_8250_CONSOLE SERIAL_EARLYCON)
	# eMMC partitions come from blkdevparts= (U-Boot env); USB sticks may be MBR or GPT
	opts_y+=(PARTITION_ADVANCED CMDLINE_PARTITION MSDOS_PARTITION EFI_PARTITION)
	# display: VOP -> RGB -> simple-panel, PWM backlight, fbdev for HelixScreen
	opts_y+=(DRM DRM_ROCKCHIP ROCKCHIP_VOP ROCKCHIP_RGB DRM_PANEL_SIMPLE DRM_FBDEV_EMULATION FB)
	opts_y+=(BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM)
	# contiguous memory: no IOMMU on the VOP, so scanout/fbdev buffers come from CMA (DT
	# linux,cma, 8 MB and not "inactive" in dts/rv1106g-kobra-s1-armbian.dts). Armbian's rv1106
	# base config has no CMA at all. No RK CMA heap: it only serves the ISP/rockit camera chain
	# (the camera is UVC) and would reserve rk_dma_heap_cma=18M from the bootargs.
	opts_y+=(CMA DMA_CMA CMA_INACTIVE DMABUF_HEAPS DMABUF_HEAPS_ROCKCHIP)
	opts_n+=(DMABUF_HEAPS_ROCKCHIP_CMA_HEAP)
	# No cpufreq: vdd_arm (PWM7) stays disabled as in stock, so the CPU keeps the bootloader's
	# 1416 MHz; rockchip-cpufreq only retried 50 times (~110 ms each, "Failed to get leakage")
	# and flooded the log buffer out of the early boot messages.
	opts_n+=(ARM_ROCKCHIP_CPUFREQ CPUFREQ_DT)
	# touch: FocalTech "focaltech,fts" on I2C3 (6.1 builds it without our 5.10 Makefile patch)
	opts_y+=(INPUT_TOUCHSCREEN TOUCHSCREEN_FTS INPUT_EVDEV INPUT_MISC INPUT_UINPUT)
	opts_y+=(REGULATOR_FIXED_VOLTAGE REGULATOR_GPIO REGULATOR_PWM)
	# Wi-Fi: RTL8723DS (userpatch); the Broadcom rkwifi driver is not needed
	opts_m+=(CFG80211 MAC80211 RTL8723DS)
	opts_n+=(WL_ROCKCHIP)
	# Bluetooth, prepared for the mainline path (serdev + hci_h5 + btrtl, "realtek,rtl8723ds-bt").
	# Needs a DT node under &uart1 that the 5.10 DTS does not have yet (see README, open items).
	opts_y+=(BT BT_BREDR BT_LE BT_RFCOMM RFKILL SERIAL_DEV_BUS SERIAL_DEV_CTRL_TTYPORT)
	opts_m+=(BT_HCIUART BT_RTL)
	opts_y+=(BT_HCIUART_3WIRE BT_HCIUART_RTL)
	# USB: DWC3 host only -> GL850G hub -> UVC camera, USB sticks, MCUs over CH340/CP210x/ACM
	opts_y+=(USB_DWC3 USB_DWC3_HOST USB_XHCI_HCD USB_STORAGE USB_HID HID_GENERIC HIDRAW)
	opts_n+=(USB_DWC3_DUAL_ROLE USB_DWC3_GADGET)
	opts_m+=(USB_ACM USB_SERIAL USB_SERIAL_CH341 USB_SERIAL_CP210X)
	opts_y+=(MEDIA_SUPPORT MEDIA_USB_SUPPORT MEDIA_CAMERA_SUPPORT)
	opts_m+=(USB_VIDEO_CLASS)
	opts_y+=(USB_NET_DRIVERS)
	opts_m+=(USB_USBNET USB_RTL8152 USB_NET_CDCETHER USB_NET_AX88179_178A)
	opts_y+=(EXFAT_FS VFAT_FS NLS_UTF8 GPIO_CDEV)
	# in the 5.10 build, off in Armbian's base: USB serial fallback, usbmon, hiddev, mousedev,
	# rfkill-gpio, AF_ALG (BlueZ/wpa_supplicant crypto)
	opts_y+=(USB_SERIAL_GENERIC USB_MON USB_HIDDEV INPUT_MOUSEDEV RFKILL_GPIO)
	opts_y+=(CRYPTO_USER_API_HASH CRYPTO_USER_API_SKCIPHER CRYPTO_USER_API_RNG CRYPTO_USER_API_AEAD)
	# systemd (README v257: required + strongly recommended), swap for apt on 215 MB
	opts_y+=(CGROUPS MEMCG CGROUP_PIDS CGROUP_SCHED CGROUP_BPF BPF_SYSCALL)
	opts_y+=(NAMESPACES UTS_NS IPC_NS PID_NS NET_NS AUTOFS_FS)
	opts_y+=(TMPFS_XATTR TMPFS_POSIX_ACL EXT4_FS_POSIX_ACL IPV6 POSIX_MQUEUE SWAP)
	# loader in the system slot (squashfs) and the overlay variant
	opts_y+=(SQUASHFS SQUASHFS_XZ BLK_DEV_LOOP)
	opts_m+=(OVERLAY_FS ZRAM)
	# the loader kexecs the kernel of the chosen root when it differs from boot_<slot> (kernel A/B
	# with the root); single core, so no PM_SLEEP_SMP needed
	opts_y+=(KEXEC)
	# No RT group scheduling: with it, cgroups get no RT runtime once systemd enables the cpu
	# controller, and klipper_mcu -r (SCHED_FIFO) fails with EPERM on any restart after boot.
	# (Armbian's enable_docker_support sets it =y: kernel_config_force_n drops it from opts_y)
	kernel_config_force_n RT_GROUP_SCHED
	# RAM and the decompressor margin: no bridge (and its STP/LLC), no EHCI (xHCI only); GBK
	# filenames and /proc/config.gz as modules (modprobe nls_cp936 / configs)
	kernel_config_force_n BRIDGE BRIDGE_VLAN_FILTERING
	opts_n+=(USB_EHCI_HCD)
	opts_m+=(NLS_CODEPAGE_936 IKCONFIG)
}
# Serial login: the family sets SERIALCON="ttyFIQ0" (pad J1, 115200).
