# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Stage 7a — MRET serialises: no instruction after MRET retires, and the
# pipeline resumes cleanly at mepc.
#
# Goal (spec §8.2 + §7.4):
#   MRET is a serialising instruction in the ROB: when MRET dispatches,
#   drain_mode prevents any further dispatch, and when MRET reaches the EX
#   stage its ex_redirect flushes IF/ID — ensuring that any instructions
#   placed after MRET in the handler stream are never fetched and never retire.
#   After MRET, control must transfer exactly to mepc and execution continues.
#
# Test sequence:
#   1. Set integer sentinels: s0=0xAAAA, s1=0xBBBB.
#   2. Install mtvec=handler; trigger ECALL.
#   3. Handler (entered from ECALL, M-mode):
#       a. Set mepc=after_trap (skips the ecall on return).
#       b. MRET — redirect fetch to after_trap; drain_mode cleared on commit.
#       c. [dead code after MRET] li s0, 0xDEAD — must NOT execute.
#       d. [dead code after MRET] li s1, 0xDEAD — must NOT execute.
#   4. after_trap:
#       a. Verify s0==0xAAAA (dead code c did not corrupt s0).
#       b. Verify s1==0xBBBB (dead code d did not corrupt s1).
#       c. Load a FP sentinel (ft1=2.0) via fld from memory.
#          Verify ft1==2.0 via fmv.x.d and integer compare.
#          (FP load exercises the ROB FP-dest commit path post-MRET.)
#   5. PASS = a0 (x10) == 0.
#
# c.fldsp rd=0 note: "fld ft0,N(sp)" assembles to the reserved c.fldsp rd=0
# encoding and causes an illegal-instruction trap.  All FP loads targeting
# ft0 (f0) must use a non-sp base register to force the full 4-byte FLD.
# This test uses ft1 (f1) which can use sp as base (c.fldsp rd=1 is legal).
#
# PASS = a0 (x10) == 0.

  .section .text
  .globl main
main:
  addi    sp, sp, -32

  # -------------------------------------------------------------------------
  # Set integer sentinels.
  # -------------------------------------------------------------------------
  li      s0, 0xAAAA
  li      s1, 0xBBBB

  # -------------------------------------------------------------------------
  # Install mtvec; trigger ECALL.
  # -------------------------------------------------------------------------
  la      t0, handler
  csrw    mtvec, t0
  ecall

  # -------------------------------------------------------------------------
  # after_trap: MRET redirected here.
  # -------------------------------------------------------------------------
after_trap:
  li      a0, 0                       # error counter

  # ---- Check 1: s0 must be 0xAAAA (dead code after MRET did not run) ------
  li      t0, 0xAAAA
  bne     s0, t0, .Lfail_s0

  # ---- Check 2: s1 must be 0xBBBB (second dead instruction did not run) ---
  li      t0, 0xBBBB
  bne     s1, t0, .Lfail_s1

  # ---- Check 3: FP load round-trip via fld + fmv.x.d ----------------------
  # Store 2.0 (0x4000000000000000) to memory, load into ft1, read back.
  # ft1=f1: c.fldsp rd=1 is a legal compressed encoding.
  li      t0, 0x40000000
  slli    t0, t0, 32                  # t0 = 0x4000000000000000 (2.0)
  sd      t0, 0(sp)
  fld     ft1, 0(sp)                  # ft1 = 2.0 (c.fldsp rd=1, legal)

  fmv.x.d t1, ft1                     # t1 = bit-pattern of ft1
  li      t2, 0x40000000
  slli    t2, t2, 32                  # t2 = 0x4000000000000000
  bne     t1, t2, .Lfail_fp

  addi    sp, sp, 32
  ret                                 # a0 = 0 → PASS

.Lfail_s0:
  addi    a0, a0, 4                   # dead code ran, corrupted s0
  addi    sp, sp, 32
  ret

.Lfail_s1:
  addi    a0, a0, 2                   # dead code ran, corrupted s1
  addi    sp, sp, 32
  ret

.Lfail_fp:
  addi    a0, a0, 1                   # FP load/readback mismatch
  addi    sp, sp, 32
  ret

  # -------------------------------------------------------------------------
  # Trap handler — entered from ECALL (M-mode).
  # -------------------------------------------------------------------------
  .balign 4
handler:
  # Redirect mepc to after_trap (advances past the ecall).
  la      t0, after_trap
  csrw    mepc, t0

  # MRET: serialise ROB, flush IF/ID, redirect fetch to mepc=after_trap.
  mret

  # ---- Dead code — must NOT execute ---------------------------------------
  li      s0, 0xDEAD                  # Check 1 fails if this runs
  li      s1, 0xDEAD                  # Check 2 fails if this runs
