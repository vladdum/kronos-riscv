// test_blt64.S — BLT with 64-bit near-maxint operands.
// a0 = 0 means all pass.

.section .text
.globl main

main:
    li      a0, 0               // fail counter

    // --- Test 1: BLT with immediate li (no forwarding hazard) ---
    li      t1, 1
    slli    t1, t1, 62          // t1 = 0x4000000000000000
    slli    t1, t1, 1           // t1 = 0x8000000000000000 (INT64_MIN)
    addi    t1, t1, -1          // t1 = 0x7FFFFFFFFFFFFFFF
    addi    t2, t1, -1          // t2 = 0x7FFFFFFFFFFFFFFE  (rs1)
    mv      t3, t1              // t3 = 0x7FFFFFFFFFFFFFFF  (rs2)
    nop
    nop
    nop
    blt     t2, t3, 1f
    addi    a0, a0, 1           // FAIL: t2 < t3 not taken
1:

    // --- Test 2: BLT via LD then addi ---
    la      t0, val_a
    ld      t2, 0(t0)           // t2 = 0x7FFFFFFFFFFFFFFE
    addi    t3, t2, 1           // t3 = 0x7FFFFFFFFFFFFFFF
    blt     t2, t3, 2f
    addi    a0, a0, 2           // FAIL
2:

    // --- Test 3: BLT via LD, LD (two separate loads) ---
    la      t0, val_a
    ld      t2, 0(t0)           // t2 = 0x7FFFFFFFFFFFFFFE
    la      t0, val_b
    ld      t3, 0(t0)           // t3 = 0x7FFFFFFFFFFFFFFF
    blt     t2, t3, 3f
    addi    a0, a0, 4           // FAIL
3:

    // --- Test 4: BLT with addi forwarding (EX→ID bypass) ---
    la      t0, val_a
    ld      t2, 0(t0)           // t2 = 0x7FFFFFFFFFFFFFFE
    nop
    nop
    addi    t3, t2, 1           // t3 = 0x7FFFFFFFFFFFFFFF
    blt     t2, t3, 4f
    addi    a0, a0, 8           // FAIL
4:

    li      t0, 0x40000000
    sw      a0, 0(t0)
    1: j 1b

.section .data
.align 3
val_a:      .dword 0x7FFFFFFFFFFFFFFE
val_b:      .dword 0x7FFFFFFFFFFFFFFF
