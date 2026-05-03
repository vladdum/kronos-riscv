# cosim/Makefile — GCC-compiled C corpus for Sail-diff cosimulation.
# Mirrors the stage6 SW Makefile: -nostdlib, static link, ihex output.
TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy

ARCH      := rv64imafdc_zicsr
ABI       := lp64
CFLAGS    := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -Os -T../stage0/link.ld

# Corpus discovery — every .c in this directory.
SRCS  := $(wildcard *.c)
TESTS := $(SRCS:%.c=%)

BUILD := build

all: $(TESTS:%=$(BUILD)/%.hex)

$(BUILD)/%.hex: %.c cosim_common.S | $(BUILD)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD):
	mkdir -p $@

.PHONY: all clean
clean:
	rm -rf $(BUILD)
