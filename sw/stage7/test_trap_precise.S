# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 7a — ROB precise-trap test (spec §8.2).
#
# Goal: verify that when instruction K traps at commit, younger instructions
# K+1..K+3 (which may have already completed execution in the OOO back-end)
# do NOT retire architectural state.
#
# Mechanism: ECALL traps deterministically at commit — no MMU setup needed.
# The ROB must not retire the three independent ALU ops that follow the ecall
# in program order.
#
# Setup:
#   t1, t2, t3 start at 0 (never written before main's ecall sequence).
#
# Trap sequence (K = ecall; K+1..K+3 = writes of small constants):
#   K:    ecall                    ← traps at ROB head (mcause=11, ecall-from-M)
#   K+1:  addi t1, x0, 1          ← would write t1=1 if it retired
#   K+2:  addi t2, x0, 2          ← would write t2=2 if it retired
#   K+3:  addi t3, x0, 3          ← would write t3=3 if it retired
#
# K+1..K+3 are independent of current register values (source is x0),
# so they complete in one cycle as soon as they reach the ALU.
#
# Handler: records a trap_seen flag via memory; directs mret to recovery.
#
# Recovery (csrr mcause used to serialise the ROB before register checks):
#   Read mcause via csrr — this is a serialising CSR op that drains the ROB,
#   ensuring any wrong-path ROB entries from after the mret have committed
#   before we inspect t1/t2/t3.
#
# Recovery checks:
#   trap_seen == 1  → trap actually fired
#   t1 == 0         → K+1 did NOT retire
#   t2 == 0         → K+2 did NOT retire
#   t3 == 0         → K+3 did NOT retire
#
# PASS = a0 (x10 = error count) == 0.

  .section .data
trap_seen:
  .word 0

  .section .text
  .globl main

# ─── Trap handler ────────────────────────────────────────────────────────────
trap_handler:
  la    t4, trap_seen
  li    t5, 1
  sw    t5, 0(t4)
  la    t4, recovery
  csrw  mepc, t4
  mret

# ─── Main ────────────────────────────────────────────────────────────────────
main:
  li    a0, 0                      # error counter

  # t1, t2, t3 start at 0 from reset, never written in this test.

  # Install trap handler (direct mode, vector base = trap_handler).
  la    t4, trap_handler
  csrw  mtvec, t4                  # serialising — drains ROB before ecall

  # ── Trap sequence ─────────────────────────────────────────────────────────
  ecall                            # K: traps at ROB head; mcause = 11
  addi  t1, x0, 1                  # K+1: must be flushed
  addi  t2, x0, 2                  # K+2: must be flushed
  addi  t3, x0, 3                  # K+3: must be flushed

recovery:
  # Serialise via csrr mcause: drains any wrong-path ROB entries that
  # were dispatched speculatively after the mret before they could be
  # flushed, so the register checks below see clean architectural state.
  csrr  t6, mcause

  # ── Check 1: trap fired ───────────────────────────────────────────────────
  la    t4, trap_seen
  lw    t5, 0(t4)
  li    t4, 1
  bne   t5, t4, .Ltrap_not_seen

  # ── Check 2: t1 must be 0 ────────────────────────────────────────────────
  bnez  t1, .Lt1_wrong

  # ── Check 3: t2 must be 0 ────────────────────────────────────────────────
  bnez  t2, .Lt2_wrong

  # ── Check 4: t3 must be 0 ────────────────────────────────────────────────
  bnez  t3, .Lt3_wrong

  ret                              # a0 == 0 → PASS

.Ltrap_not_seen:
  addi  a0, a0, 1
  ret

.Lt1_wrong:
  addi  a0, a0, 1
  bnez  t2, .Lt2_wrong_from1
  j     .Lcheck_t3_from1
.Lt2_wrong_from1:
  addi  a0, a0, 1
.Lcheck_t3_from1:
  bnez  t3, .Lt3_wrong_from1
  ret
.Lt3_wrong_from1:
  addi  a0, a0, 1
  ret

.Lt2_wrong:
  addi  a0, a0, 1
  bnez  t3, .Lt3_wrong_from2
  ret
.Lt3_wrong_from2:
  addi  a0, a0, 1
  ret

.Lt3_wrong:
  addi  a0, a0, 1
  ret
