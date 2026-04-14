# test_c_basic.S — tests integer C-extension operations
# x10 = failure count; write to 0x40000000 to halt.
.section .text
.globl main
main:
    li   a0, 0

    li   t5, 5
    li   t6, 5
    bne  t5, t6, fail

    li   x3, 99
    mv   x4, x3
    bne  x4, x3, fail

    li   x5, 10
    li   x6, 20
    add  x7, x5, x6
    li   x8, 30
    bne  x7, x8, fail

    li   x9, 100
    addi x9, x9, -1
    li   a0, 99
    bne  x9, a0, fail
    li   a0, 0

    li   a1, 1
    slli a1, a1, 4
    li   a2, 16
    bne  a1, a2, fail

    li   a3, 32
    srli a3, a3, 2
    li   a4, 8
    bne  a3, a4, fail

    li   a5, 0xFF
    andi a5, a5, 0x0F
    li   a6, 0x0F
    bne  a5, a6, fail

    li   a7, 50
    li   s2, 20
    sub  s3, a7, s2
    li   s4, 30
    bne  s3, s4, fail

    li   s5, 0xAA
    li   s6, 0x0F
    and  s5, s5, s6
    li   s7, 0x0A
    bne  s5, s7, fail

    li   s8, 0xA0
    li   s9, 0x0F
    or   s8, s8, s9
    li   s10, 0xAF
    bne  s8, s10, fail

    li   s11, 0xFF
    li   t3, 0xF0
    xor  s11, s11, t3
    li   t4, 0x0F
    bne  s11, t4, fail

    li   sp, 0x800
    li   t0, 0xDEAD
    sw   t0, 0(sp)
    lw   t1, 0(sp)
    bne  t0, t1, fail

    li   a0, 0
    ret
fail:
    li   a0, 1
    ret
