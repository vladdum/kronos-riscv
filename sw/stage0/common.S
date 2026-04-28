# common.S — startup: set stack pointer, call main, then halt
# On return from main, a0 (x10) holds the failure count.
# The sim halts when it sees a store to 0x40000000 and prints the write data.
.section .text.start
.global _start
_start:
  la   sp, _stack_top
  # Enable the FP unit: set mstatus.FS = Dirty (0x6000) so FP instructions
  # are legal on both Kronos (which initialises FS=Dirty at reset) and the
  # Sail reference model (which initialises FS=Off).
  li   t0, 0x6000
  csrrs zero, mstatus, t0
  # Sail's boot ABI puts the hart ID in a0 and the DTB address in a1;
  # Kronos resets all GPRs to 0. Zero them so the CRV Sail-vs-Kronos
  # diff sees identical pre-main state regardless of which model is run.
  mv   a0, zero
  mv   a1, zero
  call main
  # Halt: write failure count (a0 = x10) to 0x40000000 (sim_main.cpp halts on this)
_halt:
  li   t0, 0x40000000
  sw   a0, 0(t0)
  j    _halt
