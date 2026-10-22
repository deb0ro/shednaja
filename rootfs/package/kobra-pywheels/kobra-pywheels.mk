################################################################################
#
# kobra-pywheels - pinned pure-Python dependencies of Moonraker
#
################################################################################

KOBRA_PYWHEELS_VERSION = 1
KOBRA_PYWHEELS_PYPI = https://files.pythonhosted.org/packages
KOBRA_PYWHEELS_SITE = $(KOBRA_PYWHEELS_PYPI)/e3/86/8be1ac7e90f80b413e81f1e235148e8db771218886a2353392f02da01be3
KOBRA_PYWHEELS_SOURCE = inotify_simple-2.0.1-py3-none-any.whl
KOBRA_PYWHEELS_EXTRA_DOWNLOADS = \
	$(KOBRA_PYWHEELS_PYPI)/ad/ce/85fa0276de7303b44fef63e07c14d618b8630bbe41c7dd7e34db246eab8d/libnacl-2.1.0-py3-none-any.whl \
	$(KOBRA_PYWHEELS_PYPI)/38/3d/2d244233ac4f76e38533cfcb2991c9eb4c7bf688ae0a036d30725b8faafe/importlib_metadata-9.0.0-py3-none-any.whl \
	$(KOBRA_PYWHEELS_PYPI)/2e/54/647ade08bf0db230bfea292f893923872fd20be6ac6f53b2b936ba839d75/zipp-3.23.0-py3-none-any.whl \
	$(KOBRA_PYWHEELS_PYPI)/aa/db/b621610e50b1bc46ff63534d75239553c1bf33256de6096b58214fd9808a/dbus_fast-5.0.22.tar.gz
KOBRA_PYWHEELS_LICENSE = MIT (inotify-simple), Apache-2.0 (libnacl, importlib-metadata, zipp), MIT (dbus-fast)
KOBRA_PYWHEELS_DEPENDENCIES = python3 host-python3 libsodium

KOBRA_PYWHEELS_SITE_PACKAGES = $(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages

# wheels are zip files: nothing to extract up front
define KOBRA_PYWHEELS_EXTRACT_CMDS
	true
endef

define KOBRA_PYWHEELS_INSTALL_TARGET_CMDS
	for w in $(KOBRA_PYWHEELS_SOURCE) $(notdir $(filter %.whl,$(KOBRA_PYWHEELS_EXTRA_DOWNLOADS))); do \
		$(HOST_DIR)/bin/python3 -m zipfile -e $(KOBRA_PYWHEELS_DL_DIR)/$$w $(KOBRA_PYWHEELS_SITE_PACKAGES) || exit 1; \
	done
	rm -rf $(@D)/dbus-fast && mkdir -p $(@D)/dbus-fast
	tar -xzf $(KOBRA_PYWHEELS_DL_DIR)/dbus_fast-5.0.22.tar.gz -C $(@D)/dbus-fast --strip-components=1
	rm -rf $(KOBRA_PYWHEELS_SITE_PACKAGES)/dbus_fast
	cp -a $(@D)/dbus-fast/src/dbus_fast $(KOBRA_PYWHEELS_SITE_PACKAGES)/
	find $(KOBRA_PYWHEELS_SITE_PACKAGES)/dbus_fast \( -name '*.pyx' -o -name '*.pxd' -o -name '*.c' \) -delete
endef

$(eval $(generic-package))
