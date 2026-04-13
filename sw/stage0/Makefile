CC      := riscv64-unknown-elf-gcc
CFLAGS  := -march=rv32i -mabi=ilp32 -nostdlib -static -T link.ld
OBJCOPY := riscv64-unknown-elf-objcopy

BUILD_DIR := build

TESTS := test_rtype test_itype_alu test_load_store test_branch test_ujtype

all: $(addprefix $(BUILD_DIR)/, $(addsuffix .hex, $(TESTS)))

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.elf: %.S common.S link.ld | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $< common.S

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O ihex $< $@

clean:
	rm -rf $(BUILD_DIR)
