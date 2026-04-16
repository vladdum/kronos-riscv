TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH   := rv64imafdc_zicsr
ABI    := lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../stage0/link.ld

TESTS  := test_fdiv_basic test_fsqrt_basic test_fdiv_rounding test_fsqrt_rounding \
          test_fdiv_exceptions test_fsqrt_exceptions test_fdiv_subnormal \
          test_fsqrt_subnormal test_fdiv_nan_box test_fdiv_stall

BUILD_DIR := build

all: $(TESTS:%=$(BUILD_DIR)/%.hex)

$(BUILD_DIR)/%.hex: %.S ../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
