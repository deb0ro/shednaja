################################################################################
#
# kobra-abctl
#
################################################################################

KOBRA_ABCTL_VERSION = 1.0
KOBRA_ABCTL_SITE = $(BR2_EXTERNAL_KOBRA_PATH)/package/kobra-abctl/src
KOBRA_ABCTL_SITE_METHOD = local
KOBRA_ABCTL_LICENSE = MIT

define KOBRA_ABCTL_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -std=gnu99 -Wall \
		-o $(@D)/kobra-abctl $(@D)/kobra-abctl.c
endef

define KOBRA_ABCTL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/kobra-abctl $(TARGET_DIR)/usr/sbin/kobra-abctl
endef

$(eval $(generic-package))
