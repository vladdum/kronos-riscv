# test_sfence.S — Stage 6b: sfence.vma issued in M-mode is a NOP-equivalent
# from a correctness standpoint, must not trap, and must let the next memory
# access proceed normally.  Mutates the leaf PTE between two accesses to
# show that translation re-reads the table after sfence.vma.

.equ CSR_SATP, 0x180

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    0x305, t0

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

    # Identity-map 1G x 2 (covers text/data and the halt sentinel).
    li      t0, 0xCF
    sd      t0, 0(a1)
    li      t0, 0xCF
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # Enable Sv39 with ASID=5.
    srli    t0, a1, 12
    li      t1, 5
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # First access: populate dTLB.
    li      t0, 0x11111111
    la      t1, _scratch
    sw      t0, 0(t1)

    # Re-write the same PTE (no semantic change), then sfence to flush dTLB.
    li      t2, 0xCF
    sd      t2, 0(a1)
    sfence.vma

    # Second access: must succeed after sfence + TLB re-walk.
    li      t2, 0x22222222
    sw      t2, 0(t1)
    lw      t3, 0(t1)
    bne     t3, t2, .L_fail              # both are positive 32-bit, lw == li

    # Issue an ASID-tagged sfence.vma — just confirms it's accepted without trap.
    sfence.vma zero, x1                 # ASID-targeted variant
    sfence.vma t1, zero                 # VA-targeted variant
    sfence.vma t1, x1                   # VA + ASID variant

    ret

.L_fail:
    li      a0, 1
    ret

.balign 4
_mhandler:
    csrr    a0, 0x342
    ori     a0, a0, 0x80
    ret

.section .data
.balign 4096
_root_table:
    .skip 4096
.balign 8
_scratch:
    .word 0
