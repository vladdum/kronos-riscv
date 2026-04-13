# common.S — startup: set stack pointer, call main, then halt
# On return from main, a0 (x10) holds the failure count.
# The sim halts when it sees a store to 0x40000000 and prints the write data.
.section .text.start
.global _start
_start:
  la   sp, _stack_top
  call main
  # Halt: write failure count (a0 = x10) to 0x40000000 (sim_main.cpp halts on this)
_halt:
  li   t0, 0x40000000
  sw   a0, 0(t0)
  j    _halt
