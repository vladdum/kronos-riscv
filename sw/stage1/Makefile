CC      := riscv64-unknown-elf-gcc
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -nostdlib -static -T ../stage0/link.ld
OBJCOPY := riscv64-unknown-elf-objcopy

BUILD_DIR := build

TESTS := test_forwarding test_load_use test_branch_flush test_csr_trap

all: $(addprefix $(BUILD_DIR)/, $(addsuffix .hex, $(TESTS)))

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.elf: %.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $< ../stage0/common.S

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O ihex $< $@

clean:
	rm -rf $(BUILD_DIR)
