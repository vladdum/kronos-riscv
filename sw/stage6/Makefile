TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH   := rv64imafdc_zicsr_zifencei
ABI    := lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../stage0/link.ld

TESTS  := test_priv_smode test_delegation test_pmp_basic test_sret test_csr_priv test_priv_smoke \
          test_pma_mmio_load test_pma_mmio_store test_pma_amo_trap \
          test_dcache_raw

BUILD_DIR := build

all: $(TESTS:%=$(BUILD_DIR)/%.hex)

$(BUILD_DIR)/%.hex: %.S ../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
