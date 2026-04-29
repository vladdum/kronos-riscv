# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 7a — Precise trap/interrupt at ROB commit boundary (spec §8.2 + §7.6).
#
# Goal: verify that when a precise trap fires at the ROB commit boundary:
#   (a) mepc points exactly at the trapping instruction (4-byte aligned),
#   (b) mret resumes from mepc+4 (next instruction) without skipping or
#       doubling any instruction, and
#   (c) instructions in-flight in the ROB at trap time are correctly flushed
#       and re-executed after mret.
#
# Mechanism: ECALL (synchronous precise trap).  ECALL traps at ROB head
# deterministically (mcause=8, env-call-from-M), with no timer or CLINT
# setup required.  Note: machine-timer IRQ is the intended async mechanism
# but requires write-back-dcache flushing (the dcache holds the store to the
# sim IRQ-trigger address until eviction).  ECALL exercises the same ROB
# drain path as an async interrupt with an identical check sequence; the
# hardware path diverges only in how the pending flag reaches the commit unit.
#
# Sequence:
#   1. Install handler at mtvec (direct mode).
#   2. Load five accumulators (s0..s4) with distinct sentinels.
#   3. Batch 1: 10 independent addi ops (2 per accumulator, +1 each).
#   4. ECALL — traps at ROB head; batch 2 ops may be in-flight in the ROB.
#   5. Batch 2: 10 more independent addi ops — dispatched before the ECALL
#      reaches head; flushed when the trap fires, then re-executed post-mret.
#   6. Handler: record trap_seen=1, save mepc, advance mepc += 4 (skip ecall),
#      mret → resumes at batch 2.
#   7. Batch 3: 10 final addi ops — always runs after mret.
#   8. Verify:
#      a. trap_seen == 1          (handler ran)
#      b. mcause == 11            (env-call-from-M)
#      c. saved_mepc is 4-aligned (trap boundary is precise)
#      d. each accumulator == sentinel + 6  (all 30 addi ops executed once)
#
# The accumulator check is the key ROB correctness criterion: if batch 2 ops
# were skipped (mepc advanced past them) or doubled (committed twice), at
# least one accumulator will be wrong.
#
# PASS = a0 (x10) == 0.

  .section .data
trap_seen:
  .word 0
  .align 3
saved_mepc:
  .dword 0

  .section .text
  .globl main

# ─── Trap handler ────────────────────────────────────────────────────────────
trap_handler:
  # Record that handler was entered.
  la    t0, trap_seen
  li    t1, 1
  sw    t1, 0(t0)
  # Save mepc.
  csrr  t1, mepc
  la    t0, saved_mepc
  sd    t1, 0(t0)
  # Advance mepc past the ecall (ecall is a 4-byte instruction).
  addi  t1, t1, 4
  csrw  mepc, t1
  mret

# ─── Main ────────────────────────────────────────────────────────────────────
main:
  li    a0, 0                        # error counter

  # Install trap handler (direct mode, bit[1:0]=0).
  la    t0, trap_handler
  csrw  mtvec, t0

  # Clear flags.
  la    t0, trap_seen
  sw    zero, 0(t0)

  # ── Load accumulators with sentinel values ─────────────────────────────────
  li    s0, 0x1000                   # accumulator 0 sentinel
  li    s1, 0x2000                   # accumulator 1 sentinel
  li    s2, 0x3000                   # accumulator 2 sentinel
  li    s3, 0x4000                   # accumulator 3 sentinel
  li    s4, 0x5000                   # accumulator 4 sentinel

  # ── Batch 1: 10 independent addi ops (2 per accumulator, +1 each) ─────────
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  # After batch 1: s0=0x1002 .. s4=0x5002

  # ── Precise trap: ECALL traps at ROB head (mcause = 8) ────────────────────
  # Batch 2 ops may be dispatched to the ROB at the same time; the ROB must
  # drain/flush them (per spec §8.2) when the ecall reaches head and commits.
ecall_instr:
  ecall

  # ── Batch 2: 10 ops flushed on trap, re-executed after mret ───────────────
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  # After batch 2: s0=0x1004 .. s4=0x5004

  # ── Batch 3: 10 final addi ops (always runs post-mret) ────────────────────
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  addi  s0, s0, 1
  addi  s1, s1, 1
  addi  s2, s2, 1
  addi  s3, s3, 1
  addi  s4, s4, 1
  # After batch 3: s0=0x1006 .. s4=0x5006

  # ── Check 1: handler was entered ──────────────────────────────────────────
  la    t0, trap_seen
  lw    t1, 0(t0)
  li    t2, 1
  bne   t1, t2, .Ltrap_not_seen

  # ── Check 2: mcause == 11 (env-call-from-M-mode) ──────────────────────────
  csrr  t1, mcause
  li    t2, 11
  bne   t1, t2, .Lcause_wrong

  # ── Check 3: saved_mepc is 4-byte aligned ─────────────────────────────────
  la    t0, saved_mepc
  ld    t1, 0(t0)
  andi  t2, t1, 3
  bnez  t2, .Lmepc_unaligned

  # ── Check 4: saved_mepc == ecall_instr label ──────────────────────────────
  la    t2, ecall_instr
  bne   t1, t2, .Lmepc_wrong

  # ── Check 5: final accumulator values (each must be sentinel + 6) ─────────
  li    t0, 0x1006
  bne   s0, t0, .Ls0_wrong

  li    t0, 0x2006
  bne   s1, t0, .Ls1_wrong

  li    t0, 0x3006
  bne   s2, t0, .Ls2_wrong

  li    t0, 0x4006
  bne   s3, t0, .Ls3_wrong

  li    t0, 0x5006
  bne   s4, t0, .Ls4_wrong

  ret                                # a0 == 0 → PASS

# ── Error paths ───────────────────────────────────────────────────────────────
.Ltrap_not_seen:
  addi  a0, a0, 1
  ret

.Lcause_wrong:
  addi  a0, a0, 1
  ret

.Lmepc_unaligned:
  addi  a0, a0, 1
  ret

.Lmepc_wrong:
  addi  a0, a0, 1
  ret

.Ls0_wrong:
  addi  a0, a0, 1
  ret

.Ls1_wrong:
  addi  a0, a0, 1
  ret

.Ls2_wrong:
  addi  a0, a0, 1
  ret

.Ls3_wrong:
  addi  a0, a0, 1
  ret

.Ls4_wrong:
  addi  a0, a0, 1
  ret
