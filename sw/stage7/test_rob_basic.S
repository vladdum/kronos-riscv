# Stage 7a — ROB basic dispatch + commit roundtrip.
# Single integer ALU instruction stream; verify retire fires and result
# matches expectation. PASS = a0 (x10) == 0.

  .section .text
  .globl main
main:
  li      a0, 0                 # error counter
  li      t0, 0xDEAD
  li      t1, 0xBEEF
  add     t2, t0, t1            # t2 = 0x19D9C
  li      t3, 0x19D9C
  bne     t2, t3, 1f
  ret
1:
  addi    a0, a0, 1
  ret
