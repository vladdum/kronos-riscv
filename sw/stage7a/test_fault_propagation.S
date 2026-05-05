# test_fault_propagation.S — Stage 7a: fault_t bit-by-bit propagation test.
#
# Stage 7a moves trap delivery off the EX comb path: every fault bit is
# captured into id_ex1_q.fault, walked through ex1_ex2_q.fault and
# ex2_mem_q.fault, and finally fired at WB.  This test exercises one
# fault_t bit per sub-test, confirming the trap fires with the right
# mcause/mepc and that a follow-up instruction continues correctly.
#
# Sub-tests:
#   1. ecall                 (mcause = 11, M-mode ecall)
#   2. ebreak                (mcause = 3,  breakpoint)
#   3. illegal               (mcause = 2,  .word 0xFFFFFFFF)
#   4. csr_illegal           (mcause = 2,  U-mode csrr of M-mode CSR)
#   5. mret_priv_fail        (mcause = 2,  mret from U-mode)
#   6. pmp_data_fault        (mcause = 7,  store to locked PMP region)
#   7. pmp_fetch_fault       (mcause = 1,  fetch into locked-no-X PMP region)
#   8. ex_amo_nc_fault       (mcause = 7,  amoswap.w to MMIO non-cacheable)
#
# Each sub-test bumps a unique bit of x10 on failure; on success x10 = 0.
#
# Skipped (not exercisable in M-mode without MMU on stage 7a):
#   * instr_page_fault, load_page_fault, store_page_fault — Sv39/Sv48 only.
#   * satp_tvm_fail — needs S-mode + mstatus.TVM (orthogonal to fault pipe;
#     covered in Stage 6 test_sret + test_priv_smode).
#   * trig_hit, bpred_dir_mispredict, bpred_target_mispredict — internal
#     events not directly user-visible.
#   * sret_priv_fail, wfi_priv_fail, dcache_bus_err_fault — orthogonal to
#     EX1/EX2 split mechanics; same fault-bit machinery as the bits above.
#   * irq_pending — the sim_main.cpp IRQ trigger at 0x80000000 needs an
#     AXI AW to fire, but the address sits in cacheable memory in this
#     core (MMIO_BASE=0x40000000) and the dcache buffers the store before
#     it reaches the AXI master.  ACT4-s5/-s6 interrupt suites exercise
#     this fault bit through the OBI-backed arch-test harness instead.

.equ CSR_MSTATUS,   0x300
.equ CSR_MEPC,      0x341
.equ CSR_MTVEC,     0x305
.equ CSR_MCAUSE,    0x342
.equ CSR_MTVAL,     0x343
.equ CSR_MIE,       0x304
.equ CSR_PMPCFG0,   0x3A0
.equ CSR_PMPADDR0,  0x3B0
.equ CSR_PMPADDR1,  0x3B1

# Helper: load _last_mcause into Rd via two-instruction pair.
.macro READ_LAST_MCAUSE rd
    la      \rd, _last_mcause
    lw      \rd, 0(\rd)
.endm

.section .text
.global main
main:
    li      a0, 0                       # x10 — running failure count
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # ---- Test 1: ecall ----------------------------------------------------
    la      s0, _trap_taken
    sw      zero, 0(s0)
    ecall                               # expect mcause = 11 (M ecall)
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t1_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 11
    bne     t0, t1, .L_fail_t1_cause

    # ---- Test 2: ebreak ---------------------------------------------------
    sw      zero, 0(s0)
    ebreak                              # expect mcause = 3
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t2_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 3
    bne     t0, t1, .L_fail_t2_cause

    # ---- Test 3: illegal --------------------------------------------------
    sw      zero, 0(s0)
    .word   0xFFFFFFFF                  # expect mcause = 2 (illegal)
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t3_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 2
    bne     t0, t1, .L_fail_t3_cause

    # ---- Test 4: csr_illegal ---------------------------------------------
    # U-mode read of an M-mode CSR (mstatus, addr 0x300) is privilege-illegal.
    # Drop to U via mret with MPP=U and try to csrr mstatus — csr_illegal_o
    # asserts in u_csr (priv_check_fail) and rides id_ex1_q.fault.csr_illegal.
    sw      zero, 0(s0)
    # Arm the M-handler to bump priv back to M and resume at .L_t4_after_handler.
    la      t0, .L_t4_after_handler
    la      t1, _resume_pc
    sw      t0, 0(t1)
    li      t0, 0                       # MPP = U
    csrw    CSR_MSTATUS, t0
    la      t0, .L_t4_u
    csrw    CSR_MEPC, t0
    mret
.L_t4_u:
    csrr    t1, CSR_MSTATUS             # U-mode read of M-mode CSR — illegal
.L_t4_after_handler:
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t4_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 2
    bne     t0, t1, .L_fail_t4_cause

    # ---- Test 5: mret_priv_fail ------------------------------------------
    # MRET from U-mode is privileged-illegal: mcause = 2.
    sw      zero, 0(s0)
    la      t0, .L_t5_after_handler
    la      t1, _resume_pc
    sw      t0, 0(t1)
    li      t0, 0                       # MPP = U
    csrw    CSR_MSTATUS, t0
    la      t0, .L_t5_u
    csrw    CSR_MEPC, t0
    mret
.L_t5_u:
    mret                                # expect illegal trap from U-mode
.L_t5_after_handler:
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t5_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 2
    bne     t0, t1, .L_fail_t5_cause

    # ---- Test 6: pmp_data_fault ------------------------------------------
    # Locked NAPOT region [0x12000..0x12100), R=1/W=0/X=0, L=1.  M-mode
    # store to 0x12000 must trap with mcause = 7 (store-access fault).
    sw      zero, 0(s0)
    li      t0, 0x481F                  # NAPOT: base 0x12000, size 256B
    csrw    CSR_PMPADDR0, t0
    li      t0, 0x99                    # cfg: L=1, A=NAPOT, X=0, W=0, R=1
    csrw    CSR_PMPCFG0, t0
    # Stage 7a: CSR writes commit at retire (3 stages downstream of EX1).
    # Pad with NOPs so the csrw drains before the SW's EX1 PMP check.
    # Stage 6 didn't need this because csrw committed at EX1.
    nop
    nop
    nop
    nop
    li      t1, 0x12000
    sw      zero, 0(t1)                 # expect store-access fault
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t6_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 7
    bne     t0, t1, .L_fail_t6_cause

    # ---- Test 7: pmp_fetch_fault -----------------------------------------
    # Locked region 1 covers [0x13000..0x13100) with R=W=X=0.  jalr into
    # that region must trap with mcause = 1 (instr-access fault).  The
    # handler advances mepc by 4 — but since the trapping insn is the
    # jalr (not the target), mepc is the jalr PC; +4 lands after the jalr.
    sw      zero, 0(s0)
    # Region 1: NAPOT [0x13000..0x13100), R=W=X=0, L=1.
    li      t0, 0x4C1F
    csrw    CSR_PMPADDR1, t0
    # pmpcfg0 high byte = region 1 cfg (0x98), low byte = region 0 cfg (0x99).
    li      t0, (0x98 << 8) | 0x99
    csrw    CSR_PMPCFG0, t0
    nop
    nop
    nop
    nop
    # Arm handler resume PC: on fetch-fault (cause=1) the handler routes
    # to _resume_pc rather than mepc+4 (mepc is inside the locked region).
    la      t0, .L_t7_after_handler
    la      t1, _resume_pc
    sw      t0, 0(t1)
    li      t0, 0x13000
    jalr    zero, 0(t0)                 # fetch from 0x13000 → access fault
.L_t7_after_handler:
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t7_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 1
    bne     t0, t1, .L_fail_t7_cause

    # ---- Test 8: ex_amo_nc_fault -----------------------------------------
    # AMO to non-cacheable MMIO (0x40000000) must trap with mcause = 7.
    sw      zero, 0(s0)
    li      t0, 0x40000000
    li      t1, 0x55555555
    amoswap.w t2, t1, (t0)              # AMO on NC — expect access fault
    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_t8_no_trap
    READ_LAST_MCAUSE t0
    li      t1, 7
    bne     t0, t1, .L_fail_t8_cause

    # ---- Test 9 (irq_pending) intentionally omitted ----------------------
    # The timer-IRQ trigger at 0x80000000 in sim_main.cpp asserts
    # irq_timer_i on receipt of an AXI AW (write).  In the kronos dcache
    # path, 0x80000000 is in the cacheable region (MMIO_BASE=0x40000000,
    # so 0x80000000 sits in normal cached memory) — a sw to that address
    # is buffered into the dcache and never issues the AW that the sim
    # consumes.  CRV's assist_traps.S documents the same limitation.
    # The fault_t.irq_pending bit is exercised by every ACT4-s5/-s6
    # interrupt-suite test (which runs in tb_arch_test.sv with an OBI
    # backend that supports the trigger correctly), so coverage exists.

    # All sub-tests passed.
    ret

# --- failure tags -----------------------------------------------------------
# `ori` is limited to a 12-bit signed immediate, so wider tags use `li` of a
# scratch register followed by `or`.  Each failure path leaves a unique bit
# set in a0 and then returns to main, which will return to common.S _halt.
.L_fail_t1_no_trap: ori a0, a0, 0x001; ret
.L_fail_t1_cause:   ori a0, a0, 0x002; ret
.L_fail_t2_no_trap: ori a0, a0, 0x004; ret
.L_fail_t2_cause:   ori a0, a0, 0x008; ret
.L_fail_t3_no_trap: ori a0, a0, 0x010; ret
.L_fail_t3_cause:   ori a0, a0, 0x020; ret
.L_fail_t4_no_trap: ori a0, a0, 0x040; ret
.L_fail_t4_cause:   ori a0, a0, 0x080; ret
.L_fail_t5_no_trap: ori a0, a0, 0x100; ret
.L_fail_t5_cause:   ori a0, a0, 0x200; ret
.L_fail_t6_no_trap: ori a0, a0, 0x400; ret
.L_fail_t6_cause:   li t6, 0x800;   or a0, a0, t6; ret
.L_fail_t7_no_trap: li t6, 0x1000;  or a0, a0, t6; ret
.L_fail_t7_cause:   li t6, 0x2000;  or a0, a0, t6; ret
.L_fail_t8_no_trap: li t6, 0x4000;  or a0, a0, t6; ret
.L_fail_t8_cause:   li t6, 0x8000;  or a0, a0, t6; ret

# ---------------------------------------------------------------------------
# M-mode trap handler — saves mcause, marks trap_taken, advances mepc by 4
# (default).  Special-cases:
#   * MRET-from-U (test 5):  bump MPP=M, route mepc to .L_t5_after_handler.
#   * IRQ (mcause MSB=1):    save low cause bits, disable MIE/MTIE, resume.
# ---------------------------------------------------------------------------
.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE

    # IRQ path: high bit of XLEN-wide mcause set.  Use bltz because t0 is
    # XLEN-wide and a negative interpretation = MSB set.
    bltz    t0, _mhandler_irq_path

    # Save synchronous cause.
    la      t1, _last_mcause
    sw      t0, 0(t1)
    la      t1, _trap_taken
    li      t2, 1
    sw      t2, 0(t1)

    # Fetch-fault path (cause=1): mepc points to the unfetchable PC
    # (could be inside a locked PMP region — unreadable too).  Don't try
    # to read it; route via _resume_pc supplied by main.
    li      t1, 1
    beq     t0, t1, _mhandler_resume_pc

    # mcause==2 trap from U-mode: tests 4 (U-CSR-read) and 5 (U-MRET).
    # Bump priv back to M and route mepc to whatever main armed in
    # _resume_pc.
    li      t1, 2
    bne     t0, t1, _mhandler_skip4
    csrr    t1, CSR_MSTATUS
    srli    t2, t1, 11                  # MPP[12:11]
    andi    t2, t2, 0x3
    bnez    t2, _mhandler_skip4         # MPP != U → ordinary skip-4
    # MPP == U: bump back to M and route to _resume_pc.
_mhandler_resume_pc:
    li      t2, 0x1800                  # MPP = M (restore for fetch-fault path too)
    csrs    CSR_MSTATUS, t2
    la      t2, _resume_pc
    ld      t2, 0(t2)
    csrw    CSR_MEPC, t2
    mret

_mhandler_skip4:
    # Advance mepc past the offending instruction.  Reading the half-word
    # at mepc to detect compressed encoding only works when the page at
    # mepc is readable.  For pmp_fetch_fault (test 7) mepc points to the
    # jalr's PC (where the offending fetch was attempted from) — *not* the
    # locked region — so the read is fine.  But to keep this robust we
    # read mtval first: if it equals mepc and the trap was a fetch fault
    # (cause=1), the offending PC is the jalr itself, but the *target*
    # was 0x13000.  In all our skip cases the read at mepc lands inside
    # the test's text, which is in non-PMP-protected ROM, so always safe.
    csrr    t1, CSR_MEPC
    lh      t2, 0(t1)
    andi    t2, t2, 0x3
    li      t3, 0x3
    bne     t2, t3, .L_skip2
    addi    t1, t1, 4
    j       .L_skip_done
.L_skip2:
    addi    t1, t1, 2
.L_skip_done:
    csrw    CSR_MEPC, t1
    mret

_mhandler_irq_path:
    # Defensive: disable MIE so a stray IRQ from a prior test cannot loop
    # the handler on top of the synchronous-trap test stream.
    li      t1, (1 << 3)
    csrc    CSR_MSTATUS, t1
    li      t1, (1 << 7)
    csrc    CSR_MIE, t1
    mret

.section .data
.balign 8
_trap_taken:
    .word   0
_last_mcause:
    .word   0
.balign 8
_resume_pc:
    .dword  0
