# test_mul.S — MUL / MULH / MULHSU / MULHU instruction test
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
    li   a0, 0          # error counter

    # ---- MUL (lower 32 bits of signed product) ----

    # 3 * 5 = 15
    li   t0, 3
    li   t1, 5
    mul  t2, t0, t1
    li   t3, 15
    bne  t2, t3, mul_fail_1
    j    mul_ok_1
mul_fail_1: addi a0, a0, 1
mul_ok_1:

    # -3 * 5 = -15  (lower 32 bits = 0xFFFFFFF1)
    li   t0, -3
    li   t1, 5
    mul  t2, t0, t1
    li   t3, -15
    bne  t2, t3, mul_fail_2
    j    mul_ok_2
mul_fail_2: addi a0, a0, 1
mul_ok_2:

    # 0x80000000 * 2 lower = 0x00000000 (overflow wraps)
    li   t0, 0x80000000
    li   t1, 2
    mul  t2, t0, t1
    li   t3, 0
    bne  t2, t3, mul_fail_3
    j    mul_ok_3
mul_fail_3: addi a0, a0, 1
mul_ok_3:

    # ---- MULH (upper 32 bits of signed*signed) ----

    # 3 * 5 = 15: upper = 0
    li   t0, 3
    li   t1, 5
    mulh t2, t0, t1
    bnez t2, mulh_fail_1
    j    mulh_ok_1
mulh_fail_1: addi a0, a0, 1
mulh_ok_1:

    # -1 * -1 = 1: upper = 0
    li   t0, -1
    li   t1, -1
    mulh t2, t0, t1
    bnez t2, mulh_fail_2
    j    mulh_ok_2
mulh_fail_2: addi a0, a0, 1
mulh_ok_2:

    # 0x80000000 * 0x80000000: upper = 0x40000000
    li   t0, 0x80000000
    mulh t2, t0, t0
    li   t3, 0x40000000
    bne  t2, t3, mulh_fail_3
    j    mulh_ok_3
mulh_fail_3: addi a0, a0, 1
mulh_ok_3:

    # ---- MULHSU (upper 32 of signed * unsigned) ----

    # -1 (signed) * 1 (unsigned): full product = 0xFFFFFFFF_FFFFFFFF, upper = 0xFFFFFFFF
    li     t0, -1
    li     t1, 1
    mulhsu t2, t0, t1
    li     t3, -1
    bne    t2, t3, mulhsu_fail_1
    j      mulhsu_ok_1
mulhsu_fail_1: addi a0, a0, 1
mulhsu_ok_1:

    # 1 (signed) * 0xFFFFFFFF (unsigned): full = 0x00000000_FFFFFFFF, upper = 0
    li     t0, 1
    li     t1, -1         # assembler treats as unsigned 0xFFFFFFFF
    mulhsu t2, t0, t1
    bnez   t2, mulhsu_fail_2
    j      mulhsu_ok_2
mulhsu_fail_2: addi a0, a0, 1
mulhsu_ok_2:

    # ---- MULHU (upper 32 of unsigned*unsigned) ----

    # 0xFFFFFFFF * 0xFFFFFFFF = 0xFFFFFFFE_00000001, upper = 0xFFFFFFFE
    li    t0, -1         # 0xFFFFFFFF
    mulhu t2, t0, t0
    li    t3, -2         # 0xFFFFFFFE
    bne   t2, t3, mulhu_fail_1
    j     mulhu_ok_1
mulhu_fail_1: addi a0, a0, 1
mulhu_ok_1:

    # 0x00010000 * 0x00010000 = 0x00000001_00000000, upper = 1
    li    t0, 0x00010000
    mulhu t2, t0, t0
    li    t3, 1
    bne   t2, t3, mulhu_fail_2
    j     mulhu_ok_2
mulhu_fail_2: addi a0, a0, 1
mulhu_ok_2:

    ret
