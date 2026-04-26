TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy

ARCH   := rv64imafdc_zicsr_zifencei
ABI    := lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../../stage0/link.ld

ASSISTS   := $(patsubst %.S,%,$(wildcard assist_*.S))
BUILD_DIR := build

# Build both Intel HEX (for Vsim_top) and Verilog vmem (for Vtb_crv_cov).
all: $(ASSISTS:%=$(BUILD_DIR)/%.hex) $(ASSISTS:%=$(BUILD_DIR)/%.vmem)

# Keep ELF files (they are intermediates needed by both .hex and .vmem).
.SECONDARY: $(ASSISTS:%=$(BUILD_DIR)/%.elf)

$(BUILD_DIR)/%.elf: %.S ../../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $^

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD_DIR)/%.vmem: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O verilog --verilog-data-width 4 $< $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
