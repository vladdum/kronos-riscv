# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# start.S — minimal RV64 startup for sw/perf/dhrystone.
# Mirrors sw/stage0/common.S: enable FS=Dirty, zero a0/a1 (Sail boot ABI parity),
# call main, halt on store to 0x40000000 with a0 (return value) as halt signal.
.section .text.start
.global _start
_start:
  la    sp, _stack_top
  li    t0, 0x6000
  csrrs zero, mstatus, t0
  mv    a0, zero
  mv    a1, zero
  call  main
_halt:
  li    t0, 0x40000000
  sw    a0, 0(t0)
  j     _halt
