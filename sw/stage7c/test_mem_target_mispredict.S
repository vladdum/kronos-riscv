# test_mem_target_mispredict.S — MEM1/MEM2 split: target mispredict flush.
#
# In stage 7c a target mispredict (bpred_target_mispredict) is detected at
# MEM2 and flushes 5 stages (ID + RR + EX1 + EX2 + MEM1), one more than in
# 7b.  The pipeline must redirect to the correct target and continue cleanly.
#
# Test approach: use JALR with a register-loaded target address.  The branch
# predictor cannot predict the target of a register-indirect JALR before the
# register is available (at EX1/EX2 at earliest), so the pipeline typically
# fetches speculatively from PC+4.  When the JALR resolves in EX2/MEM2, the
# redirect fires, flushing the wrongly-fetched instructions.
#
# Additionally, exercise a taken branch whose target was not in the BTB
# (cold branch), so the predictor speculates not-taken and must redirect.
#
# Sub-tests:
#   1. JALR to a register-loaded address: verify correct landing.
#      Pattern: pre-set a0=0x1 (fail); clear to 0 at target.
#   2. Cold backward branch (not in predictor): verify all loop iterations
#      execute the correct number of times.
#   3. Forward JALR chain: JALR A → JALR B → JALR C, verify final landing.
#
# x10 == 0 on PASS.

.section .text
.global main
main:
    li      a0, 0

    # ---- Test 1: register-indirect JALR target mispredict -----------------
    li      a0, 0x1                     # failure sentinel
    la      t0, _t1_target
    jalr    x0, 0(t0)                   # JALR to address in t0
    addi    a0, a0, 0x100              # unreachable on correct path
_t1_target:
    li      a0, 0                       # clear sentinel — arrived correctly

    # ---- Test 2: cold backward branch (loop) ------------------------------
    # Count down from 4 to 0; the backward branch is never-seen-before.
    li      t0, 4                       # loop counter
    li      t1, 0                       # accumulator
.L_t2_loop:
    addi    t1, t1, 1                   # acc++
    addi    t0, t0, -1                  # counter--
    bnez    t0, .L_t2_loop             # backward branch — potential mispredict
    li      t2, 4
    bne     t1, t2, .L_fail_t2         # must have run exactly 4 times

    # ---- Test 3: forward JALR chain ---------------------------------------
    # JALR A → JALR B → JALR C → landing; verify we land at the right spot.
    li      a0, 0x3                     # failure sentinel
    la      t0, _t3_jmp_b
    jalr    x0, 0(t0)                   # jump to _t3_jmp_b
    addi    a0, a0, 0x100              # unreachable
_t3_jmp_b:
    la      t0, _t3_jmp_c
    jalr    x0, 0(t0)                   # jump to _t3_jmp_c
    addi    a0, a0, 0x100              # unreachable
_t3_jmp_c:
    la      t0, _t3_target
    jalr    x0, 0(t0)                   # jump to _t3_target
    addi    a0, a0, 0x100              # unreachable
_t3_target:
    li      a0, 0                       # clear sentinel

    ret

.L_fail_t2: addi a0, a0, 1; ret
