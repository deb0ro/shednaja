################################################################################
#
# mainsail-config (mainsail.cfg client macros)
#
################################################################################

MAINSAIL_CONFIG_VERSION = v1.2.1
MAINSAIL_CONFIG_SITE = https://github.com/mainsail-crew/mainsail-config.git
MAINSAIL_CONFIG_SITE_METHOD = git
MAINSAIL_CONFIG_LICENSE = GPL-3.0
MAINSAIL_CONFIG_LICENSE_FILES = LICENSE

define MAINSAIL_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/mainsail.cfg \
		$(TARGET_DIR)/usr/share/shednaja/printer_data/config/mainsail.cfg
endef

$(eval $(generic-package))
