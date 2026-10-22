################################################################################
#
# kobra-numpy - Buildroot's python-numpy recipe, plus fenv.h for uClibc/ARM
#
################################################################################

KOBRA_NUMPY_VERSION = 1.23.5
KOBRA_NUMPY_SOURCE = numpy-$(KOBRA_NUMPY_VERSION).tar.gz
KOBRA_NUMPY_SITE = https://github.com/numpy/numpy/releases/download/v$(KOBRA_NUMPY_VERSION)
KOBRA_NUMPY_LICENSE = BSD-3-Clause, MIT, Zlib
KOBRA_NUMPY_LICENSE_FILES = \
	LICENSE.txt \
	numpy/core/src/multiarray/dragon4.c \
	numpy/core/include/numpy/libdivide/LICENSE.txt \
	numpy/linalg/lapack_lite/LICENSE.txt \
	tools/npy_tempita/license.txt

KOBRA_NUMPY_SETUP_TYPE = setuptools
KOBRA_NUMPY_DEPENDENCIES = host-python-cython
# no LAPACK/BLAS/Fortran: numpy's bundled lapack_lite is enough for Klipper
KOBRA_NUMPY_ENV = BLAS=None LAPACK=None \
	CFLAGS="$(TARGET_CFLAGS) -I$(@D)/kobra-include" \
	CXXFLAGS="$(TARGET_CXXFLAGS) -I$(@D)/kobra-include"
KOBRA_NUMPY_BUILD_OPTS = --fcompiler=None

define KOBRA_NUMPY_CONFIGURE_CMDS
	rm -f $(@D)/site.cfg
	echo "[DEFAULT]" >> $(@D)/site.cfg
	echo "library_dirs = $(STAGING_DIR)/usr/lib" >> $(@D)/site.cfg
	echo "include_dirs = $(STAGING_DIR)/usr/include" >> $(@D)/site.cfg
	mkdir -p $(@D)/kobra-include
	cp $(BR2_EXTERNAL_KOBRA_PATH)/package/kobra-numpy/include/fenv.h $(@D)/kobra-include/
endef

$(eval $(python-package))
