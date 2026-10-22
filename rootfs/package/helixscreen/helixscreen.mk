################################################################################
#
# helixscreen (touch UI, prebuilt static armv7 release)
#
################################################################################

# The "ad5m" release is a fully static armv7-a hard-float binary (glibc inside),
# so it runs on our uClibc rootfs as is. Building from source needs GCC >= 10
# (C++17, LVGL 9); the SDK toolchain is gcc 8.3. See docs/display-ui.md.
HELIXSCREEN_VERSION = 1.0.6
HELIXSCREEN_SITE = https://github.com/prestonbrown/helixscreen/releases/download/v$(HELIXSCREEN_VERSION)
HELIXSCREEN_SOURCE = helixscreen-ad5m-v$(HELIXSCREEN_VERSION).tar.gz
HELIXSCREEN_LICENSE = GPL-3.0+
HELIXSCREEN_STRIP_COMPONENTS = 1

# Printer images: 44 MB of the 77 MB tree. Keep only the generic one and the Kobra S1.
# Splash images for 1024x600+ and ultrawide panels are not used at 800x480.
# Chinese and Japanese: translations plus their CJK fonts (5 MB); choosing either
# in the UI then falls back to English. Sounds: tracker music for the sound test,
# Snake and the About easter egg; the buzzer plays tones only, never these.
define HELIXSCREEN_PRUNE
	find $(@D)/assets/images/printers -maxdepth 1 -type f \
		! -name 'anycubic-kobra-s1.png' ! -name 'README.md' -delete
	find $(@D)/assets/images/printers/prerendered -type f \
		! -name 'anycubic-kobra-s1-*.bin' -delete
	rm -f $(@D)/assets/images/prerendered/*-large.bin \
		$(@D)/assets/images/prerendered/*-ultrawide.bin
	rm -f $(@D)/ui_xml/translations/zh.xml $(@D)/ui_xml/translations/ja.xml
	rm -rf $(@D)/assets/fonts/cjk $(@D)/assets/sounds
	rm -f $(@D)/install.sh
endef
HELIXSCREEN_POST_EXTRACT_HOOKS += HELIXSCREEN_PRUNE

define HELIXSCREEN_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/opt/helixscreen
	mkdir -p $(TARGET_DIR)/opt
	cp -a $(@D) $(TARGET_DIR)/opt/helixscreen
	find $(TARGET_DIR)/opt/helixscreen -maxdepth 1 -type f -name '.*' -delete	# Buildroot stamps
	find $(TARGET_DIR)/opt/helixscreen -type d -exec chmod 755 {} + -o -type f -exec chmod go-w {} +
	# settings.json/helixscreen.env backups (the app writes them to /var/lib/helixscreen)
	rm -rf $(TARGET_DIR)/var/lib/helixscreen
	ln -s /useremain/shednaja/helixscreen/backup $(TARGET_DIR)/var/lib/helixscreen
endef

$(eval $(generic-package))
