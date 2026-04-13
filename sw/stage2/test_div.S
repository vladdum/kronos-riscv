# test_div.S — DIV / DIVU / REM / REMU + RISC-V edge cases
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
    li   a0, 0

    # ---- DIV (signed divide) ----

    # 20 / 4 = 5
    li   t0, 20
    li   t1, 4
    div  t2, t0, t1
    li   t3, 5
    bne  t2, t3, div_fail_1
    j    div_ok_1
div_fail_1: addi a0, a0, 1
div_ok_1:

    # -20 / 4 = -5
    li   t0, -20
    li   t1, 4
    div  t2, t0, t1
    li   t3, -5
    bne  t2, t3, div_fail_2
    j    div_ok_2
div_fail_2: addi a0, a0, 1
div_ok_2:

    # 20 / -4 = -5
    li   t0, 20
    li   t1, -4
    div  t2, t0, t1
    li   t3, -5
    bne  t2, t3, div_fail_3
    j    div_ok_3
div_fail_3: addi a0, a0, 1
div_ok_3:

    # -20 / -4 = 5
    li   t0, -20
    li   t1, -4
    div  t2, t0, t1
    li   t3, 5
    bne  t2, t3, div_fail_4
    j    div_ok_4
div_fail_4: addi a0, a0, 1
div_ok_4:

    # Division by zero: result = -1 (0xFFFFFFFF) per RISC-V spec
    li   t0, 7
    li   t1, 0
    div  t2, t0, t1
    li   t3, -1
    bne  t2, t3, div_fail_5
    j    div_ok_5
div_fail_5: addi a0, a0, 1
div_ok_5:

    # Signed overflow: INT_MIN / -1 = INT_MIN per RISC-V spec
    li   t0, 0x80000000
    li   t1, -1
    div  t2, t0, t1
    li   t3, 0x80000000
    bne  t2, t3, div_fail_6
    j    div_ok_6
div_fail_6: addi a0, a0, 1
div_ok_6:

    # ---- DIVU (unsigned divide) ----

    # 20 / 4 = 5
    li   t0, 20
    li   t1, 4
    divu t2, t0, t1
    li   t3, 5
    bne  t2, t3, divu_fail_1
    j    divu_ok_1
divu_fail_1: addi a0, a0, 1
divu_ok_1:

    # 0xFFFFFFFF / 2 = 0x7FFFFFFF
    li   t0, -1
    li   t1, 2
    divu t2, t0, t1
    li   t3, 0x7FFFFFFF
    bne  t2, t3, divu_fail_2
    j    divu_ok_2
divu_fail_2: addi a0, a0, 1
divu_ok_2:

    # Division by zero: result = 0xFFFFFFFF per RISC-V spec
    li   t0, 7
    li   t1, 0
    divu t2, t0, t1
    li   t3, -1
    bne  t2, t3, divu_fail_3
    j    divu_ok_3
divu_fail_3: addi a0, a0, 1
divu_ok_3:

    # ---- REM (signed remainder) ----

    # 21 % 4 = 1
    li   t0, 21
    li   t1, 4
    rem  t2, t0, t1
    li   t3, 1
    bne  t2, t3, rem_fail_1
    j    rem_ok_1
rem_fail_1: addi a0, a0, 1
rem_ok_1:

    # -21 % 4 = -1  (sign of dividend)
    li   t0, -21
    li   t1, 4
    rem  t2, t0, t1
    li   t3, -1
    bne  t2, t3, rem_fail_2
    j    rem_ok_2
rem_fail_2: addi a0, a0, 1
rem_ok_2:

    # 21 % -4 = 1  (sign of dividend)
    li   t0, 21
    li   t1, -4
    rem  t2, t0, t1
    li   t3, 1
    bne  t2, t3, rem_fail_3
    j    rem_ok_3
rem_fail_3: addi a0, a0, 1
rem_ok_3:

    # Remainder by zero: result = dividend per RISC-V spec
    li   t0, 21
    li   t1, 0
    rem  t2, t0, t1
    li   t3, 21
    bne  t2, t3, rem_fail_4
    j    rem_ok_4
rem_fail_4: addi a0, a0, 1
rem_ok_4:

    # Signed overflow: INT_MIN % -1 = 0 per RISC-V spec
    li   t0, 0x80000000
    li   t1, -1
    rem  t2, t0, t1
    bnez t2, rem_fail_5
    j    rem_ok_5
rem_fail_5: addi a0, a0, 1
rem_ok_5:

    # ---- REMU (unsigned remainder) ----

    # 21 % 4 = 1
    li   t0, 21
    li   t1, 4
    remu t2, t0, t1
    li   t3, 1
    bne  t2, t3, remu_fail_1
    j    remu_ok_1
remu_fail_1: addi a0, a0, 1
remu_ok_1:

    # Remainder by zero: result = dividend per RISC-V spec
    li   t0, 21
    li   t1, 0
    remu t2, t0, t1
    li   t3, 21
    bne  t2, t3, remu_fail_2
    j    remu_ok_2
remu_fail_2: addi a0, a0, 1
remu_ok_2:

    ret
