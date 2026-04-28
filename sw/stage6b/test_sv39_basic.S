# test_sv39_basic.S — Stage 6b: enable Sv39 with a 1 GB identity-mapped
# megapage covering VA[0, 1 GB) -> PA[0, 1 GB), then a 2nd megapage for
# VA[1 GB, 2 GB) so the halt sentinel at 0x40000000 still resolves.
# A successful load + store under translation halts with x10 = 0.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_MTVEC,   0x305
.equ CSR_SATP,    0x180

# 1 GB megapage PTE bits: V=1 R=1 W=1 X=1 A=1 D=1 (PPN field set per slot).
# Bits: V(0)=1 R(1)=1 W(2)=1 X(3)=1 U(4)=0 G(5)=0 A(6)=1 D(7)=1 -> 0xCF.

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # ---- Build root table (Sv39): identity-map [0, 2 GB) with 1 GB megapages.
    la      a1, _root_table

    # Clear 4 KB
    mv      t0, a1
    li      t1, 0
    li      t2, 512
.L_clear:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    bltu    t1, t2, .L_clear

    # root[0] = leaf, PPN[2]=0 (PA 0..1 GB).  Flags 0xCF, PPN field starts at bit 10.
    li      t3, 0xCF
    sd      t3, 0(a1)

    # root[1] = leaf, PPN[2]=1 (PA 1..2 GB).  ppn[2]=1 -> 1 << 28 -> bit 28.
    # PTE encoding: ppn[2] occupies bits[53:28]; the level-2 PPN value 1 lands at
    # bit 28 (which is bit 28 of the PTE = (1 << 30) >> 12 << 10 = 1 << 28).
    li      t3, 0xCF
    li      t4, (1 << 28)               # ppn[2]=1 contribution
    or      t3, t3, t4
    sd      t3, 8(a1)                   # root[1]

    # ---- Compose satp = MODE(Sv39=8) | ASID=1 | PPN(root_pa >> 12)
    srli    t0, a1, 12                  # PPN of root table
    li      t1, 1
    slli    t1, t1, 44                  # ASID=1 in [59:44]
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60                  # MODE=Sv39 in [63:60]
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # ---- Verify load + store still work under translation.
    li      t0, 0x12345678
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
    # Any unexpected trap -> fail with cause-encoded a0.
    csrr    a0, 0x342                   # mcause
    ori     a0, a0, 0x80
    ret

.section .data
.balign 4096
_root_table:
    .skip 4096
.balign 8
_scratch:
    .word 0
