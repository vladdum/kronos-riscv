SF_ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SF_BUILD   := $(SF_ROOT)/build
SF_LIB     := $(SF_BUILD)/softfloat.a
SF_INCS    := -I$(SF_BUILD) -I$(SF_ROOT)/source/include
SF_DPI_SRC := $(SF_ROOT)/dpi/softfloat_dpi.cpp

$(SF_LIB):
	$(MAKE) -C $(SF_BUILD) SPECIALIZE_TYPE=RISCV SOURCE_DIR=$(SF_ROOT)/source
