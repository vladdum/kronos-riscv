# assist_w_extensions.S — directed assist for cg_instr_class.op_imm32 and cg_instr_class.op_reg32
# Why: RV64-only *W instructions (ADDW/SUBW/SLLW/SRLW/SRAW/ADDIW/SLLIW/SRLIW/SRAIW)
#      use the op_imm32 (0b0011011) and op_reg32 (0b0111011) opcodes which were
#      not covered by the existing RV32-biased scenarios.

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # ---- op_imm32: ADDIW ----
    li      t0, 0x7FFFFFFF
    addiw   t1, t0, 1       # t1 = 0x80000000 (sign-extended to -2147483648 in 64-bit)
    li      t2, -2147483648
    bne     t1, t2, 1f
    j       2f
1:  addi    a0, a0, 1
2:

    # ---- op_imm32: SLLIW ----
    li      t0, 1
    slliw   t1, t0, 3       # t1 = 8
    li      t2, 8
    bne     t1, t2, 3f
    j       4f
3:  addi    a0, a0, 1
4:

    # ---- op_imm32: SRLIW ----
    li      t0, 0x80000000
    srliw   t1, t0, 1       # t1 = 0x40000000
    li      t2, 0x40000000
    bne     t1, t2, 5f
    j       6f
5:  addi    a0, a0, 1
6:

    # ---- op_imm32: SRAIW ----
    li      t0, 0x80000000
    sraiw   t1, t0, 1       # t1 = 0xC0000000 sign-extended = -1073741824
    li      t2, -1073741824
    bne     t1, t2, 7f
    j       8f
7:  addi    a0, a0, 1
8:

    # ---- op_reg32: ADDW ----
    li      t0, 0x7FFFFFFF
    li      t1, 1
    addw    t2, t0, t1      # t2 = 0x80000000 sign-extended
    li      t3, -2147483648
    bne     t2, t3, 9f
    j       10f
9:  addi    a0, a0, 1
10:

    # ---- op_reg32: SUBW ----
    li      t0, 10
    li      t1, 3
    subw    t2, t0, t1      # t2 = 7
    li      t3, 7
    bne     t2, t3, 11f
    j       12f
11: addi    a0, a0, 1
12:

    # ---- op_reg32: SLLW ----
    li      t0, 1
    li      t1, 4
    sllw    t2, t0, t1      # t2 = 16
    li      t3, 16
    bne     t2, t3, 13f
    j       14f
13: addi    a0, a0, 1
14:

    # ---- op_reg32: SRLW ----
    li      t0, 0x80000000
    li      t1, 1
    srlw    t2, t0, t1      # t2 = 0x40000000
    li      t3, 0x40000000
    bne     t2, t3, 15f
    j       16f
15: addi    a0, a0, 1
16:

    # ---- op_reg32: SRAW ----
    li      t0, 0x80000000
    li      t1, 1
    sraw    t2, t0, t1      # t2 = 0xC0000000 sign-extended
    li      t3, -1073741824
    bne     t2, t3, 17f
    j       18f
17: addi    a0, a0, 1
18:

    ret
