# test_word_ops.S — W-suffix instruction tests
.section .text
.globl main
main:
    li   a0, 0

    # ADDIW: 0x7FFFFFFF + 1 sign-extends to negative
    li   t0, 0x7FFFFFFF
    addiw t1, t0, 1
    bge  t1, x0, fail

    # SUBW: 0 - 1 = -1 (sign-extended)
    li   t0, 0
    li   t1, 1
    subw t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail

    # SLLW: 1 << 31 -> negative
    li   t0, 1
    li   t1, 31
    sllw t2, t0, t1
    bge  t2, x0, fail

    # SRLW: logical shift in 32-bit domain
    lui  t0, 0x80000
    li   t1, 1
    srlw t2, t0, t1
    li   t3, 0x40000000
    bne  t2, t3, fail

    # SRAW: arithmetic shift in 32-bit domain
    lui  t0, 0x80000
    li   t1, 1
    sraw t2, t0, t1
    bge  t2, x0, fail
    slli t3, t2, 32
    srli t3, t3, 32
    li   t4, 0xC0000000
    slli t4, t4, 32
    srli t4, t4, 32
    bne  t3, t4, fail

    li   a0, 0
    ret

fail:
    li   a0, 1
    ret
