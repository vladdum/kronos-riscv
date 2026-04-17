// test_blt64.S — diagnose BLT for 64-bit near-maxint operands.
// Each test is standalone with explicit forwarding patterns.
// a0 = 0 means all pass.

.section .text
.globl main

main:
    li      a0, 0               // fail counter

    // --- Test 1: BLT with immediate li (no forwarding hazard) ---
    // ra = 0x7FFFFFFFFFFFFFFE, sp = 0x7FFFFFFFFFFFFFFF
    // via: li t1, 1; slli t1, t1, 62; addi ra, t1, -2; addi sp, t1, -1
    li      t1, 1
    slli    t1, t1, 62          // t1 = 0x4000000000000000
    slli    t1, t1, 1           // t1 = 0x8000000000000000 (INT64_MIN)
    addi    t1, t1, -1          // t1 = 0x7FFFFFFFFFFFFFFF
    addi    ra, t1, -1          // ra = 0x7FFFFFFFFFFFFFFE
    mv      sp, t1              // sp = 0x7FFFFFFFFFFFFFFF
    // Now BLT with 3 NOPs to drain forwarding hazards
    nop
    nop
    nop
    blt     ra, sp, 1f
    addi    a0, a0, 1           // FAIL: ra < sp not taken
1:

    // --- Test 2: BLT via LD then addi (the actual ACT4 pattern) ---
    la      t0, val_a
    ld      ra, 0(t0)           // ra = 0x7FFFFFFFFFFFFFFE
    addi    sp, ra, 1           // sp = 0x7FFFFFFFFFFFFFFF (load-use: hazard then forward)
    blt     ra, sp, 2f
    addi    a0, a0, 1           // FAIL
2:

    // --- Test 3: BLT via LD, LD (two separate loads) ---
    la      t0, val_a
    ld      ra, 0(t0)           // ra = 0x7FFFFFFFFFFFFFFE
    la      t0, val_b
    ld      sp, 0(t0)           // sp = 0x7FFFFFFFFFFFFFFF
    blt     ra, sp, 3f
    addi    a0, a0, 1           // FAIL
3:

    // --- Test 4: BLT with addi forwarding (EX→ID bypass) ---
    la      t0, val_a
    ld      ra, 0(t0)           // ra = 0x7FFFFFFFFFFFFFFE
    nop
    nop
    addi    sp, ra, 1           // sp = 0x7FFFFFFFFFFFFFFF (no hazard, ra in regfile)
    blt     ra, sp, 4f
    addi    a0, a0, 1           // FAIL
4:

    // --- Test 5: Check values via store (debug what ra, sp actually are) ---
    // Store ra to result_ra, sp to result_sp, then compare stored values
    la      t0, val_a
    ld      ra, 0(t0)
    addi    sp, ra, 1
    la      t0, result_ra
    sd      ra, 0(t0)
    la      t0, result_sp
    sd      sp, 0(t0)
    // Now reload and compare
    la      t0, result_ra
    ld      x3, 0(t0)
    la      t0, result_sp
    ld      x4, 0(t0)
    la      t0, val_a
    ld      x5, 0(t0)           // expected ra
    la      t0, val_b
    ld      x6, 0(t0)           // expected sp
    bne     x3, x5, 51f         // ra mismatch
    bne     x4, x6, 52f         // sp mismatch
    j       53f
51: addi    a0, a0, 2           // ra was wrong
    j       53f
52: addi    a0, a0, 4           // sp was wrong
53:

    ret

.section .data
.align 3
val_a:      .dword 0x7FFFFFFFFFFFFFFE
val_b:      .dword 0x7FFFFFFFFFFFFFFF
result_ra:  .dword 0
result_sp:  .dword 0
