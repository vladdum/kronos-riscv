# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 7a — ROB-full back-pressure test.
#
# Strategy:
#   A single FDIV.D is dispatched first.  It occupies ROB slot 0 (head) and
#   takes ~30 cycles to complete.  Fifteen independent integer ADDs follow
#   immediately; they complete in one cycle each but cannot retire because
#   the FDIV is still at the head.  When the 15th ADD fills ROB slot 15 the
#   ROB is full and dispatch stalls on `rob_full`.  The subsequent ADDs are
#   held back by the back-pressure gate until the FDIV completes, retires,
#   and drains the ROB.  Those later ADDs then dispatch and complete normally.
#
#   Self-check: the 15 stalled ADDs and the 2 post-drain ADDs all compute
#   s0 + s1 = 100 + 200 = 300.  Any mismatch increments a0.
#
# PASS = a0 == 0.

  .section .text
  .globl main
main:
  li      a0, 0                 # error counter

  # ----------------------------------------------------------------
  # Load FP operands: ft0 = 1.0, fa0 = 2.0.
  # Uses FCVT.D.L (3-cycle, sequential) so both are ready before FDIV.
  # ----------------------------------------------------------------
  li      t0, 1
  fcvt.d.l  ft0, t0             # ft0 = 1.0
  li      t0, 2
  fcvt.d.l  fa0, t0             # fa0 = 2.0

  # ----------------------------------------------------------------
  # FDIV.D: dispatches to the ROB head, latency ~30 cycles.
  # No subsequent FP ops are issued so fpu_busy resolves after dispatch.
  # ----------------------------------------------------------------
  fdiv.d  fa1, ft0, fa0         # fa1 = 0.5 (ROB slot 0, head)

  # ----------------------------------------------------------------
  # Load integer base values into s0, s1.
  # These dispatch right after FDIV and sit in the ROB behind it.
  # ----------------------------------------------------------------
  li      s0, 100
  li      s1, 200

  # ----------------------------------------------------------------
  # 15 independent integer ADDs — fill ROB slots 3..15 (behind FDIV).
  # They complete in 1 cycle but cannot commit until FDIV retires.
  # When slot 15 fills, rob_full=1 and dispatch stalls.
  # ----------------------------------------------------------------
  add     s2,  s0, s1           # = 300
  add     s3,  s0, s1           # = 300
  add     s4,  s0, s1           # = 300
  add     s5,  s0, s1           # = 300
  add     s6,  s0, s1           # = 300
  add     s7,  s0, s1           # = 300
  add     s8,  s0, s1           # = 300
  add     s9,  s0, s1           # = 300
  add     s10, s0, s1           # = 300
  add     s11, s0, s1           # = 300
  add     t2,  s0, s1           # = 300
  add     t3,  s0, s1           # = 300
  add     t4,  s0, s1           # = 300
  add     t5,  s0, s1           # = 300
  add     t6,  s0, s1           # = 300

  # ----------------------------------------------------------------
  # These 2 ADDs arrive while the ROB is full; dispatch is stalled
  # until the FDIV commits and drains the ROB.
  # ----------------------------------------------------------------
  add     a2,  s0, s1           # = 300 (dispatched post-drain)
  add     a3,  s0, s1           # = 300 (dispatched post-drain)

  # ----------------------------------------------------------------
  # Verify: all 17 ADD results must equal 300.
  # A single mismatch increments a0 (FAIL).
  # ----------------------------------------------------------------
  li      t0, 300
  bne     s2,  t0, 1f
  bne     s3,  t0, 1f
  bne     s4,  t0, 1f
  bne     s5,  t0, 1f
  bne     s6,  t0, 1f
  bne     s7,  t0, 1f
  bne     s8,  t0, 1f
  bne     s9,  t0, 1f
  bne     s10, t0, 1f
  bne     s11, t0, 1f
  bne     t2,  t0, 1f
  bne     t3,  t0, 1f
  bne     t4,  t0, 1f
  bne     t5,  t0, 1f
  bne     t6,  t0, 1f
  bne     a2,  t0, 1f
  bne     a3,  t0, 1f
  j       2f
1:
  addi    a0, a0, 1
2:
  ret
