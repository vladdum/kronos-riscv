# test_muldiv_hazards.S — RAW hazards through muldiv results
# Verifies that muldiv results forward correctly through existing paths.
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
    li   a0, 0

    # ---- EX/MEM forward: consumer one instruction after muldiv ----
    # MUL t0, t1, t2
    # ADD t3, t0, t4   <- t0 forwarded from EX/MEM
    li   t1, 6
    li   t2, 7
    li   t4, 10
    mul  t0, t1, t2          # t0 = 42
    add  t3, t0, t4          # t3 = 52 (t0 from EX/MEM forward)
    li   t5, 52
    bne  t3, t5, haz_fail_1
    j    haz_ok_1
haz_fail_1: addi a0, a0, 1
haz_ok_1:

    # ---- MEM/WB forward: consumer two instructions after muldiv ----
    # MUL t0, t1, t2
    # NOP (addi x0,x0,0)
    # ADD t3, t0, t4   <- t0 forwarded from MEM/WB
    li   t1, 5
    li   t2, 8
    li   t4, 3
    mul  t0, t1, t2          # t0 = 40
    addi x0, x0, 0           # NOP
    add  t3, t0, t4          # t3 = 43 (t0 from MEM/WB forward)
    li   t5, 43
    bne  t3, t5, haz_fail_2
    j    haz_ok_2
haz_fail_2: addi a0, a0, 1
haz_ok_2:

    # ---- Chained muldiv: second muldiv uses result of first ----
    # MUL t0, t1, t2        # t0 = 3*4 = 12
    # MUL t3, t0, t4        # t3 = 12*5 = 60 (t0 must be ready)
    li   t1, 3
    li   t2, 4
    li   t4, 5
    mul  t0, t1, t2          # t0 = 12
    mul  t3, t0, t4          # t3 = 60
    li   t5, 60
    bne  t3, t5, haz_fail_3
    j    haz_ok_3
haz_fail_3: addi a0, a0, 1
haz_ok_3:

    # ---- DIV result forwarded to ADD ----
    li   t1, 100
    li   t2, 5
    li   t4, 7
    div  t0, t1, t2          # t0 = 20
    add  t3, t0, t4          # t3 = 27 (t0 from EX/MEM forward)
    li   t5, 27
    bne  t3, t5, haz_fail_4
    j    haz_ok_4
haz_fail_4: addi a0, a0, 1
haz_ok_4:

    # ---- muldiv result used as store address ----
    # SW base address via MUL result
    la   t4, scratch
    li   t1, 4
    li   t2, 1               # t1*t2 = 4 (offset from scratch)
    mul  t0, t1, t2          # t0 = 4
    add  t5, t4, t0          # t5 = scratch+4
    li   t6, 0xABCD
    sw   t6, 0(t5)
    lw   t3, 0(t5)
    li   t5, 0xABCD
    bne  t3, t5, haz_fail_5
    j    haz_ok_5
haz_fail_5: addi a0, a0, 1
haz_ok_5:

    ret

.section .data
scratch: .word 0, 0, 0, 0
