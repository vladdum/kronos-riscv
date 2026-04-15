// FMV roundtrip with NOPs to eliminate hazards
.section .text
.globl main
main:
    li    a0, 0
    li    t0, 0x3F800000    // t0 = 1.0f bits
    fmv.w.x ft0, t0         // ft0 = NaN-box(1.0f)
    nop
    nop
    nop
    nop
    nop
    fmv.x.w t1, ft0         // t1 = lower 32 bits of ft0 = 0x3F800000
    nop
    nop
    nop
    nop
    nop
    li    t2, 0x3F800000
    beq   t1, t2, 1f
    addi  a0, a0, 1
1:
    ret
