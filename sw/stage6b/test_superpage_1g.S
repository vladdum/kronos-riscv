# test_superpage_1g.S — Stage 6b: Sv39 with two 1 GB megapages at level 2.
# Same shape as test_sv39_basic but explicitly named to document the level-2
# leaf path; passes if a translated load + store both succeed.

.equ CSR_SATP, 0x180

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    0x305, t0                   # mtvec

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

    # Two 1 GB megapages: VA[0..1G) -> PA[0..1G); VA[1G..2G) -> PA[1G..2G).
    li      t0, 0xCF
    sd      t0, 0(a1)
    li      t0, 0xCF
    li      t1, (1 << 28)
    or      t0, t0, t1
    sd      t0, 8(a1)

    # satp Sv39 ASID=3.
    srli    t0, a1, 12
    li      t1, 3
    slli    t1, t1, 44
    or      t0, t0, t1
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    CSR_SATP, t0
    sfence.vma

    # Exercise translation through 1 GB leaves on both halves of the map:
    # store + load to a low-page scratch (covered by root[0]).
    li      t0, 0x25A5F00D              # bit 31 = 0
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
.balign 8
_scratch:
    .word 0
