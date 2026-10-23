################################################################################
#
# kobra-acepro (ACE Pro klippy driver from Kobra-S1/ACEPRO)
#
################################################################################

# the commit of tag V0.8.1, pinned by hash: a tag can be moved upstream
KOBRA_ACEPRO_VERSION = 2d20ef9278055cd08265e2022928f5523fc8a3d0
KOBRA_ACEPRO_SITE = $(call github,Kobra-S1,ACEPRO,$(KOBRA_ACEPRO_VERSION))
KOBRA_ACEPRO_LICENSE = GPL-3.0
KOBRA_ACEPRO_LICENSE_FILES = LICENSE
# installs into klipper's klippy/extras
KOBRA_ACEPRO_DEPENDENCIES = klipper host-python3

KOBRA_ACEPRO_EXTRAS = $(TARGET_DIR)/usr/lib/klipper/klippy/extras
KOBRA_ACEPRO_DEFAULTS = $(TARGET_DIR)/usr/share/shednaja/printer_data/config

# Same layout as the ACEPRO installer (symlinks into klippy/extras), compiled like klippy.
# The configs become printer_data defaults: printer-data-init copies them to
# printer_data/config when they are missing, also on printers set up earlier.
define KOBRA_ACEPRO_INSTALL_TARGET_CMDS
	rm -rf $(KOBRA_ACEPRO_EXTRAS)/ace
	cp -a $(@D)/extras/ace $(KOBRA_ACEPRO_EXTRAS)/ace
	$(INSTALL) -m 0644 $(@D)/extras/temperature_ace.py $(@D)/extras/virtual_pins.py \
		$(KOBRA_ACEPRO_EXTRAS)/
	find $(KOBRA_ACEPRO_EXTRAS)/ace -name '__pycache__' -prune -exec rm -rf {} +
	$(HOST_DIR)/bin/python3 -m compileall -q -j1 --invalidation-mode unchecked-hash \
		-d /usr/lib/klipper/klippy/extras $(KOBRA_ACEPRO_EXTRAS)/ace \
		$(KOBRA_ACEPRO_EXTRAS)/temperature_ace.py $(KOBRA_ACEPRO_EXTRAS)/virtual_pins.py
	$(INSTALL) -D -m 0644 $(@D)/config/ace_KS1.cfg $(KOBRA_ACEPRO_DEFAULTS)/ace_KS1.cfg
	$(INSTALL) -D -m 0644 $(@D)/config/ace_macros_generic.cfg \
		$(KOBRA_ACEPRO_DEFAULTS)/ace_macros_generic.cfg
endef

$(eval $(generic-package))
