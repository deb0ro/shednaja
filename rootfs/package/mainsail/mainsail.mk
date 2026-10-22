################################################################################
#
# mainsail (static web UI, release zip)
#
################################################################################

MAINSAIL_VERSION = 2.19.0
MAINSAIL_SITE = https://github.com/mainsail-crew/mainsail/releases/download/v$(MAINSAIL_VERSION)
MAINSAIL_SOURCE = mainsail.zip
MAINSAIL_LICENSE = GPL-3.0
MAINSAIL_DEPENDENCIES = host-python3

define MAINSAIL_EXTRACT_CMDS
	$(HOST_DIR)/bin/python3 -m zipfile -e $(MAINSAIL_DL_DIR)/$(MAINSAIL_SOURCE) $(@D)/www
endef

define MAINSAIL_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/share/mainsail
	mkdir -p $(TARGET_DIR)/usr/share
	cp -a $(@D)/www $(TARGET_DIR)/usr/share/mainsail
	find $(TARGET_DIR)/usr/share/mainsail -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
endef

$(eval $(generic-package))
