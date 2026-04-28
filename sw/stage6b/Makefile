TOOLCHAIN := riscv64-unknown-elf
CC        := $(TOOLCHAIN)-gcc
OBJCOPY   := $(TOOLCHAIN)-objcopy
OBJDUMP   := $(TOOLCHAIN)-objdump

ARCH   := rv64imafdc_zicsr_zifencei
ABI    := lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -static -T../stage0/link.ld

TESTS  := test_sv39_basic test_sv48_basic test_superpage_2m test_superpage_1g \
          test_page_fault test_sfence test_ad_update test_user_smode_swap \
          test_integration_long

BUILD_DIR := build

all: $(TESTS:%=$(BUILD_DIR)/%.hex)

$(BUILD_DIR)/%.hex: %.S ../stage0/common.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(@:.hex=.elf) $^
	$(OBJCOPY) -O ihex $(@:.hex=.elf) $@

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
