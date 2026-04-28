# test_superpage_2m.S — Stage 6b: Sv39 with a 2 MB megapage at level 1.
# root[0] -> L1 table.  L1[0] is a 2 MB leaf identity-mapping VA[0, 2 MB)
# -> PA[0, 2 MB).  root[1] is a 1 GB leaf for VA[1 GB, 2 GB) so the halt
# sentinel at 0x40000000 still resolves.

.equ CSR_SATP, 0x180

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    0x305, t0                   # mtvec

    la      a1, _root_table             # level-2 (root) table
    la      a2, _l1_table               # level-1 table

    # Clear both tables (1024 entries total).
    mv      t0, a1
    li      t1, 0
    li      t2, 1024
.L_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .L_clear

    # root[0] = pointer to L1 table.
    srli    t0, a2, 12
    slli    t0, t0, 10
    ori     t0, t0, 0x01                # V=1, pointer
    sd      t0, 0(a1)

    # L1[0] = leaf, 2 MB megapage.  PPN[1]=0, PPN[0]=0 -> PA 0..2 MB.  Flags 0xCF.
    li      t0, 0xCF
    sd      t0, 0(a2)

    # root[1] = 1 GB leaf, PPN[2]=1 -> PA 1..2 GB (covers sentinel).
    li      t0, 0xCF
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # satp = MODE(Sv39=8) | ASID=2 | PPN(root_pa>>12)
    srli    t0, a1, 12
    li      t1, 2
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # Exercise the 2 MB leaf via a normal load + store.
    li      t0, 0x1234ABCD              # bit 31 = 0 -> lw matches li exactly
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
_l1_table:
    .skip 4096
.balign 8
_scratch:
    .word 0
