################################################################################
#
# mainsail-config (mainsail.cfg client macros)
#
################################################################################

# tag v1.2.1 plus one commit (the _CLIENT_LINEAR_MOVE macro), pinned by hash. A new version
# needs the sha256 of its mainsail.cfg in board/kobra_s1/klipper_config/known-versions.sha256.
MAINSAIL_CONFIG_VERSION = ff3869a621db17ce3ef660adbbd3fa321995ac42
MAINSAIL_CONFIG_SITE = https://github.com/mainsail-crew/mainsail-config.git
MAINSAIL_CONFIG_SITE_METHOD = git
MAINSAIL_CONFIG_LICENSE = GPL-3.0
MAINSAIL_CONFIG_LICENSE_FILES = LICENSE

define MAINSAIL_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/mainsail.cfg \
		$(TARGET_DIR)/usr/share/shednaja/klipper/mainsail.cfg
endef

$(eval $(generic-package))
