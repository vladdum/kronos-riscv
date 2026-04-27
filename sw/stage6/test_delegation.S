# test_delegation.S — Stage 6a: ecall-from-U delegated to S-mode handler.
# x10 = 0 if S-mode handler runs with scause=8; non-zero on failure.

.equ CSR_MSTATUS,  0x300
.equ CSR_MEPC,     0x341
.equ CSR_MTVEC,    0x305
.equ CSR_STVEC,    0x105
.equ CSR_SCAUSE,   0x142
.equ CSR_SEPC,     0x141
.equ CSR_MEDELEG,  0x302

.section .text
.global main
main:
    li      a0, 0

    # Install M-mode handler (catches anything not delegated).
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # Install S-mode handler.
    la      t0, _shandler
    csrw    CSR_STVEC, t0

    # Delegate cause 8 (U-mode ecall) to S.
    li      t0, 0x100
    csrw    CSR_MEDELEG, t0

    # Drop M -> S (MPP = S).
    li      t0, 0x800
    csrw    CSR_MSTATUS, t0
    la      t0, .L_smode
    csrw    CSR_MEPC, t0
    mret

.L_smode:
    # In S. SPP=0 already (reset). sret -> U-mode at .L_umode.
    la      t0, .L_umode
    csrw    CSR_SEPC, t0
    .word   0x10200073      # sret -> U
.L_umode:
    ecall                    # cause 8 (U-ecall) -> delegated to S handler

.L_check:
    # If we reach here, delegation succeeded and S-handler returned via sret.
    ret

.balign 4
_shandler:
    csrr    t0, CSR_SCAUSE
    li      t1, 8           # U-mode ecall
    bne     t0, t1, .L_shandler_fail
    # Advance sepc by 4 and sret to .L_check.
    la      t0, .L_check
    csrw    CSR_SEPC, t0
    .word   0x10200073      # sret
    # sret should not return; if it does, fall through is fail.

.L_shandler_fail:
    li      a0, 1
    ret

.balign 4
_mhandler:
    # Should not reach here — bug.
    li      a0, 2
    ret
