// RV64I basic test: exercise 64-bit ops, W-suffix, 6-bit shamt, and LD/SD.
// x10 accumulates failure count; x10 = 0 means pass.
//
// Layout:
//   - register reserved as fail counter: a0 (x10), initialized to 0
//   - scratch data area: label `data` — 64 bytes, 8-byte aligned

.section .text
.globl main

main:
    li      a0, 0                  // fail counter

    // --------------------------------------------------------------
    // Test 1: SLLI by 32 then SRLI by 32 round-trips a 32-bit value
    //   t0 = 1; t0 <<= 32  -> 0x0000_0001_0000_0000
    //   t1 = t0 >> 32     -> 0x0000_0000_0000_0001
    // --------------------------------------------------------------
    li      t0, 1
    slli    t0, t0, 32
    srli    t1, t0, 32
    li      t2, 1
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // --------------------------------------------------------------
    // Test 2: SRAI by 32 sign-extends
    //   t0 = 0xFFFF_FFFF_0000_0000 (via LUI+SLLI)
    //   t1 = t0 >>> 32  -> 0xFFFF_FFFF_FFFF_FFFF
    // --------------------------------------------------------------
    li      t0, -1
    slli    t0, t0, 32             // 0xFFFF_FFFF_0000_0000
    srai    t1, t0, 32             // 0xFFFF_FFFF_FFFF_FFFF
    li      t2, -1
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // --------------------------------------------------------------
    // Test 3: ADDW sign-extends a 32-bit add result
    //   t0 = 0x7FFFFFFF; t1 = 1
    //   t2 = ADDW(t0,t1) -> 0xFFFF_FFFF_8000_0000
    // --------------------------------------------------------------
    li      t0, 0x7FFFFFFF
    li      t1, 1
    addw    t2, t0, t1
    li      t3, 0xFFFFFFFF80000000
    beq     t2, t3, 3f
    addi    a0, a0, 1
3:

    // --------------------------------------------------------------
    // Test 4: SUBW wraparound sign-extends
    //   t0 = 0; t1 = 1
    //   t2 = SUBW(t0,t1) -> 0xFFFF_FFFF_FFFF_FFFF
    // --------------------------------------------------------------
    li      t0, 0
    li      t1, 1
    subw    t2, t0, t1
    li      t3, -1
    beq     t2, t3, 4f
    addi    a0, a0, 1
4:

    // --------------------------------------------------------------
    // Test 5: LUI sign-extends bit 31
    //   t0 = LUI 0x80000  -> 0xFFFF_FFFF_8000_0000
    // --------------------------------------------------------------
    lui     t0, 0x80000
    li      t1, 0xFFFFFFFF80000000
    beq     t0, t1, 5f
    addi    a0, a0, 1
5:

    // --------------------------------------------------------------
    // Test 6: SD/LD round-trip on a 64-bit pattern
    //   store 0xDEAD_BEEF_CAFE_BABE to data, load back, compare
    // --------------------------------------------------------------
    la      t0, data
    li      t1, 0xDEADBEEFCAFEBABE
    sd      t1, 0(t0)
    ld      t2, 0(t0)
    bne     t1, t2, 6f
    j       7f
6:
    addi    a0, a0, 1
7:

    ret

.section .data
.align 3
data:
    .zero 64
