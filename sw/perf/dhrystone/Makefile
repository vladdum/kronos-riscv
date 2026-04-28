# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH    := rv64imafdc_zicsr_zifencei
ABI     := lp64d
CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -O2 -nostdlib -static -ffreestanding \
           -std=gnu89 \
           -Wno-implicit-int -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
           -Wno-old-style-definition
LDFLAGS := -T link.ld -Wl,--no-relax

SRCS_C  := dhry_1.c dhry_2.c dhry_main.c
SRCS_S  := start.S
OBJS    := $(SRCS_C:%.c=build/%.o) $(SRCS_S:%.S=build/%.o)

BUILD_DIR := build

all: $(BUILD_DIR)/dhrystone.hex

build/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

build/%.o: %.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/dhrystone.elf: $(OBJS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

$(BUILD_DIR)/dhrystone.hex: $(BUILD_DIR)/dhrystone.elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
