# test_sret.S — Stage 6a: sret basic flow.
#
# Test A: sret from S with TSR=0 succeeds (S -> U via sret).
# Test B: stub — TSR=1 illegal-instr trap is exercised by ACT4. Per plan note:
#         "If T17 is feeling cumbersome, leave Test B as a stub that always
#          passes and rely on ACT4 for the TSR=1 case."
#
# x10 = 0 on success; non-zero on failure.

.equ CSR_MSTATUS, 0x300
.equ CSR_MEPC,    0x341
.equ CSR_SEPC,    0x141
.equ CSR_MTVEC,   0x305
.equ CSR_MCAUSE,  0x342

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # ---- A: sret from S with TSR=0 succeeds ----
    li      t0, 0x800                # MPP = S
    csrw    CSR_MSTATUS, t0
    la      t0, .L_s_tsr0
    csrw    CSR_MEPC, t0
    mret

.L_s_tsr0:
    # In S. Set sepc = continuation. SPP defaults to 0 (U), so sret -> U.
    la      t0, .L_after_a
    csrw    CSR_SEPC, t0
    .word   0x10200073               # sret -> U at .L_after_a

.L_after_a:
    # Now in U. Use ecall to bounce back to M-mode.
    ecall                            # cause 8 in U; handler returns to .L_b_stub

.L_b_stub:
    # ---- B: stub (relies on ACT4 for the TSR=1 illegal-instr path) ----
    # Reaching this label means Test A passed and we returned to M cleanly.
    ret

.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE
    li      t1, 8                    # U-mode ecall (from .L_after_a)
    beq     t0, t1, .L_handle_ecall
    # Any other cause is unexpected.
    li      a0, 99
    ret

.L_handle_ecall:
    la      t0, .L_b_stub
    csrw    CSR_MEPC, t0
    mret
