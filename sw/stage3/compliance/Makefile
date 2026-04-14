CC      := riscv64-unknown-elf-gcc
CFLAGS  := -march=rv32imc -mabi=ilp32 -nostdlib -static -T ../../stage0/link.ld
OBJCOPY := riscv64-unknown-elf-objcopy
SIM     := ../../../sim/obj_dir/s3/Vsim_top

RISCV_TESTS_UC := ../../../riscv-tests/isa/rv32uc
RISCV_TESTS_UI := ../../../riscv-tests/isa/rv32ui
MACROS         := ../../../riscv-tests/isa/macros/scalar
INCLUDES       := -I../../stage0/compliance -I$(MACROS)

# RV32C compliance tests
TESTS_UC := rvc

# RV32I integer tests (rerun on stage3 sim with -march=rv32imc) — exclude
# fence_i (unimplemented) and misaligned-access tests.
TESTS_UI := add addi and andi auipc beq bge bgeu blt bltu bne \
            jal jalr lb lbu lh lhu lui lw or ori              \
            sb sh sll slli slt slti sltiu sltu                \
            sra srai srl srli sub sw xor xori simple

BUILD_DIR := build

HEXES_UC := $(addprefix $(BUILD_DIR)/uc_, $(addsuffix .hex, $(TESTS_UC)))
HEXES_UI := $(addprefix $(BUILD_DIR)/ui_, $(addsuffix .hex, $(TESTS_UI)))

all: $(HEXES_UC) $(HEXES_UI)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/uc_%.elf: $(RISCV_TESTS_UC)/%.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $<

$(BUILD_DIR)/ui_%.elf: $(RISCV_TESTS_UI)/%.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $<

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O ihex $< $@

run: all
	@pass=0; fail=0; \
	echo "=== rv32uc ==="; \
	for t in $(TESTS_UC); do \
	  out=$$($(SIM) $(BUILD_DIR)/uc_$$t.hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    echo "PASS: uc/$$t"; pass=$$((pass+1)); \
	  else \
	    echo "FAIL: uc/$$t (failing test case = $$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "=== rv32ui (compressed build) ==="; \
	for t in $(TESTS_UI); do \
	  out=$$($(SIM) $(BUILD_DIR)/ui_$$t.hex 2>&1); \
	  x10=$$(echo "$$out" | grep -oP 'x10 = \K[0-9]+'); \
	  if [ "$$x10" = "0" ]; then \
	    echo "PASS: ui/$$t"; pass=$$((pass+1)); \
	  else \
	    echo "FAIL: ui/$$t (failing test case = $$x10)"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "---"; \
	echo "$$pass / $$((pass+fail)) passed"; \
	[ $$fail -eq 0 ]

clean:
	rm -rf $(BUILD_DIR)
