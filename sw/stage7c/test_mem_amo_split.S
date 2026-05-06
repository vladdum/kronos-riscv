# test_mem_amo_split.S — MEM1/MEM2 split: AMO RMW correctness.
#
# In stage 7c the AMO operand-launch advances from ex2_mem_q (7b) to
# mem1_mem2_q (MEM1→MEM2 boundary).  The dcache DC_AMO_RMW FSM is unchanged;
# only the source register for the LSU req_i shifts one stage later.
# AMO completion latency increases by 1 cycle; the architectural result is
# unchanged.
#
# Sub-tests:
#   1. LR.D / SC.D round-trip: reservation holds, SC succeeds (x9 == 0),
#      memory contains the new value.
#   2. AMOADD.D: rd gets the old memory value; memory holds old + operand.
#   3. AMOSWAP.D: rd gets the old value; memory holds the new value.
#   4. LR.D / SC.D with interleaved nop (reservation must still hold on a
#      single hart — spec guarantees forward progress).
#
# x10 == 0 on PASS; addi a0, a0, 1 per failed sub-test.

.section .text
.global main
main:
    li      a0, 0

    # ---- Test 1: LR.D / SC.D round-trip -----------------------------------
    la      t0, _lock_word
    li      t1, 0x42
    sd      t1, 0(t0)

    lr.d    t2, (t0)                    # t2 = 0x42, reservation set
    li      t3, 0x11
    bne     t2, t1, .L_fail_t1_lr      # lr.d must return the stored value

    li      t3, 0x99
    sc.d    t4, t3, (t0)               # t4 = 0 on success
    bnez    t4, .L_fail_t1_sc

    ld      t5, 0(t0)
    bne     t5, t3, .L_fail_t1_mem     # memory must hold 0x99

    # ---- Test 2: AMOADD.D -------------------------------------------------
    li      t1, 0x10
    sd      t1, 0(t0)
    li      t2, 0x20
    amoadd.d t3, t2, (t0)             # t3 = old (0x10), mem ← 0x30
    bne     t3, t1, .L_fail_t2_rd

    ld      t4, 0(t0)
    li      t5, 0x30
    bne     t4, t5, .L_fail_t2_mem

    # ---- Test 3: AMOSWAP.D ------------------------------------------------
    li      t1, 0xAA
    sd      t1, 0(t0)
    li      t2, 0xBB
    amoswap.d t3, t2, (t0)            # t3 = 0xAA, mem ← 0xBB
    bne     t3, t1, .L_fail_t3_rd

    ld      t4, 0(t0)
    bne     t4, t2, .L_fail_t3_mem

    # ---- Test 4: LR.D / SC.D with nop between ----------------------------
    li      t1, 0x55
    sd      t1, 0(t0)
    lr.d    t2, (t0)
    bne     t2, t1, .L_fail_t4_lr
    nop
    nop
    li      t3, 0x66
    sc.d    t4, t3, (t0)
    bnez    t4, .L_fail_t4_sc

    ld      t5, 0(t0)
    bne     t5, t3, .L_fail_t4_mem

    ret

.L_fail_t1_lr:  addi a0, a0, 1; ret
.L_fail_t1_sc:  addi a0, a0, 1; ret
.L_fail_t1_mem: addi a0, a0, 1; ret
.L_fail_t2_rd:  addi a0, a0, 1; ret
.L_fail_t2_mem: addi a0, a0, 1; ret
.L_fail_t3_rd:  addi a0, a0, 1; ret
.L_fail_t3_mem: addi a0, a0, 1; ret
.L_fail_t4_lr:  addi a0, a0, 1; ret
.L_fail_t4_sc:  addi a0, a0, 1; ret
.L_fail_t4_mem: addi a0, a0, 1; ret

.section .data
.balign 8
_lock_word:
    .dword  0
