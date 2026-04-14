# test_64bit_loadstore.S — LD, SD, LWU, LB/LBU tests
.section .text
.globl main
main:
    li   a0, 0
    la   sp, data

    # SD then LD — round-trip 64-bit
    li   t0, 1
    slli t0, t0, 32
    addi t0, t0, 0x42
    sd   t0, 0(sp)
    ld   t1, 0(sp)
    bne  t0, t1, fail

    # SD negative, LD back
    li   t0, -1
    sd   t0, 8(sp)
    ld   t1, 8(sp)
    bne  t0, t1, fail

    # LW sign-extends
    li   t0, -1
    sw   t0, 16(sp)
    lw   t1, 16(sp)
    li   t2, -1
    bne  t1, t2, fail

    # LWU zero-extends
    lwu  t1, 16(sp)
    srli t2, t1, 32
    bne  t2, x0, fail
    slli t3, t1, 32
    srli t3, t3, 32
    li   t4, -1
    slli t4, t4, 32
    srli t4, t4, 32
    bne  t3, t4, fail

    # LB sign-extends
    li   t0, 0x80
    sb   t0, 24(sp)
    lb   t1, 24(sp)
    li   t2, -128
    bne  t1, t2, fail

    # LBU zero-extends
    lbu  t1, 24(sp)
    li   t2, 0x80
    bne  t1, t2, fail

    li   a0, 0
    ret

fail:
    li   a0, 1
    ret

.section .data
.align 3
data:
    .zero 64
