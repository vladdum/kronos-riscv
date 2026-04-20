// test_muldiv_redirect.S — regression: both muldiv_req and muldiv_stall must
// be gated by ~ex_redirect and ~mem_redirect.
//
// Issue: when a BTB target misprediction (mem_redirect) fires while the first
// speculatively-fetched wrong-path instruction is a MUL in EX, two things
// must hold:
//
//   1. muldiv_req must not fire (prevents spurious FSM start).
//   2. muldiv_stall must not assert (prevents a deadlock where the pipeline
//      is frozen by the stall so the redirect flush can never fire).
//
// Without (1), muldiv_req fires for the wrong-path MUL, muldiv_stall kicks in
// immediately (MUL in EX, FSM not done), and the pipeline freezes for 3 cycles.
// After the FSM completes the stale computation, muldiv_stall deasserts and
// the redirect finally flushes the pipeline.  The stale result is discarded,
// so the wrong-path MUL result doesn't corrupt register state — but the 3-cycle
// ghost stall affects instruction timing, and in production code it interacts
// with forwarding and CSR state in ways that produce MCAUSE=2 traps.
//
// Without (2) but with (1): muldiv_req=0 keeps the FSM in IDLE, so
// muldiv_valid=0 forever → muldiv_stall=1 permanently → deadlock.  This test
// detects that case as a timeout.
//
// With both fixes: when mem_redirect fires, neither muldiv_req nor
// muldiv_stall asserts.  The redirect flush fires immediately (priority-3 path
// in kronos_hazard), the wrong-path MUL is discarded cleanly, and execution
// resumes at the correct target.
//
// How mem_redirect is triggered (Test 1):
//   Bimodal counter index = pc[7:2].  Counters start at 2'b01 (weak NT);
//   JAL/JALR never update them, so btb_hit alone is insufficient for
//   pred_taken.  bpred_warmup executes a taken conditional branch that aliases
//   the jalr_site bimodal entry, bumping counter[1] to 1.
//
//   Layout (precise PC control from main at 0x16):
//     2 + 8 + 8 + 2 + 2 + 2 + 2 = 26 bytes of setup → lands at 0x30.
//
//     bpred_warmup (0x30): beqz a0, jalr_site   [C.BEQZ, 2 bytes]
//       • a0=0 at this point → always taken → counter[12]: 2'b01 → 2'b10
//       • pc[7:2] = 0x30[7:2] = 12  ← shares bimodal + BTB entry with
//         jalr_site (0x32[7:2] = 12; both have pc[31:6] = 0 → same tag)
//
//     jalr_site (0x32): jr t1                   [4 bytes]
//       Pass 1 — t1=target_A, BTB miss → ex_redirect, BTB learns target_A.
//       Pass 2 — t1=target_B, BTB hit (target_A) + counter[12][1]=1 →
//                pred_taken=1 → predicts target_A → mem_redirect fires.
//                MUL at target_A is in EX when mem_redirect fires.
//
// Observable behaviour:
//   Incomplete fix (only muldiv_req gated): test hangs (deadlock timeout).
//   Full fix (both muldiv_req and muldiv_stall gated): x10=0 in ~240 cycles.
//
// a0 = 0 on success.

.section .text
.globl main

main:
    li      a0, 0               // failure counter; also used as 0 for warm-up branch

    // Setup for Test 1.  Total = 2+8+8+2+2+2+2 = 26 bytes → next instr at 0x30.
    la      t1, target_A        // t1 = target_A (pass 1 JALR target); 8 bytes
    la      s2, target_B        // s2 = target_B (stored for pass 2 handoff); 8 bytes
    li      t2, 7               // wrong-path MUL operands (target_A)
    li      t3, 6
    li      t5, 5               // correct-path MUL operands (target_B)
    li      t6, 8

    // -----------------------------------------------------------------------
    // Bimodal warm-up: beqz a0, jalr_site is at 0x30 (pc[7:2]=12).
    // a0=0 → always taken; updates counter[12]: 2'b01 → 2'b10.
    // jalr_site is at 0x32 (pc[7:2]=12) — same bimodal and BTB entry.
    // After pass 1, BTB[12]={tag:0, target:target_A}.  On pass 2:
    //   btb_hit=1 && counter[12][1]=1 → pred_taken=1 → mem_redirect.
    // -----------------------------------------------------------------------

bpred_warmup:                   // must be at 0x30
    beqz    a0, jalr_site       // C.BEQZ (2 bytes); a0=0 → taken; target=0x32

    // -----------------------------------------------------------------------
    // Test 1: MUL immediately at BTB target-misprediction redirect target.
    //
    // Wrong-path MUL  (target_A, pass 2): 7 * 6 (spurious if FSM fires)
    // Correct-path MUL (target_B, first instruction): 5 * 8 = 40
    // -----------------------------------------------------------------------

jalr_site:                      // must be at 0x32 (pc[7:2]=12)
    jalr    zero, t1, 0         // pass 1: t1=target_A; pass 2: t1=target_B

target_A:
    // Pass 2 wrong path: this MUL is in EX when mem_redirect fires.
    // Without fix, muldiv_req starts spurious 7*6=42 computation.
    mul     t4, t2, t3          // wrong-path MUL: 7 * 6 = 42
    // Pass 1 continuation: load target_B into t1 and loop back.
    mv      t1, s2              // t1 = target_B
    j       jalr_site           // pass 2: JALR fires mem_redirect

target_B:
    // First instruction at the correct redirect target.
    // Bug: captures stale DONE result (42) instead of computing 40.
    mul     s0, t5, t6          // must be 5 * 8 = 40

    li      t1, 40
    bne     s0, t1, test1_fail
    j       test1_pass
test1_fail:
    addi    a0, a0, 1
test1_pass:

    // -----------------------------------------------------------------------
    // Test 2: MULHU at JALR redirect target (ex_redirect path).
    //
    // Note: without a bimodal warm-up for jalr_site2, pred_taken=0 for the
    // JALR → only ex_redirect fires (direction misprediction on pass 1),
    // not mem_redirect.  The wrong-path MULHU fires AFTER the redirect
    // completes, so muldiv_req does not race with the flush.  This test
    // exercises the basic "JALR + MUL at target" sequencing without
    // specifically triggering the mem_redirect variant of the bug.
    //
    // Wrong-path MULHU: 0x100000000 * 0x100000000, high = 1
    // Correct-path MULHU (target_D first instruction): 3 * 3, high = 0
    // -----------------------------------------------------------------------

    la      s3, target_C
    la      s4, target_D

    li      t2, 1
    slli    t2, t2, 32          // t2 = 0x1_0000_0000
    li      t3, 1
    slli    t3, t3, 32          // t3 = 0x1_0000_0000

    li      t5, 3
    li      t6, 3

    mv      t1, s3

jalr_site2:
    jalr    zero, t1, 0

target_C:
    mulhu   t4, t2, t3          // wrong-path computation (ex_redirect path)
    mv      t1, s4
    j       jalr_site2

target_D:
    mulhu   s0, t5, t6          // 3 * 3 = 9, high 64 bits = 0

    bne     s0, zero, test2_fail
    j       test2_pass
test2_fail:
    addi    a0, a0, 1
test2_pass:

    // -----------------------------------------------------------------------
    // Test 3: MULW at JALR redirect target (ex_redirect path, same caveat).
    //
    // Wrong-path MULW:  (-3) * (-4) = 12 (sign-extended to 64)
    // Correct-path MULW: 9 * 4 = 36 (sign-extended to 64)
    // -----------------------------------------------------------------------

    la      s5, target_E
    la      s6, target_F

    li      t2, -3
    li      t3, -4

    li      t5, 9
    li      t6, 4

    mv      t1, s5

jalr_site3:
    jalr    zero, t1, 0

target_E:
    mulw    t4, t2, t3          // wrong-path: (-3)*(-4) = 12
    mv      t1, s6
    j       jalr_site3

target_F:
    mulw    s0, t5, t6          // must be 9 * 4 = 36

    li      t1, 36
    bne     s0, t1, test3_fail
    j       test3_pass
test3_fail:
    addi    a0, a0, 1
test3_pass:

    ret
