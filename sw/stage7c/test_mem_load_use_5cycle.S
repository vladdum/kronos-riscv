# test_mem_load_use_5cycle.S — load-use bypass correctness with 5 ID bubbles.
#
# The hazard unit detects a load in {RR, EX1, EX2, MEM1, MEM1B, MEM2} —
# six producer slots — and FWD_MEMWB (mem_wb_q.alu_result, registered) is
# the only load-value forwarding path.  A load consumed in ID stalls for
# 5 cycles before FWD_MEMWB delivers the value at the next RR.  This is
# +1 bubble vs 7d-closeout (4) and +2 bubbles vs 7c (3).
#
# This test verifies result correctness for back-to-back ld/use patterns —
# the self-check confirms bypass delivers the right value rather than a
# stale register value (cycle counts are not asserted in-program; they
# are gated upstream by the hazard testbench and the cycle-diff CI job).
#
# Sub-tests:
#   1. Single ld immediately consumed by addi      — FWD_MEMWB path
#   2. ld followed by two ld-dependent addi chain  — consecutive stalls
#   3. ld of a negative value, use in arithmetic   — sign extension check
#   4. Double-word ld consumed by add (two-operand) — FWD_MEMWB on rs2
#
# x10 == 0 on PASS; increments by 1 per failed sub-test.

.equ CSR_MSTATUS, 0x300

.section .text
.global main
main:
    li      a0, 0                       # running failure count

    # ---- Test 1: ld immediately consumed by addi -- FWD_MEMWB ------------
    la      t0, _test_data
    li      t1, 0x12345678
    sd      t1, 0(t0)
    ld      t2, 0(t0)                   # load 0x12345678 → t2
    addi    t3, t2, 1                   # consume immediately (load-use stall)
    li      t4, 0x12345679
    bne     t3, t4, .L_fail_t1

    # ---- Test 2: back-to-back ld; addi; addi chain -----------------------
    li      t1, 0x100
    sd      t1, 0(t0)
    ld      t2, 0(t0)                   # t2 = 0x100
    addi    t3, t2, 0x10               # t3 = 0x110  (load-use stall)
    addi    t4, t3, 0x10               # t4 = 0x120
    li      t5, 0x120
    bne     t4, t5, .L_fail_t2

    # ---- Test 3: ld negative value, use in arithmetic --------------------
    li      t1, -1
    sd      t1, 0(t0)
    ld      t2, 0(t0)                   # t2 = -1 (sign-extended 0xFFFF...FFFF)
    addi    t3, t2, 1                   # t3 = 0
    bnez    t3, .L_fail_t3

    # ---- Test 4: ld consumed on rs2 of add -- FWD_MEMWB on rs2 ------------
    li      t1, 0xABCD
    sd      t1, 0(t0)
    ld      t2, 0(t0)                   # t2 = 0xABCD
    li      t3, 0x1000
    add     t4, t3, t2                  # consume on rs2 (load-use stall)
    li      t5, 0xBBCD
    bne     t4, t5, .L_fail_t4

    ret

.L_fail_t1: addi a0, a0, 1; ret
.L_fail_t2: addi a0, a0, 1; ret
.L_fail_t3: addi a0, a0, 1; ret
.L_fail_t4: addi a0, a0, 1; ret

.section .data
.balign 8
_test_data:
    .dword  0
