# assist_alu_slt.S — directed assist for cg_alu_sign.slt_pos, slt_neg,
#                    cg_alu_sign.sltu_pos, cg_alu_sign.sltu_neg, cg_alu_sign.and_neg
# Why: SLT/SLTU produce 0 (positive result) or 1 (positive result) — the result
#      is always 0 or 1, so bit[63] is always 0. The "neg" bins (bit[63]=1) are
#      unreachable for SLT/SLTU since their results are in {0,1}.
#      AND with all bits set produces a negative result (bit[63]=1).
#      SLT/SLTU results are 0 or 1 (always positive, bit[63]=0).
#      So slt_neg / sltu_neg are unreachable — they are in the excludes list.
#      This assist covers slt_pos, sltu_pos, and and_neg.

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # ---- slt_pos: SLT where result = 1 (positive) ----
    li      t0, 5
    li      t1, 10
    slt     t2, t0, t1      # t2 = 1 (5 < 10)
    li      t3, 1
    bne     t2, t3, 1f
    j       2f
1:  addi    a0, a0, 1
2:

    # ---- slt_pos: SLT where result = 0 (also positive) ----
    li      t0, 10
    li      t1, 5
    slt     t2, t0, t1      # t2 = 0 (10 >= 5)
    bnez    t2, 3f
    j       4f
3:  addi    a0, a0, 1
4:

    # ---- sltu_pos: SLTU where result = 1 ----
    li      t0, 1
    li      t1, 100
    sltu    t2, t0, t1      # t2 = 1 (1 < 100 unsigned)
    li      t3, 1
    bne     t2, t3, 5f
    j       6f
5:  addi    a0, a0, 1
6:

    # ---- sltu_pos: SLTU where result = 0 ----
    li      t0, -1          # 0xFFFFFFFFFFFFFFFF (largest unsigned)
    li      t1, 1
    sltu    t2, t0, t1      # t2 = 0 (0xFFFF... >= 1)
    bnez    t2, 7f
    j       8f
7:  addi    a0, a0, 1
8:

    # ---- and_neg: AND where result has bit[63]=1 ----
    li      t0, -1          # 0xFFFFFFFFFFFFFFFF
    li      t1, -1
    and     t2, t0, t1      # t2 = 0xFFFFFFFFFFFFFFFF (negative)
    bge     t2, zero, 9f   # branch if t2 >= 0 (i.e., not negative) — should NOT branch
    j       10f
9:  addi    a0, a0, 1
10:

    # Another and_neg: AND with a negative operand
    li      t0, -2          # 0xFFFFFFFFFFFFFFFE
    li      t1, -4          # 0xFFFFFFFFFFFFFFFC
    and     t2, t0, t1      # t2 = 0xFFFFFFFFFFFFFFFC (negative)
    bge     t2, zero, 11f
    j       12f
11: addi    a0, a0, 1
12:

    # ---- SLTI/SLTIU (immediate forms) for more coverage ----
    li      t0, -1
    slti    t1, t0, 0       # t1 = 1 (-1 < 0)
    li      t2, 1
    bne     t1, t2, 13f
    j       14f
13: addi    a0, a0, 1
14:

    li      t0, 5
    sltiu   t1, t0, 10      # t1 = 1 (5 < 10 unsigned)
    li      t2, 1
    bne     t1, t2, 15f
    j       16f
15: addi    a0, a0, 1
16:

    ret
