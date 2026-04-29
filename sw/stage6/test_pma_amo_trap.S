# test_pma_amo_trap.S — Stage 6e: AMO on NC traps with mcause=7, mtval=PA.

.equ CSR_MTVEC,  0x305
.equ CSR_MEPC,   0x341
.equ CSR_MCAUSE, 0x342
.equ CSR_MTVAL,  0x343

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    la      s0, _trap_taken
    sw      zero, 0(s0)

    li      t0, 0x40000000
    li      t1, 0x55555555
    amoswap.w t2, t1, (t0)          # expect access-fault (mcause=7)

    lw      t3, 0(s0)
    li      t4, 1
    bne     t3, t4, .L_fail_no_trap

    csrr    t3, CSR_MCAUSE
    li      t4, 7
    bne     t3, t4, .L_fail_cause

    csrr    t3, CSR_MTVAL
    li      t4, 0x40000000
    bne     t3, t4, .L_fail_tval
    j       .L_pass

.L_fail_no_trap:
    li      a0, 1
    ret
.L_fail_cause:
    li      a0, 2
    ret
.L_fail_tval:
    li      a0, 3
    ret
.L_pass:
    ret

.balign 4
_mhandler:
    la      t0, _trap_taken
    li      t1, 1
    sw      t1, 0(t0)
    csrr    t0, CSR_MEPC
    addi    t0, t0, 4               # skip the offending amoswap.w
    csrw    CSR_MEPC, t0
    mret

.section .data
.balign 8
_trap_taken:
    .word   0
