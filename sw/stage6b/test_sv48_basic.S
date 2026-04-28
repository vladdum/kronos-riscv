# test_sv48_basic.S — Stage 6b: Sv48 (mode=9) with one extra outer level.
# Root table (level 3) -> L2 table (level 2) which holds two 1 GB megapage
# leaves identity-mapping VA[0, 2 GB) -> PA[0, 2 GB).  Successful load +
# store under Sv48 translation halts with x10 = 0.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_MTVEC,   0x305
.equ CSR_SATP,    0x180

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    la      a1, _root_table             # level-3 page table
    la      a2, _l2_table               # level-2 page table

    # Clear root + L2 (each 4 KB / 512 entries).
    mv      t0, a1
    li      t1, 0
    li      t2, 1024
.L_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .L_clear            # clears both consecutive tables

    # root[0] = pointer to L2 table.
    # PTE: V=1, R=W=X=0, PPN = (l2_pa >> 12), shifted left by 10.
    srli    t0, a2, 12                  # PPN of L2 table
    slli    t0, t0, 10                  # PPN field starts at bit 10
    ori     t0, t0, 0x01                # V=1 (R=W=X=0 -> pointer)
    sd      t0, 0(a1)

    # L2[0] = leaf, PPN field 0 -> PA 0..1 GB, flags 0xCF.
    li      t0, 0xCF
    sd      t0, 0(a2)

    # L2[1] = leaf, PPN[2]=1 -> PA 1..2 GB.
    li      t0, 0xCF
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a2)

    # satp = MODE(Sv48=9) | ASID=1 | PPN(root_pa >> 12)
    srli    t0, a1, 12
    li      t1, 1
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 9
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # Verify load + store still work under Sv48 translation.
    li      t0, 0x4AFEBABE              # < 2^31 to keep lw == li (no sign-extension)
    la      t1, _scratch
    sw      t0, 0(t1)
    lw      t2, 0(t1)
    bne     t2, t0, .L_fail
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
_l2_table:
    .skip 4096
.balign 8
_scratch:
    .word 0
