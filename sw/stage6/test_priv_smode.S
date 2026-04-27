# test_priv_smode.S — Stage 6a: M -> S transition via mret.
# x10 = 0 if priv reaches S; non-zero on failure.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_STVEC,   0x105

.section .text
.global main
main:
    li      a0, 0
    # Set MPP = S (bit[12:11] = 01)
    li      t0, 0x800
    csrw    CSR_MSTATUS, t0

    # mepc = .L_smode_entry
    la      t0, .L_smode_entry
    csrw    CSR_MEPC, t0
    mret

.L_smode_entry:
    # In S-mode now. Try to write stvec — succeeds only in S or M.
    la      t0, _smode_handler
    csrw    CSR_STVEC, t0
    # Read stvec back; matches written value confirms write succeeded.
    csrr    t1, CSR_STVEC
    bne     t1, t0, .L_fail
    ret

.L_fail:
    li      a0, 1
    ret

.balign 4
_smode_handler:
    # Handler body — should not be reached in this test.
    li      a0, 99
    ret
