# test_c_control.S — tests C-extension control flow
.section .text
.globl main
main:
    mv   s0, ra
    li   a0, 0

    j    after_j
    li   a0, 1
after_j:

    li   x1, 0
    beqz x1, after_beqz
    li   a0, 1
after_beqz:

    li   x2, 1
    beqz x2, fail

    li   x3, 5
    bnez x3, after_bnez
    li   a0, 1
after_bnez:

    li   x4, 0
    bnez x4, fail

    jal  x1, subr
    j    after_call
subr:
    jr   x1
after_call:

    la   x5, subr2
    jalr x1, 0(x5)
    j    after_call2
subr2:
    ret
after_call2:
    mv   ra, s0

    li   x6, 5
loop:
    addi x6, x6, -1
    bnez x6, loop
    bnez x6, fail

    li   a0, 0
    ret
fail:
    li   a0, 1
    ret
