// Minimal FMV roundtrip: FMV.W.X ft0, t0 then FMV.X.W t1, ft0
// x10=0 means pass. One test only.
.section .text
.globl main
main:
    li    a0, 0
    li    t0, 0x3F800000    // t0 = 1.0f bits
    fmv.w.x ft0, t0         // ft0 = NaN-box(1.0f)
    fmv.x.w t1, ft0         // t1 = lower 32 bits of ft0 = 0x3F800000
    li    t2, 0x3F800000
    beq   t1, t2, 1f
    addi  a0, a0, 1
1:
    ret
