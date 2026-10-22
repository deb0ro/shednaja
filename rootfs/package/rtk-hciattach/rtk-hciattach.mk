################################################################################
#
# rtk-hciattach (radxa/rkwifibt tools/rtk_hciattach, pinned by tools/build_rootfs.sh)
#
################################################################################

RTK_HCIATTACH_VERSION = $(KOBRA_RKWIFIBT_COMMIT)
RTK_HCIATTACH_SITE = $(KOBRA_RKWIFIBT_DIR)/tools/rtk_hciattach
RTK_HCIATTACH_SITE_METHOD = local
RTK_HCIATTACH_LICENSE = GPL-2.0+

define RTK_HCIATTACH_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -Wall" LDFLAGS="$(TARGET_LDFLAGS)"
endef

define RTK_HCIATTACH_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rtk_hciattach $(TARGET_DIR)/usr/sbin/rtk_hciattach
endef

$(eval $(generic-package))
