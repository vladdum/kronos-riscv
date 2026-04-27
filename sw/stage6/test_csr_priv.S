# test_csr_priv.S — Stage 6a: U-mode read of mhpmcounter3 gated by counteren.
#
# Test 1: mcounteren=0 -> U-mode csrr mhpmcounter3 raises illegal-instr.
# Test 2: mcounteren bit3 set, scounteren bit3 set -> read succeeds.
#
# x10 = 0 on success; non-zero on failure.

.equ CSR_MSTATUS,    0x300
.equ CSR_MEPC,       0x341
.equ CSR_MTVEC,      0x305
.equ CSR_MCAUSE,     0x342
.equ CSR_MCOUNTEREN, 0x306
.equ CSR_SCOUNTEREN, 0x106

.section .text
.global main
main:
    li      a0, 0
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # Reset counter-enable bits (test 1).
    csrw    CSR_MCOUNTEREN, zero
    csrw    CSR_SCOUNTEREN, zero

    # Drop M -> U (MPP = U).
    li      t0, 0
    csrw    CSR_MSTATUS, t0
    la      t0, .L_u_no_en
    csrw    CSR_MEPC, t0
    mret

.L_u_no_en:
    # mcounteren bit3 = 0 -> expect illegal-instr trap.
    csrr    t1, 0xB03                # mhpmcounter3
    # Should not reach here without trap.
    ori     a0, a0, 1
    j       .L_u_no_en_done
.L_u_no_en_done:
    # Force exit via ecall (handler may have moved mepc to here).
    ecall

.L_check2:
    # Back in M. Enable bit3 in both gates and try again.
    li      t0, 0x8                  # bit 3 = mhpmcounter3
    csrw    CSR_MCOUNTEREN, t0
    csrw    CSR_SCOUNTEREN, t0
    li      t0, 0
    csrw    CSR_MSTATUS, t0          # MPP = U
    la      t0, .L_u_en
    csrw    CSR_MEPC, t0
    mret

.L_u_en:
    csrr    t1, 0xC03                # mhpmcounter3 U-alias; gated by counteren
    # Return to M via ecall.
    ecall

.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE
    li      t1, 2                    # illegal-instr (Test 1)
    beq     t0, t1, .L_handle_illegal
    li      t1, 8                    # U-mode ecall (Test 2 finished, or guard ecall)
    beq     t0, t1, .L_handle_ecall
    li      a0, 99
    ret

.L_handle_illegal:
    # Skip the faulting csrr and head to test 2 setup. .L_check2 expects M.
    li      t0, 0x1800               # MPP = M so mret returns to M-mode
    csrs    CSR_MSTATUS, t0
    la      t0, .L_check2
    csrw    CSR_MEPC, t0
    mret
.L_handle_ecall:
    # In the success path, Test 1's csrr traps as illegal (handled via
    # .L_handle_illegal) and never falls through to its guard ecall, so the
    # only ecall the M handler ever sees here is Test 2's success ecall.
    # Route directly to .L_done.
    li      t0, 0x1800               # MPP = M so mret returns to M-mode
    csrs    CSR_MSTATUS, t0
    la      t0, .L_done
    csrw    CSR_MEPC, t0
    mret

.L_done:
    ret

.section .data
.balign 8
_ecall_seen:
    .word   0                        # unused (kept for symbol completeness)
