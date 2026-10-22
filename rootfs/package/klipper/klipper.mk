################################################################################
#
# klipper (klippy host part) - Kobra-S1 fork, branch Kobra-S1-Dev
#
################################################################################

KLIPPER_VERSION = 45f35e8cd5cab6b369e0467d995012dcacb805bd
KLIPPER_SITE = https://github.com/Kobra-S1/klipper-kobra-s1.git
KLIPPER_SITE_METHOD = git
KLIPPER_LICENSE = GPL-3.0
KLIPPER_LICENSE_FILES = COPYING
KLIPPER_DEPENDENCIES = python3 host-python3
# git describe --tags --long of the pinned commit (klippy reads klippy/.version)
KLIPPER_DESCRIBE = V1.3.1-51-g45f35e8c

KLIPPER_CHELPER = $(@D)/klippy/chelper

# Same flags as klippy/chelper/__init__.py (COMPILE_ARGS), with the target compiler.
# The source list is read from SOURCE_FILES there, so it stays in sync with the code.
define KLIPPER_BUILD_CMDS
	cd $(KLIPPER_CHELPER) && \
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall -O2 -shared -fPIC \
		-flto -fwhole-program -fno-use-linker-plugin -o c_helper.so \
		$$($(HOST_DIR)/bin/python3 -c 'import ast,sys; t=ast.parse(open("__init__.py").read()); \
		print(" ".join(next(ast.literal_eval(n.value) for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "SOURCE_FILES")))') \
		-lm
endef

define KLIPPER_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/lib/klipper
	mkdir -p $(TARGET_DIR)/usr/lib/klipper
	cp -a $(@D)/klippy $(TARGET_DIR)/usr/lib/klipper/
	cp -a $(@D)/COPYING $(TARGET_DIR)/usr/lib/klipper/
	# Moonraker serves these as the "config_examples" and "docs" file roots (and warns when
	# they are missing): example configs (~90 kB in the image), docs as text only (no images)
	cp -a $(@D)/config $(TARGET_DIR)/usr/lib/klipper/
	mkdir -p $(TARGET_DIR)/usr/lib/klipper/docs
	cp -a $(@D)/docs/*.md $(TARGET_DIR)/usr/lib/klipper/docs/
	echo "$(KLIPPER_DESCRIBE)" > $(TARGET_DIR)/usr/lib/klipper/klippy/.version
	find $(TARGET_DIR)/usr/lib/klipper -name '__pycache__' -prune -exec rm -rf {} +
	$(HOST_DIR)/bin/python3 -m compileall -q -j1 --invalidation-mode unchecked-hash \
		-d /usr/lib/klipper/klippy $(TARGET_DIR)/usr/lib/klipper/klippy
endef

$(eval $(generic-package))
