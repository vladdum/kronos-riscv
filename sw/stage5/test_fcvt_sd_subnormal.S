// FCVT.S.D into single-precision subnormal range.
// Three categories:
//   - exponent in [-149, -126): rounds to single subnormal
//   - exponent in [-126, ...]:  rounds to single normal (already worked)
//   - exponent <  -149:         rounds to signed zero
// a0 accumulates failures; a0=0 means pass.
//
// Note: fmv.x.w sign-extends the single-precision bit pattern into the 64-bit
// integer register (RV64). For comparisons with positive constants loaded via
// `li`, mask the upper 32 bits of t1 first.

.section .text
.globl main

main:
    li      a0, 0
    csrwi   frm, 0                  // RNE

    // Test 1: D = 1.0 * 2^-130 -> S subnormal with mant = 1 << 19
    //   Double pattern: sign=0, exp=(1023-130)=893=0x37D, mant=0
    //     => 0x37D0_0000_0000_0000
    //   Expected single subnormal: exp=0, mant = 1 << (23 - (130-126)) = 1 << 19
    //     => 0x0008_0000
    li      t0, 0x37D0000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    li      t2, 0x00080000
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // Test 2: D = -1.0 * 2^-140 -> S subnormal, sign bit set
    //   Double exp = 1023-140 = 883 = 0x373
    //   => 0xB730_0000_0000_0000  (sign=1, exp=0x373, mant=0)
    //   Expected single: sign=1, exp=0, mant = 1 << (23 - 14) = 1 << 9 = 0x200
    //     => 0x80000200
    li      t0, 0xB730000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    li      t2, 0x80000200
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // Test 3: D = 1.0 * 2^-150 -> underflows to +0 (below smallest subnormal)
    //   Double exp = 1023-150 = 873 = 0x369
    //   => 0x3690_0000_0000_0000
    //   Expected: 0x00000000, UF + NX flags set.
    csrwi   fflags, 0
    li      t0, 0x3690000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    bnez    t1, 3f                  // expect 0
    csrr    t0, fflags
    andi    t0, t0, 0x03            // UF (bit 1) | NX (bit 0) = 0x03
    li      t2, 0x03
    beq     t0, t2, 4f
3:
    addi    a0, a0, 1
4:

    // Test 4: D = 1.0 * 2^-127 -> single subnormal with hidden bit
    //   shift = -126 - (-127) + 1 = 2; mant = (1<<23) >> 1 = 0x400000
    //   Double exp = 896 = 0x380; pattern 0x3800_0000_0000_0000
    //   Expected single: exp=0, mant=0x400000  => 0x00400000
    li      t0, 0x3800000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    li      t2, 0x00400000
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:

    // Test 5: D = 1.0 * 2^-400 -> deeply tiny, must flush to +0 with UF|NX
    //   Double exp = 1023-400 = 623 = 0x26F; pattern 0x26F0_0000_0000_0000
    //   Unwrapped shift_amt = -126 - (-400) = 274 (>= 25 -> flush to zero)
    //   Expected: 0x00000000, UF + NX flags set.
    csrwi   fflags, 0
    li      t0, 0x26F0000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    bnez    t1, 6f                  // expect 0
    csrr    t0, fflags
    andi    t0, t0, 0x03            // UF (bit 1) | NX (bit 0) = 0x03
    li      t2, 0x03
    beq     t0, t2, 7f
6:
    addi    a0, a0, 1
7:

    // Test 6: D = 1.0 * 2^-382 -> regression-catcher for the 8-bit truncation bug.
    //   Double exp = 1023-382 = 641 = 0x281; pattern 0x2810_0000_0000_0000
    //   Unwrapped shift_amt = -126 - (-382) = 256.
    //   Old 8-bit code wrapped 256 -> 0, slipping past the >= 25 guard and
    //   producing 0x00800000 (~2^-126). 10-bit shift correctly flushes to +0.
    //   Expected: 0x00000000, UF + NX flags set.
    csrwi   fflags, 0
    li      t0, 0x2810000000000000
    fmv.d.x ft0, t0
    fcvt.s.d ft1, ft0
    fmv.x.w t1, ft1
    slli    t1, t1, 32
    srli    t1, t1, 32
    bnez    t1, 8f                  // expect 0
    csrr    t0, fflags
    andi    t0, t0, 0x03            // UF (bit 1) | NX (bit 0) = 0x03
    li      t2, 0x03
    beq     t0, t2, 9f
8:
    addi    a0, a0, 1
9:

    csrwi   fflags, 0
    ret
