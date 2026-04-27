# test_pmp_basic.S — Stage 6a: PMP basic deny-on-locked test.
# Region 0 = NAPOT [0x12000..0x12100), R=1/W=0/X=0, locked.
# Expectation:
#   * M-mode write to 0x12000 -> store-access fault (locked, denies M).
#   * M-mode write to 0x14000 -> no region matches; M passes.
#
# We avoid the .data section's home (link.ld puts it at 0x10000) so the
# tracking variable can be written even with the locked region active.

.equ CSR_MTVEC,    0x305
.equ CSR_MEPC,     0x341
.equ CSR_MCAUSE,   0x342
.equ CSR_PMPCFG0,  0x3A0
.equ CSR_PMPADDR0, 0x3B0

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # Program region 0: NAPOT [0x12000..0x12100), R=1, W=0, X=0, L=1.
    # NAPOT addr encoding: base = 0x12000, size = 256B -> 6 trailing 1s.
    # pmpaddr = (0x12000 >> 2) | ((1 << 5) - 1) = 0x4800 | 0x1F = 0x481F.
    li      t0, 0x481F
    csrw    CSR_PMPADDR0, t0
    # cfg = L=1, A=11(NAPOT), X=0, W=0, R=1 -> 0x99
    li      t0, 0x99
    csrw    CSR_PMPCFG0, t0

    # ---- A: write 0x12000 -> should fault ----
    la      s0, _trap_taken
    sw      zero, 0(s0)
    li      t1, 0x12000
    sw      zero, 0(t1)             # expect access fault; handler skips this insn

    lw      t0, 0(s0)
    li      t1, 1
    bne     t0, t1, .L_fail_a

    # ---- B: write 0x14000 -> no region matches; M passes ----
    sw      zero, 0(s0)
    li      t1, 0x14000
    sw      zero, 0(t1)             # should NOT fault
    lw      t0, 0(s0)
    bnez    t0, .L_fail_b
    ret

.L_fail_a:
    ori     a0, a0, 1
    ret
.L_fail_b:
    ori     a0, a0, 2
    ret

.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE
    li      t1, 7                    # store-access fault
    bne     t0, t1, _trap_unexpected
    la      t0, _trap_taken
    li      t1, 1
    sw      t1, 0(t0)
    csrr    t0, CSR_MEPC
    addi    t0, t0, 4
    csrw    CSR_MEPC, t0
    mret
_trap_unexpected:
    li      a0, 99
    ret

.section .data
.balign 8
_trap_taken:
    .word   0
