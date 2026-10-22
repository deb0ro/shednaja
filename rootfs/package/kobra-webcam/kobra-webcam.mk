################################################################################
#
# kobra-webcam (mjpg-streamer service for the printer camera)
#
################################################################################

KOBRA_WEBCAM_VERSION = 1.0
KOBRA_WEBCAM_SITE = $(BR2_EXTERNAL_KOBRA_PATH)/package/kobra-webcam/src
KOBRA_WEBCAM_SITE_METHOD = local
KOBRA_WEBCAM_LICENSE = MIT
KOBRA_WEBCAM_DEPENDENCIES = mjpg-streamer

# The input/output plugins call parse_resolution_opt() etc. from the mjpg_streamer
# executable. With the CMake that Buildroot builds (CMP0065 NEW) the executable is linked
# without -rdynamic, and loading input_uvc.so fails with "can't resolve symbol".
# (mjpg-streamer.mk expands its CONF_OPTS only when configuring, so this applies.)
MJPG_STREAMER_CONF_OPTS += -DCMAKE_ENABLE_EXPORTS=ON

define KOBRA_WEBCAM_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(@D)/S65webcam $(TARGET_DIR)/etc/init.d/S65webcam
endef

# Only input_uvc + output_http are used; the stream is shown by Mainsail/HelixScreen,
# so mjpg-streamer's own web pages go too. libjpeg-turbo's command line tools and
# the TurboJPEG API library are not needed by mjpg-streamer either.
define KOBRA_WEBCAM_TRIM
	cd $(TARGET_DIR)/usr/lib/mjpg-streamer && \
		find . -name '*.so' ! -name input_uvc.so ! -name output_http.so -delete
	rm -rf $(TARGET_DIR)/usr/share/mjpg-streamer
	rm -f $(addprefix $(TARGET_DIR)/usr/bin/,cjpeg djpeg jpegtran rdjpgcom wrjpgcom tjbench)
	rm -f $(TARGET_DIR)/usr/lib/libturbojpeg.so*
endef
KOBRA_WEBCAM_TARGET_FINALIZE_HOOKS += KOBRA_WEBCAM_TRIM

$(eval $(generic-package))
