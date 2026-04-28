# test_ad_update.S — Stage 6b: hardware A/D bit update.  Translation is
# only active in S/U, so the test drops to S to drive the PTW.  Plant a
# leaf with A=0, D=0, U=1; do an S-mode load through it; the PTW must
# atomically set A=1 (and D=1 on the subsequent store) via LR/SC before
# refilling the TLB.  After returning to M, read the PTE back and verify
# A=1 and D=1.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_MTVEC,   0x305
.equ CSR_SATP,    0x180

# Leaf flags A=0 D=0 with U=1: V=1 R=1 W=1 X=1 U=1 -> 0x1F.
.equ LEAF_NOAD_U,  0x1F
# Leaf flags A=1 D=1 with U=1: 0xDF (used for the sentinel coverage).
.equ LEAF_FULL_U,  0xDF

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

    # root[0] = 1 GB leaf, A=0, D=0 -> PA 0..1 GB.  PTW must populate A/D.
    li      t0, LEAF_NOAD_U
    sd      t0, 0(a1)

    # root[1] = 1 GB leaf, A=1, D=1, PA 1..2 GB (covers sentinel).
    li      t0, LEAF_FULL_U
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # Enable Sv39 ASID=6.
    srli    t0, a1, 12
    li      t1, 6
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # Drop M -> U directly so translation is active and U leaves are accessible.
    li      t0, 0x1800
    csrc    CSR_MSTATUS, t0             # MPP cleared (= U)
    la      t0, .L_umode
    csrw    CSR_MEPC, t0
    mret

.L_umode:
    # In U-mode under translation.  PTW will set A=1 on this load.
    la      t0, _scratch
    lw      t1, 0(t0)

    # Trigger D update with a store.
    li      t2, 0xC0FFEE
    sw      t2, 0(t0)

    # Bounce back to M via ecall to inspect the in-memory PTE.
    ecall

.L_back_in_m:
    # Re-read root[0] (the PTE we planted with A=0, D=0).  A bit (0x40),
    # D bit (0x80) must both be set.
    la      t0, _root_table
    ld      t1, 0(t0)
    andi    t2, t1, 0x40
    beqz    t2, .L_fail_a
    andi    t2, t1, 0x80
    beqz    t2, .L_fail_d
    ret

.L_fail_a:
    li      a0, 1
    ret
.L_fail_d:
    li      a0, 2
    ret

.balign 4
_mhandler:
    # Came from U via ecall (cause 8).  Return to .L_back_in_m in M-mode.
    li      t0, 0x1800
    csrs    CSR_MSTATUS, t0             # MPP = M
    la      t0, .L_back_in_m
    csrw    CSR_MEPC, t0
    mret

.section .data
.balign 4096
_root_table:
    .skip 4096
.balign 8
_scratch:
    .word 0xDEADBEEF
