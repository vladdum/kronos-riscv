CC      := riscv64-unknown-elf-gcc
CFLAGS  := -march=rv32i -mabi=ilp32 -nostdlib -static -T ../link.ld
OBJCOPY := riscv64-unknown-elf-objcopy
SIM     := ../../../sim/obj_dir/Vkronos_top

RISCV_TESTS := ../../../riscv-tests/isa/rv32ui
MACROS      := ../../../riscv-tests/isa/macros/scalar
INCLUDES    := -I. -I$(MACROS)

# RV32I integer tests — exclude fence_i (unimplemented) and
# misaligned-access tests (ld_st, st_ld, ma_data).
TESTS := add addi and andi auipc beq bge bgeu blt bltu bne \
         jal jalr lb lbu lh lhu lui lw or ori              \
         sb sh sll slli slt slti sltiu sltu                \
         sra srai srl srli sub sw xor xori simple

BUILD_DIR := build

HEXES := $(addprefix $(BUILD_DIR)/, $(addsuffix .hex, $(TESTS)))

all: $(HEXES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.elf: $(RISCV_TESTS)/%.S riscv_test.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $<

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O ihex $< $@

run: all
	@pass=0; fail=0; \
	for t in $(TESTS); do \
	  out=$$($(SIM) $(BUILD_DIR)/$$t.hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    echo "PASS: $$t"; pass=$$((pass+1)); \
	  else \
	    echo "FAIL: $$t (failing test case = $$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "---"; \
	echo "$$pass / $$((pass+fail)) passed"

clean:
	rm -rf $(BUILD_DIR)
