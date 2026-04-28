# test_page_fault.S — Stage 6b: deliberate page faults from S/U-mode.
#
# Two subtests, both expected to trap into M-mode:
#
#  1. Instruction-page-fault (cause 12).  Setup: identity-map [0, 2 GB)
#     with U=1 leaves.  Per the privileged spec, S-mode CANNOT fetch
#     from a U=1 page (regardless of SUM).  M hands off to S; S's first
#     fetch raises CAUSE_INSTR_PAGE_FAULT.
#
#  2. Load-page-fault (cause 13).  After resuming, M drops to U-mode and
#     issues `lw t0, 0(0xDEAD0000)` — a virtual address with no PTE in
#     the root table (root[entry] all zero -> invalid).  Sv39 walk
#     terminates at level 2 with V=0, raising CAUSE_LOAD_PAGE_FAULT.
#     This subtest exercises the EX→MEM dtlb-miss / page-fault stall
#     fix: without it, the U-mode load would silently complete with the
#     stale-PA captured before the PTW page-fault fired.
#
# Pass: x10 = 0.

.equ CSR_MSTATUS, 0x300
.equ CSR_MTVEC,   0x305
.equ CSR_MEPC,    0x341
.equ CSR_MCAUSE,  0x342
.equ CSR_MTVAL,   0x343
.equ CSR_SATP,    0x180

# Leaf flags U=1: V=1 R=1 W=1 X=1 U=1 A=1 D=1 -> 0xDF.
.equ LEAF_U, 0xDF

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    la      a1, _root_table

    # Clear root table (all PTEs invalid by default).
    mv      t0, a1
    li      t1, 0
    li      t2, 512
.L_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .L_clear

    # Identity-map [0, 2 GB) with U=1 leaves so S/U can fetch + load
    # within the mapped range.  PTEs above leave invalid so a VA in
    # 0xDEAD0000 (out of mapped range) page-faults on lookup.
    li      t0, LEAF_U
    sd      t0, 0(a1)                   # root[0]: PA 0..1G
    li      t0, LEAF_U
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)                   # root[1]: PA 1G..2G

    # Enable Sv39 ASID=4.
    srli    t0, a1, 12
    li      t1, 4
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # ---- Subtest 1: S-mode fetch from U=1 page -> instr page-fault.
    # Set MPP=S (01) so mret returns to S-mode.
    li      t0, 0x1800
    csrc    CSR_MSTATUS, t0
    li      t0, 0x0800
    csrs    CSR_MSTATUS, t0
    la      t0, .L_smode_entry
    csrw    CSR_MEPC, t0
    li      a0, 1                       # tentative fail
    li      a2, 1                       # subtest 1 marker
    mret

.L_smode_entry:
    # Should fault before this nop ever retires.  If we reach here, the
    # fault path is broken.
    nop
    nop
    j       .L_done

.L_after_subtest_1:
    # Subtest 1 passed (fall-through from the M handler via mret to
    # here).  Now run subtest 2: U-mode load to an unmapped VA.
    li      a0, 1                       # tentative fail (cleared on cause=13)
    li      a2, 2                       # subtest 2 marker

    # MPP=U (00) so mret returns to U-mode.
    li      t0, 0x1800
    csrc    CSR_MSTATUS, t0
    la      t0, .L_umode_load
    csrw    CSR_MEPC, t0
    mret

.L_umode_load:
    # Issue a translated load to an unmapped VA.  The dTLB will miss,
    # the PTW will walk and find an invalid PTE, raising a
    # load-page-fault (cause 13) through the same stall machinery that
    # holds the EX→MEM advance until the fault fires.
    li      t0, 0xDEAD0000
    lw      t1, 0(t0)
    # Should not reach here.
    j       .L_done

.L_done:
    ret

.balign 4
_mhandler:
    csrr    t1, CSR_MCAUSE
    # Subtest dispatch on a2.
    li      t2, 1
    beq     a2, t2, .L_h_subtest_1
    li      t2, 2
    beq     a2, t2, .L_h_subtest_2
    j       .L_bad

.L_h_subtest_1:
    # Expect cause = 12 (INSTR_PAGE_FAULT) and MPP=S (01).
    li      t2, 12
    bne     t1, t2, .L_bad
    csrr    t2, CSR_MSTATUS
    srli    t2, t2, 11
    andi    t2, t2, 0x3
    li      t3, 1
    bne     t2, t3, .L_bad
    csrr    t2, CSR_MEPC
    beqz    t2, .L_bad

    # Pass subtest 1.  Fall through into subtest 2 by mret to
    # .L_after_subtest_1 in M-mode.
    li      t2, 0x1800
    csrs    CSR_MSTATUS, t2             # MPP=M
    la      t2, .L_after_subtest_1
    csrw    CSR_MEPC, t2
    mret

.L_h_subtest_2:
    # Expect cause = 13 (LOAD_PAGE_FAULT) and MPP=U (00).
    li      t2, 13
    bne     t1, t2, .L_bad
    csrr    t2, CSR_MSTATUS
    srli    t2, t2, 11
    andi    t2, t2, 0x3
    bnez    t2, .L_bad

    # All subtests passed.
    li      a0, 0
    li      t2, 0x1800
    csrs    CSR_MSTATUS, t2             # MPP=M
    la      t2, .L_done
    csrw    CSR_MEPC, t2
    mret

.L_bad:
    li      a0, 0xBAD
    li      t2, 0x1800
    csrs    CSR_MSTATUS, t2
    la      t2, .L_done
    csrw    CSR_MEPC, t2
    mret

.section .data
.balign 4096
_root_table:
    .skip 4096
