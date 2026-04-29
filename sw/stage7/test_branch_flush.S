# Stage 7a — ROB mispredict flush: FPU/muldiv dead-op handling.
#
# The BHT predicts "not-taken" for a forward branch on first encounter.
# We construct a forward branch that IS taken (mispredict), with a long-
# latency FDIV on the not-taken (speculative) path that writes fa1, and
# a MUL on that same path.  After the branch resolves, the ROB must flush
# both wrong-path entries and silently drop their results.
#
# Self-check:
#   s0  = "leak counter", starts 0; wrong path would set it to 99.
#         Must still be 0 after the branch.
#   fa1 = pre-loaded with a sentinel (2.0); wrong path FDIV would write it.
#         Must still be 2.0 after the branch.
#   t4  = pre-loaded with 0xABCD; wrong path MUL would write it.
#         Must still be 0xABCD after the branch.
#   a0  = failure count.  PASS = 0.

  .section .text
  .globl main
main:
  li      a0, 0                   # error counter

  # ----------------------------------------------------------------
  # Pre-branch setup
  # ----------------------------------------------------------------
  li      s0, 0                   # leak counter: must stay 0

  # Load sentinel values that the wrong path must NOT overwrite
  fld     fa1, sentinel_fp, t0    # fa1 = 2.0  (sentinel FP value)
  li      t4, 0xABCD              # t4 = sentinel integer value

  # Operands used on the wrong path to keep the ops non-trivial
  fld     fa2, two_fp, t0         # fa2 = 2.0  (divisor for wrong-path FDIV)
  fld     fa3, eight_fp, t0       # fa3 = 8.0  (dividend for wrong-path FDIV)
  li      t5, 7                   # multiplicand for wrong-path MUL
  li      t6, 13                  # multiplier  for wrong-path MUL

  # ----------------------------------------------------------------
  # The mispredict branch:  BHT default = not-taken for forward branch.
  # We set the condition so the branch IS taken (jump forward over the
  # wrong-path instructions).
  # ----------------------------------------------------------------
  li      t0, 1
  li      t1, 1
  beq     t0, t1, taken_path      # TAKEN — BHT predicts not-taken => mispredict

  # ----------------------------------------------------------------
  # Wrong (speculative) path — must be flushed by ROB
  # ----------------------------------------------------------------
  li      s0, 99                  # leak: must NOT survive
  fdiv.d  fa1, fa3, fa2           # long-latency FP divide — result must be dropped
  mul     t4, t5, t6              # muldiv — result must be dropped
  # extra ALU ops to widen the window and stress the flush logic
  li      t2, 12345
  li      t3, 67890
  add     t2, t2, t3
  add     t2, t2, t3
  j       merge_point             # never executed — here for structural completeness

  # ----------------------------------------------------------------
  # Taken (correct) path
  # ----------------------------------------------------------------
taken_path:
  # Simple ALU work on the correct path
  li      t2, 0x1111
  li      t3, 0x2222
  add     t2, t2, t3              # t2 = 0x3333 (correct-path result, not checked)

merge_point:
  # ----------------------------------------------------------------
  # Verify: flush must have dropped all wrong-path side-effects
  # ----------------------------------------------------------------

  # Check 1: s0 must still be 0
  bnez    s0, fail_s0

  # Check 2: fa1 must still equal 2.0 (sentinel)
  fld     fa0, sentinel_fp, t0    # reload 2.0
  feq.d   t0, fa1, fa0            # t0 = 1 if fa1 == 2.0
  beqz    t0, fail_fa1

  # Check 3: t4 must still be 0xABCD
  li      t1, 0xABCD
  bne     t4, t1, fail_t4

  ret                             # a0 == 0 => PASS

fail_s0:
  addi    a0, a0, 1
  j       fail_fa1_check
fail_fa1_check:
  fld     fa0, sentinel_fp, t0
  feq.d   t0, fa1, fa0
  beqz    t0, fail_fa1
  j       fail_t4_check
fail_fa1:
  addi    a0, a0, 2
fail_t4_check:
  li      t1, 0xABCD
  bne     t4, t1, fail_t4
  ret
fail_t4:
  addi    a0, a0, 4
  ret

  # ----------------------------------------------------------------
  # Read-only data
  # ----------------------------------------------------------------
  .section .rodata
  .align 3
sentinel_fp:
  .double 2.0
two_fp:
  .double 2.0
eight_fp:
  .double 8.0
