// test_fence_i.S — Self-modifying-code smoke test for FENCE.I.
// Exercise: store an `addi x24, x24, 5` over an existing `addi x24, x24, 1`
// at `selfmodify_0`, then `fence.i`, then execute the slot.  If FENCE.I
// drains the D-cache and invalidates the I-cache, x24 ends up at 8 (init=3,
// new addi adds 5).  If the modified bytes never reach memory, the old
// addi runs and x24 ends up at 4.
//
// a0 = 0 = pass.

.section .text
.globl main

.option norvc                   // disable compressed in this region so the
                                // 4-byte sw cleanly overwrites a single 4-byte
                                // addi without touching the next instruction.
main:
    // Install a minimal trap handler that advances MEPC by 4 and MRETs —
    // mirrors what the ACT4 framework does for FENCE.I (decoded as
    // illegal-instruction).
    la      t0, trap_handler
    csrw    mtvec, t0

    li      x24, 3              // initial value
    li      t2, 8                // expected after self-modify

    // Write the new instruction (addi x24, x24, 5) over selfmodify_0.
    la      t0, selfmodify_0
    li      t1, 0x005C0C13      // addi x24, x24, 5
    sw      t1, 0(t0)

    fence.i                     // drain D$, invalidate I$ (traps to handler;
                                // handler MRETs to selfmodify_0)

selfmodify_0:
    addi    x24, x24, 1         // original — overwritten by the sw above (4 B)

    // Expected: x24 = 3 + 5 = 8 (not 4 = 3 + 1).
    bne     x24, t2, .Lfail

    li      a0, 0
    ret

.Lfail:
    li      a0, 1
    ret

.align 2
trap_handler:
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
