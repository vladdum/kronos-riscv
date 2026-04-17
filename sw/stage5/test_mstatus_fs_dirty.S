// mstatus.FS advances to Dirty (11) after an FP writeback.
// a0 accumulates failure count.

.section .text
.globl main

main:
    li      a0, 0

    // Reset FS to Initial (01) via mstatus write.
    li      t0, 0x6000              // FS mask in bits [14:13]
    csrrc   x0, mstatus, t0         // clear bits 14:13
    li      t0, 0x2000              // FS=01
    csrrs   x0, mstatus, t0         // set FS=01

    // Confirm FS is now 01.
    csrr    t0, mstatus
    srli    t0, t0, 13
    andi    t0, t0, 3
    li      t1, 1
    beq     t0, t1, 1f
    addi    a0, a0, 1
1:

    // Issue an FP writeback (FADD.D of two zero doubles).
    fmv.d.x ft0, x0
    fmv.d.x ft1, x0
    fadd.d  ft2, ft0, ft1

    // FS must now be 11 (Dirty).
    csrr    t0, mstatus
    srli    t0, t0, 13
    andi    t0, t0, 3
    li      t1, 3
    beq     t0, t1, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: SW write to fflags must also transition FS to Dirty.
    // Reset FS to Initial first.
    // ------------------------------------------------------------------
    li      t0, 0x6000              // FS=11 mask
    csrrc   x0, mstatus, t0         // clear bits 14:13
    li      t0, 0x2000              // FS=01
    csrrs   x0, mstatus, t0         // set FS=01

    // Confirm FS=01.
    csrr    t0, mstatus
    srli    t0, t0, 13
    andi    t0, t0, 3
    li      t1, 1
    beq     t0, t1, 3f
    addi    a0, a0, 1
3:

    // SW write to fflags (no FP arithmetic).
    csrwi   fflags, 0x1f            // write all-1s into fflags

    // FS must now be 11 (Dirty).
    csrr    t0, mstatus
    srli    t0, t0, 13
    andi    t0, t0, 3
    li      t1, 3
    beq     t0, t1, 4f
    addi    a0, a0, 1
4:

    // Repeat for frm.
    li      t0, 0x6000
    csrrc   x0, mstatus, t0
    li      t0, 0x2000
    csrrs   x0, mstatus, t0
    csrwi   frm, 0                  // SW write to frm
    csrr    t0, mstatus
    srli    t0, t0, 13
    andi    t0, t0, 3
    li      t1, 3
    beq     t0, t1, 5f
    addi    a0, a0, 1
5:

    ret
