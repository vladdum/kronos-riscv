// test_blt_act4.S — reproduces the exact ACT4 I-blt-00 test case 198 pattern.
// Two 64-bit loads then BLT without extra NOPs.
// a0 = 0 = pass.

.section .text
.globl main

main:
    li      a0, 0

    // Exact pattern from ACT4 I-blt test case 198:
    //   ld x17, 0(x11)    → rs1 = 0x7FFFFFFFFFFFFFFE
    //   addi x11, x11, 8
    //   ld x10, 0(x11)    → rs2 = 0x7FFFFFFFFFFFFFFF
    //   addi x11, x11, 8
    //   blt x17, x10, target   (forward BLT, should be taken)
    //   blt x17, x10, back     (never-taken BLT, should NOT be taken)
    la      x11, sigvals
    ld      x17, 0(x11)         // x17 = 0x7FFFFFFFFFFFFFFE (rs1val)
    addi    x11, x11, 8
    ld      x10, 0(x11)         // x10 = 0x7FFFFFFFFFFFFFFF (rs2val)
    addi    x11, x11, 8
    blt     x17, x10, 1f        // forward BLT: should be TAKEN
    blt     x17, x10, back      // never-taken backward BLT
    // Taken path:
1:  blt     x17, x10, 2f        // backward BLT to 2f (below) - never taken
    j       3f                  // correct path after forward BLT taken
back:
    // We only reach here if forward BLT not taken
    addi    a0, a0, 1           // FAIL: forward BLT not taken
    j       3f
2:
    addi    a0, a0, 2           // FAIL: should not be taken
3:
    // Check that backward BLT (the first one) was NOT executed
    // Done - halt
    li      t0, 0x40000000
    sw      a0, 0(t0)
    1: j 1b

.section .data
.align 3
sigvals:
    .dword 0x7FFFFFFFFFFFFFFE   // rs1val (0(x11))
    .dword 0x7FFFFFFFFFFFFFFF   // rs2val (8(x11))
