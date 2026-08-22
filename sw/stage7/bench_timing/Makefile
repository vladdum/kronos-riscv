TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH   := rv64imafdc_zicsr_zifencei
ABI    := lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../../stage0/link.ld

# One .S per instruction class in docs/architecture.md §11 Timing Table,
# plus bench_overhead (the loop-tail baseline every other bench's total is
# measured against: cycles/op = (class_total - overhead_total)/100).
TESTS  := bench_overhead \
          bench_alu \
          bench_taken_branch \
          bench_mispredict \
          bench_load_hit \
          bench_load_use_hit \
          bench_store_hit \
          bench_mul \
          bench_div32 \
          bench_div64 \
          bench_amo \
          bench_fadd \
          bench_fmul \
          bench_fma \
          bench_fdiv_s \
          bench_fdiv_d \
          bench_csr \
          bench_trap

BUILD_DIR := build

all: $(TESTS:%=$(BUILD_DIR)/%.hex)

$(BUILD_DIR)/%.hex: %.S ../../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
