// test_blt_act4.S — reproduces the ACT4 I-blt-00 test case 198 pattern:
// two 64-bit loads then BLT with near-maxint operands.
// a0 = 0 = pass.

.section .text
.globl main

main:
    li      t4, 0               // fail counter (x10 is used as rs2val)

    // ACT4 I-blt test case 198 pattern:
    //   ld x17, ...  → rs1 = 0x7FFFFFFFFFFFFFFE
    //   ld x10, ...  → rs2 = 0x7FFFFFFFFFFFFFFF
    //   blt x17, x10  (should be TAKEN: rs1 < rs2)
    la      x11, sigvals
    ld      x17, 0(x11)         // x17 = 0x7FFFFFFFFFFFFFFE
    addi    x11, x11, 8
    ld      x10, 0(x11)         // x10 = 0x7FFFFFFFFFFFFFFF

    // Test 1: BLT taken (x17 < x10)
    blt     x17, x10, 1f
    addi    t4, t4, 1           // FAIL: branch not taken
1:
    // Test 2: BLT not taken (x10 > x17, so x10 < x17 is false)
    blt     x10, x17, 2f        // x10 > x17 → NOT taken
    j       3f
2:
    addi    t4, t4, 2           // FAIL: branch should not have been taken
3:
    mv      a0, t4
    li      t0, 0x40000000
    sw      a0, 0(t0)
    1: j 1b

.section .data
.align 3
sigvals:
    .dword 0x7FFFFFFFFFFFFFFE
    .dword 0x7FFFFFFFFFFFFFFF
