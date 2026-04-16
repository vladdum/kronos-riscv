TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH   := rv32imc
ABI    := ilp32
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../stage0/link.ld

TESTS  := test_c_basic test_c_control test_bpred_loop test_jalr_fwd_stall

BUILD_DIR := build

all: $(TESTS:%=$(BUILD_DIR)/%.hex)

$(BUILD_DIR)/%.hex: %.S ../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
