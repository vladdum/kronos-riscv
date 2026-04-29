# Stage 7a — OoO FP/int interleaved completion test.
#
# Goal: prove that independent integer ADDs complete and commit before a
# long-latency FDIV.D retires.  The integer stream has zero RAW dependencies
# on the FP operands; the ROB must retire them in program order while the
# long-latency FDIV is still in-flight.
#
# Sequence
#   1. Load ft0 = 12.0d via fmv.d.x.
#   2. Load ft1 =  4.0d via fmv.d.x, then issue 10 integer ADDs.
#      — ft1 is loaded before the integer ADD burst; by the time the 10
#        integer ADDs flow through the ROB, ft1 has completed and committed
#        to the FP register file (eliminating any pending busy-table entry).
#   3. Issue FDIV.D ft2, ft0, ft1 after the integer burst.
#      — Since ft1 is now architecturally committed, the FP regfile read at
#        dispatch gives the correct value regardless of ROB forwarding state.
#   4. Issue 10 more independent integer ADDs (different dest regs, no FP dep).
#      — These retire while FDIV is still in-flight, demonstrating OoO.
#   5. Sum all 20 integer ADD results; check against expected constant.
#   6. Verify ft2 == 3.0d via fmv.x.d.
#
# FP values:  ft0 = 12.0d (0x4028000000000000)
#             ft1 =  4.0d (0x4010000000000000)
#             ft2 = FDIV.D result = 3.0d (0x4008000000000000)
#
# Integer ADDs (20 independent, distinct destinations):
#   First 10 (issued before FDIV):
#     t0=1+2=3, t1=3+4=7, t2=5+6=11, t3=7+8=15, t4=9+10=19,
#     t5=11+12=23, t6=13+14=27, s0=15+16=31, s1=17+18=35, s2=19+20=39
#   Second 10 (issued after FDIV, retire before FDIV):
#     a1=1+1=2, a2=2+2=4, a3=3+3=6, a4=4+4=8, a5=5+5=10,
#     a6=6+6=12, a7=7+7=14, s3=8+8=16, s4=9+9=18, s5=10+10=20
#   total sum = (3+7+11+15+19+23+27+31+35+39) + (2+4+6+8+10+12+14+16+18+20)
#             = 210 + 110 = 320
#
# PASS = a0 (x10) == 0.

  .section .text
  .globl main
main:
  li      a0, 0                     # error counter

  # -----------------------------------------------------------------------
  # Step 1: Load ft0 = 12.0d
  # -----------------------------------------------------------------------
  li      t0, 0x4028000000000000
  fmv.d.x ft0, t0                   # ft0 = 12.0d

  # -----------------------------------------------------------------------
  # Step 2: Load ft1 = 4.0d, then issue 10 integer ADDs.
  # By the time all 10 ADDs have been dispatched to the ROB and retired,
  # fmv.d.x ft1 will have completed in the FPU and committed to the
  # architectural FP register file, clearing its busy-table entry.
  # -----------------------------------------------------------------------
  li      t4, 0x4010000000000000
  fmv.d.x ft1, t4                   # ft1 = 4.0d

  # First 10 integer ADDs — no FP dependence.
  li      t0, 1
  li      t5, 2
  add     t0, t0, t5                # t0 = 3

  li      t1, 3
  li      t5, 4
  add     t1, t1, t5                # t1 = 7

  li      t2, 5
  li      t5, 6
  add     t2, t2, t5                # t2 = 11

  li      t3, 7
  li      t5, 8
  add     t3, t3, t5                # t3 = 15

  li      t4, 9
  li      t5, 10
  add     t4, t4, t5                # t4 = 19

  li      t5, 11
  li      t6, 12
  add     t5, t5, t6                # t5 = 23

  li      t6, 13
  li      s0, 14
  add     t6, t6, s0                # t6 = 27

  li      s0, 15
  li      s1, 16
  add     s0, s0, s1                # s0 = 31

  li      s1, 17
  li      s2, 18
  add     s1, s1, s2                # s1 = 35

  li      s2, 19
  li      s3, 20
  add     s2, s2, s3                # s2 = 39

  # -----------------------------------------------------------------------
  # Step 3: Issue long-latency FDIV.D.
  # ft0 and ft1 are architecturally committed at this point (their busy
  # entries were cleared when they committed). The regfile read is correct.
  # -----------------------------------------------------------------------
  fdiv.d  ft2, ft0, ft1             # ft2 = 12.0d / 4.0d = 3.0d

  # -----------------------------------------------------------------------
  # Step 4: Second burst of 10 independent integer ADDs.
  # These have no dependence on ft2 (FDIV in-flight).
  # In an OoO ROB they complete and retire while FDIV is still executing.
  # -----------------------------------------------------------------------
  li      a1, 1
  add     a1, a1, a1                # a1 = 2

  li      a2, 2
  add     a2, a2, a2                # a2 = 4

  li      a3, 3
  add     a3, a3, a3                # a3 = 6

  li      a4, 4
  add     a4, a4, a4                # a4 = 8

  li      a5, 5
  add     a5, a5, a5                # a5 = 10

  li      a6, 6
  add     a6, a6, a6                # a6 = 12

  li      a7, 7
  add     a7, a7, a7                # a7 = 14

  li      s3, 8
  add     s3, s3, s3                # s3 = 16

  li      s4, 9
  add     s4, s4, s4                # s4 = 18

  li      s5, 10
  add     s5, s5, s5                # s5 = 20

  # -----------------------------------------------------------------------
  # Step 5: Verify total integer sum == 320
  # First 10: t0..t6, s0..s2; second 10: a1..a7, s3..s5
  # -----------------------------------------------------------------------
  add     s6, t0, t1
  add     s6, s6, t2
  add     s6, s6, t3
  add     s6, s6, t4
  add     s6, s6, t5
  add     s6, s6, t6
  add     s6, s6, s0
  add     s6, s6, s1
  add     s6, s6, s2                # s6 = 210 (first 10)

  add     s7, a1, a2
  add     s7, s7, a3
  add     s7, s7, a4
  add     s7, s7, a5
  add     s7, s7, a6
  add     s7, s7, a7
  add     s7, s7, s3
  add     s7, s7, s4
  add     s7, s7, s5                # s7 = 110 (second 10)

  add     s8, s6, s7                # s8 = 320

  li      s9, 320
  bne     s8, s9, 2f                # mismatch -> error 1

  # -----------------------------------------------------------------------
  # Step 6: Verify FDIV.D result ft2 == 3.0d (0x4008000000000000)
  # fmv.x.d stalls (operand_stall via rs1_fp_stall) until fdiv.d has
  # completed in the FPU and the ROB entry is marked complete.
  # -----------------------------------------------------------------------
  fmv.x.d a4, ft2                   # a4 = bits of ft2
  li      a5, 0x4008000000000000
  bne     a4, a5, 3f                # mismatch -> error 2

  ret                               # a0 = 0 => PASS

2:
  addi    a0, a0, 1                 # integer sum wrong
  ret

3:
  addi    a0, a0, 2                 # FP result wrong
  ret
