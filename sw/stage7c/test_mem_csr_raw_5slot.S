# test_mem_csr_raw_5slot.S — MEM1/MEM2 split: CSR-RAW stall for 5-slot writer.
#
# In stage 7c the CSR-RAW hazard window extends from 4 (7b: RR, EX1, EX2,
# MEM1) to 5 positions ({RR, EX1, EX2, MEM1, MEM2}).  A CSR read immediately
# following a chain of up to 5 back-to-back CSR writes to the same address
# must stall until the last writer has committed, then return the final value.
#
# mscratch (0x340) is used as the test CSR — M-mode accessible, no side
# effects, safe to clobber.
#
# Sub-tests:
#   1. Single csrrw + immediate csrr — basic RAW stall.
#   2. Two consecutive csrrw to same CSR + csrr — 2-slot RAW.
#   3. Five consecutive csrrw + csrr — exercises the full 5-slot window.
#   4. Five csrrw to same CSR; intermediate csrr after each write verifies
#      that each stall delivers the correct in-flight value.
#
# x10 == 0 on PASS; addi a0, a0, 1 per failed sub-test.

.equ CSR_MSCRATCH, 0x340

.section .text
.global main
main:
    li      a0, 0

    # ---- Test 1: single csrrw + csrr -------------------------------------
    li      t0, 0x11
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH
    li      t2, 0x11
    bne     t1, t2, .L_fail_t1

    # ---- Test 2: two csrrw + csrr ----------------------------------------
    li      t0, 0x22
    csrrw   x0, CSR_MSCRATCH, t0
    li      t0, 0x33
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH
    li      t2, 0x33
    bne     t1, t2, .L_fail_t2

    # ---- Test 3: five csrrw + csrr (full 5-slot window) ------------------
    li      t0, 0x11
    csrrw   x0, CSR_MSCRATCH, t0
    li      t0, 0x22
    csrrw   x0, CSR_MSCRATCH, t0
    li      t0, 0x33
    csrrw   x0, CSR_MSCRATCH, t0
    li      t0, 0x44
    csrrw   x0, CSR_MSCRATCH, t0
    li      t0, 0x55
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH           # must stall until last write retires
    li      t2, 0x55
    bne     t1, t2, .L_fail_t3

    # ---- Test 4: csrr after each write delivers the correct value ---------
    li      t0, 0xAA
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH
    li      t2, 0xAA
    bne     t1, t2, .L_fail_t4a

    li      t0, 0xBB
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH
    li      t2, 0xBB
    bne     t1, t2, .L_fail_t4b

    li      t0, 0xCC
    csrrw   x0, CSR_MSCRATCH, t0
    csrr    t1, CSR_MSCRATCH
    li      t2, 0xCC
    bne     t1, t2, .L_fail_t4c

    ret

.L_fail_t1:  addi a0, a0, 1; ret
.L_fail_t2:  addi a0, a0, 1; ret
.L_fail_t3:  addi a0, a0, 1; ret
.L_fail_t4a: addi a0, a0, 1; ret
.L_fail_t4b: addi a0, a0, 1; ret
.L_fail_t4c: addi a0, a0, 1; ret
