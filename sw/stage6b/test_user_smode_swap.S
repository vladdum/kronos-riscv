# test_user_smode_swap.S — Stage 6b: privilege swap (M -> U) with Sv39
# translation enabled.  Sets up an identity-mapped Sv39 root, drops to U
# via mret, executes a translated `sw` then a translated `lw` and
# compares the result, then ecall's back to M.  The M handler verifies
# the trap arrived from U-mode (MPP=00) and resumes main with x10=0.
#
# This exercises the Stage 6b dtlb-miss EX→MEM stall fix: the U-mode
# `sw` and `lw` both go through the dTLB, which is cold on first
# access.  The PTW must refill before either access proceeds, otherwise
# the load would see stale data and the compare would fail.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_MTVEC,   0x305
.equ CSR_MCAUSE,  0x342
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

    # Clear root table.
    mv      t0, a1
    li      t1, 0
    li      t2, 512
.L_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .L_clear

    # Identity-map [0, 2 GB) with U=1 leaves so U can fetch our .text.
    li      t0, LEAF_U
    sd      t0, 0(a1)
    li      t0, LEAF_U
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # satp Sv39 ASID=7.
    srli    t0, a1, 12
    li      t1, 7
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # M -> U via mret (MPP cleared = U).
    li      t0, 0x1800
    csrc    CSR_MSTATUS, t0
    la      t0, .L_in_umode
    csrw    CSR_MEPC, t0
    mret

.L_in_umode:
    # In U-mode under Sv39 + U=1 leaves.  Do a translated store followed
    # by a translated load and compare — both go through the dTLB.
    # Use lwu (zero-extending word load) so the compare matches t1 (held
    # as a zero-extended 64-bit immediate from the li sequence).
    la      t0, _scratch
    li      t1, 0xCAFEBABE
    sw      t1, 0(t0)
    lwu     t2, 0(t0)
    bne     t1, t2, .L_u_mismatch
    ecall

.L_u_mismatch:
    li      a0, 0x55                    # mismatch sentinel (load saw stale data)
    ecall

.L_after_u_ecall:
    # In M.  Pass.
    ret

.balign 4
_mhandler:
    # Expected: cause=8 (U-ecall), MPP=U (00).
    csrr    t0, CSR_MCAUSE
    li      t1, 8
    bne     t0, t1, .L_m_unexpected
    csrr    t0, CSR_MSTATUS
    srli    t0, t0, 11
    andi    t0, t0, 0x3
    bnez    t0, .L_m_bad_mpp

    # Pass: set MPP=M, redirect to .L_after_u_ecall in M-mode.
    li      t1, 0x1800
    csrs    CSR_MSTATUS, t1
    la      t1, .L_after_u_ecall
    csrw    CSR_MEPC, t1
    mret

.L_m_unexpected:
    li      a0, 0x11
    j       .L_m_resume
.L_m_bad_mpp:
    li      a0, 0x20
    j       .L_m_resume
.L_m_resume:
    li      t1, 0x1800
    csrs    CSR_MSTATUS, t1
    la      t1, .L_after_u_ecall
    csrw    CSR_MEPC, t1
    mret

.section .data
.balign 4096
_root_table:
    .skip 4096
.balign 8
_scratch:
    .word 0xDEADBEEF
