# Stage 7a — CSR write serialization.
#
# A CSR write must drain the pipeline (all younger instructions stall until
# the CSR retires and the pipeline refetches).  This test verifies that a
# csrr issued immediately after a csrw sees the post-write CSR state, not a
# stale value from before the write.
#
# Test sequence (mscratch):
#   1. Write 0xDEADBEEF to mscratch; read back; must see 0xDEADBEEF.
#   2. Write 0xCAFEBABE to mscratch; read back; must see 0xCAFEBABE.
#
# Self-check: a0 (x10) == 0 on PASS, non-zero on FAIL.

  .section .text
  .globl main
main:
  li      a0, 0                   # error counter

  # ---- Round 1: write 0xDEADBEEF, read back -------------------------
  li      t0, 0xDEADBEEF
  csrw    mscratch, t0            # serialize point — drains ROB
  csrr    t1, mscratch            # younger read — must see new value
  li      t2, 0xDEADBEEF
  bne     t1, t2, fail1

  # ---- Round 2: write 0xCAFEBABE, read back -------------------------
  li      t0, 0xCAFEBABE
  csrw    mscratch, t0
  csrr    t1, mscratch
  li      t2, 0xCAFEBABE
  bne     t1, t2, fail2

  ret                             # a0 == 0 => PASS

fail1:
  addi    a0, a0, 1
  ret
fail2:
  addi    a0, a0, 2
  ret
