################################################################################
#
# moonraker
#
################################################################################

# master after tag v0.11.0 (revert of the strict API key handling, a status update fix),
# pinned by hash; MOONRAKER_RELEASE is its git describe
MOONRAKER_RELEASE = v0.11.0-4-gb559b9a
MOONRAKER_VERSION = b559b9a81161f958a43c2f527b6ad96f73310d5d
MOONRAKER_SITE = https://github.com/Arksine/moonraker.git
MOONRAKER_SITE_METHOD = git
MOONRAKER_LICENSE = GPL-3.0
MOONRAKER_LICENSE_FILES = LICENSE
MOONRAKER_DEPENDENCIES = python3 host-python3

define MOONRAKER_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/lib/moonraker
	mkdir -p $(TARGET_DIR)/usr/lib/moonraker
	cp -a $(@D)/moonraker $(@D)/LICENSE $(TARGET_DIR)/usr/lib/moonraker/
	echo "$(MOONRAKER_RELEASE)" > $(TARGET_DIR)/usr/lib/moonraker/moonraker/.version
	find $(TARGET_DIR)/usr/lib/moonraker -name '__pycache__' -prune -exec rm -rf {} +
	$(HOST_DIR)/bin/python3 -m compileall -q -j1 --invalidation-mode unchecked-hash \
		-d /usr/lib/moonraker/moonraker $(TARGET_DIR)/usr/lib/moonraker/moonraker
endef

$(eval $(generic-package))
