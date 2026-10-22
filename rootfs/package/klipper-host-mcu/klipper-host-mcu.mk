################################################################################
#
# klipper-host-mcu (Klipper "Linux MCU" process for the host board's GPIO/PWM)
#
################################################################################

# Same source tarball as the klipper package, so klippy and klipper_mcu always speak
# the same protocol (and the download is shared). This file is parsed before
# klipper.mk, so the version is repeated here; the build checks that they match.
KLIPPER_HOST_MCU_VERSION = 45f35e8cd5cab6b369e0467d995012dcacb805bd
KLIPPER_HOST_MCU_SITE = https://github.com/Kobra-S1/klipper-kobra-s1.git
KLIPPER_HOST_MCU_SITE_METHOD = git
KLIPPER_HOST_MCU_DL_SUBDIR = klipper
KLIPPER_HOST_MCU_SOURCE = klipper-$(KLIPPER_HOST_MCU_VERSION)-br1.tar.gz
KLIPPER_HOST_MCU_LICENSE = GPL-3.0
KLIPPER_HOST_MCU_LICENSE_FILES = COPYING
KLIPPER_HOST_MCU_DEPENDENCIES = host-python3 klipper

# Kconfig: just the Linux target, everything else default (the fork's
# CONFIG_FIRMWARE_VERSION becomes the reported MCU version, as for the printer MCUs).
define KLIPPER_HOST_MCU_BUILD_CMDS
	test "$(KLIPPER_HOST_MCU_VERSION)" = "$(KLIPPER_VERSION)" || \
		{ echo "klipper-host-mcu: version differs from klipper.mk"; exit 1; }
	echo "CONFIG_MACH_LINUX=y" > $(@D)/.config
	$(MAKE) -C $(@D) PYTHON=$(HOST_DIR)/bin/python3 olddefconfig
	$(MAKE) -C $(@D) PYTHON=$(HOST_DIR)/bin/python3 CROSS_PREFIX=$(TARGET_CROSS)
endef

define KLIPPER_HOST_MCU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/out/klipper.elf $(TARGET_DIR)/usr/bin/klipper_mcu
endef

define KLIPPER_HOST_MCU_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL_KOBRA_PATH)/package/klipper-host-mcu/S59klipper-mcu \
		$(TARGET_DIR)/etc/init.d/S59klipper-mcu
endef

$(eval $(generic-package))
