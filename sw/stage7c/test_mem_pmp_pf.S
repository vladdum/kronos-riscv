# test_mem_pmp_pf.S — MEM1/MEM2 split: PMP data fault and page-fault trapping.
#
# In stage 7c the PMP check moves from EX2 to MEM1.  Faults produced at MEM1
# ride mem1_mem2_q.fault and are delivered via the MEM2 redirect path with a
# 5-bubble flush (ID + RR + EX1 + EX2 + MEM1).
#
# This test exercises PMP data faults, which are the only fault type
# reachable from M-mode without setting up Sv39 translation.  Page faults
# require virtual memory (SATP != 0 in S/U mode) which needs OS scaffolding
# not available here; they are covered by the ACT4-s6-priv Sv suite.
#
# Sub-tests:
#   1. PMP store-access fault (mcause = 7): locked NAPOT region, W=0, M-mode
#      store → fault traps with correct mcause and mepc.
#   2. PMP load-access fault (mcause = 5): locked NAPOT region, R=0, M-mode
#      load → fault traps with correct mcause and mepc.
#   3. Fault delivers to handler after exactly the right number of NOPs:
#      mepc matches the instruction that triggered the fault (not +4, not -4).
#
# x10 == 0 on PASS; each failed sub-test ORs a unique bit into a0.

.equ CSR_MTVEC,   0x305
.equ CSR_MEPC,    0x341
.equ CSR_MCAUSE,  0x342
.equ CSR_MTVAL,   0x343
.equ CSR_PMPCFG0, 0x3A0
.equ CSR_PMPCFG1, 0x3A1
.equ CSR_PMPADDR0, 0x3B0
.equ CSR_PMPADDR1, 0x3B1

.macro READ_LAST_MCAUSE rd
    la      \rd, _last_mcause
    lw      \rd, 0(\rd)
.endm

.macro READ_LAST_MEPC rd
    la      \rd, _last_mepc
    ld      \rd, 0(\rd)
.endm

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # ---- Test 1: PMP store-access fault (mcause = 7) ---------------------
    # NAPOT region covering [0x12000, 0x12100): R=1, W=0, X=0, L=1.
    la      s0, _trap_taken
    sw      zero, 0(s0)
    li      t0, 0x481F                  # NAPOT: base=0x12000, size=256B
    csrw    CSR_PMPADDR0, t0
    li      t0, 0x99                    # L=1, A=NAPOT, X=0, W=0, R=1
    csrw    CSR_PMPCFG0, t0
    # Wait for CSR writes to drain through the pipeline before PMP check.
    nop; nop; nop; nop
    li      t1, 0x12000
.L_t1_store:
    sw      zero, 0(t1)                 # expect store-access fault (mcause=7)
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t1_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 7
    bne     t0, t1, .L_fail_t1_cause
    # Verify mepc points at the faulting store, not past it.
    READ_LAST_MEPC t0
    la      t1, .L_t1_store
    bne     t0, t1, .L_fail_t1_mepc

    # ---- Test 2: PMP load-access fault (mcause = 5) ----------------------
    # Region 1: [0x13000, 0x13100) with R=0, W=0, X=0, L=1.
    sw      zero, 0(s0)
    li      t0, 0x4C1F                  # NAPOT: base=0x13000, size=256B
    csrw    CSR_PMPADDR1, t0
    li      t0, (0x98 << 8) | 0x99     # cfg1: L=1,NAPOT,X=0,W=0,R=0; cfg0 unchanged
    csrw    CSR_PMPCFG0, t0
    nop; nop; nop; nop
    li      t1, 0x13000
.L_t2_load:
    lw      t2, 0(t1)                   # expect load-access fault (mcause=5)
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t2_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 5
    bne     t0, t1, .L_fail_t2_cause
    READ_LAST_MEPC t0
    la      t1, .L_t2_load
    bne     t0, t1, .L_fail_t2_mepc

    ret

.L_fail_t1_no_trap: ori a0, a0, 0x001; ret
.L_fail_t1_cause:   ori a0, a0, 0x002; ret
.L_fail_t1_mepc:    ori a0, a0, 0x004; ret
.L_fail_t2_no_trap: ori a0, a0, 0x008; ret
.L_fail_t2_cause:   ori a0, a0, 0x010; ret
.L_fail_t2_mepc:    ori a0, a0, 0x020; ret

# M-mode trap handler: save mcause/mepc, mark trap_taken, skip faulting instr.
.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE
    la      t1, _last_mcause
    sw      t0, 0(t1)
    csrr    t0, CSR_MEPC
    la      t1, _last_mepc
    sd      t0, 0(t1)
    la      t1, _trap_taken
    li      t2, 1
    sw      t2, 0(t1)
    # Advance mepc past the faulting instruction (assume 4-byte for simplicity).
    csrr    t1, CSR_MEPC
    addi    t1, t1, 4
    csrw    CSR_MEPC, t1
    mret

.section .data
.balign 8
_trap_taken:
    .word   0
_last_mcause:
    .word   0
.balign 8
_last_mepc:
    .dword  0
