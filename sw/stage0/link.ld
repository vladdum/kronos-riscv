MEMORY {
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
  RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}
SECTIONS {
  .text : { *(.text.start) *(.text*) } > ROM
  .data : { *(.data*) *(.rodata*) } > RAM
  .bss  : { *(.bss*) *(COMMON) } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
