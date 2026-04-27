# test_sdtrig.S — Stage 5h Sdtrig end-to-end test.
#
# Tests:
#   A (bit 0): PC trigger fires at .L_pc_target.
#   B (bit 1): Load-address trigger fires on lw from _payload.
#   C (bit 2): Store-address trigger fires on sw to _payload_C.
#   D (bit 3): Four triggers (T0-T3) programmed simultaneously; all four fire.
#
# x10 (a0) = bitmask of failed tests (0 = all pass).
# _hit_flag is used as an incrementing counter; zeroed before each test.

.equ CSR_TSELECT, 0x7A0
.equ CSR_TDATA1,  0x7A1
.equ CSR_TDATA2,  0x7A2
.equ CSR_TINFO,   0x7A4
.equ CSR_MTVEC,   0x305
.equ CSR_MEPC,    0x341
.equ CSR_MCAUSE,  0x342

# tdata1 bits
.equ TD1_M,       0x40    # bit 6
.equ TD1_EXEC,    0x08    # bit 3
.equ TD1_STORE,   0x04    # bit 2
.equ TD1_LOAD,    0x02    # bit 1

.section .text
.global main
main:
    li      a0, 0                         # fail bitmask
    la      t0, _trap_handler
    csrw    CSR_MTVEC, t0

    # ----- Test A: PC trigger fires at .L_pc_target -----
    la      s1, _hit_flag
    sw      zero, 0(s1)

    csrw    CSR_TSELECT, zero             # T0
    la      t0, .L_pc_target
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_EXEC
    csrw    CSR_TDATA1, t0

    j       .L_pc_target                  # jump → trigger fires
.balign 4
.L_pc_target:
.option norvc
    nop                                    # 4-byte nop; handler skips past here
.option rvc

    # Verify handler set _hit_flag == 1
    lw      t0, 0(s1)
    li      t1, 1
    bne     t0, t1, .L_a_fail
    j       .L_a_ok
.L_a_fail:
    ori     a0, a0, 1
.L_a_ok:
    # Disable trigger
    csrw    CSR_TDATA1, zero

    # ----- Test B: Load-address trigger -----
    sw      zero, 0(s1)

    csrw    CSR_TSELECT, zero
    la      t0, _payload
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_LOAD
    csrw    CSR_TDATA1, t0

    la      t1, _payload
    lw      t2, 0(t1)                     # load → trigger fires; mepc+4 skips this lw
    nop                                    # execution resumes here after mret

    lw      t0, 0(s1)
    li      t1, 1
    bne     t0, t1, .L_b_fail
    j       .L_b_ok
.L_b_fail:
    ori     a0, a0, 2
.L_b_ok:
    csrw    CSR_TDATA1, zero

    # ----- Test C: Store-address trigger -----
    sw      zero, 0(s1)

    csrw    CSR_TSELECT, zero             # T0
    la      t0, _payload_C
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_STORE
    csrw    CSR_TDATA1, t0

    la      t1, _payload_C
    sw      zero, 0(t1)                   # store → trigger fires; mepc+4 skips this sw
    nop                                    # execution resumes here after mret

    lw      t0, 0(s1)
    li      t1, 1
    bne     t0, t1, .L_c_fail
    j       .L_c_ok
.L_c_fail:
    ori     a0, a0, 4
.L_c_ok:
    csrw    CSR_TDATA1, zero

    # ----- Test D: Four triggers simultaneously -----
    # T0 = PC trigger at .L_pc_d
    # T1 = load trigger at _payload_D_load
    # T2 = store trigger at _payload_D_store
    # T3 = PC trigger at .L_pc_d2
    sw      zero, 0(s1)                   # zero _hit_flag (used as counter)

    # Program T0
    csrw    CSR_TSELECT, zero
    la      t0, .L_pc_d
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_EXEC
    csrw    CSR_TDATA1, t0

    # Program T1
    li      t0, 1
    csrw    CSR_TSELECT, t0
    la      t0, _payload_D_load
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_LOAD
    csrw    CSR_TDATA1, t0

    # Program T2
    li      t0, 2
    csrw    CSR_TSELECT, t0
    la      t0, _payload_D_store
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_STORE
    csrw    CSR_TDATA1, t0

    # Program T3
    li      t0, 3
    csrw    CSR_TSELECT, t0
    la      t0, .L_pc_d2
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_EXEC
    csrw    CSR_TDATA1, t0

    # Fire T0: PC trigger at .L_pc_d
.option norvc
.balign 4
    j       .L_pc_d
.balign 4
.L_pc_d:
    nop                                    # 4-byte; T0 fires here, handler skips past
.option rvc

    # Fire T1: load trigger
    la      t1, _payload_D_load
    lw      t2, 0(t1)                     # T1 fires; mepc+4 skips this lw
    nop                                    # resumes here

    # Fire T2: store trigger
    la      t1, _payload_D_store
    sw      zero, 0(t1)                   # T2 fires; mepc+4 skips this sw
    nop                                    # resumes here

    # Fire T3: PC trigger at .L_pc_d2
.option norvc
.balign 4
    j       .L_pc_d2
.balign 4
.L_pc_d2:
    nop                                    # 4-byte; T3 fires here, handler skips past
.option rvc

    # Disable all four triggers
    csrw    CSR_TSELECT, zero
    csrw    CSR_TDATA1, zero
    li      t0, 1
    csrw    CSR_TSELECT, t0
    csrw    CSR_TDATA1, zero
    li      t0, 2
    csrw    CSR_TSELECT, t0
    csrw    CSR_TDATA1, zero
    li      t0, 3
    csrw    CSR_TSELECT, t0
    csrw    CSR_TDATA1, zero

    # Verify counter == 4
    lw      t0, 0(s1)
    li      t1, 4
    bne     t0, t1, .L_d_fail
    j       .L_d_ok
.L_d_fail:
    ori     a0, a0, 8
.L_d_ok:

    # ----- Test E (bit 4): trigger priority over illegal-instr cause -----
    # A PC trigger on an illegal-instruction encoding must report mcause=3
    # (BREAKPOINT) — Sdtrig action fires before the matched instruction
    # commits, so it outranks the decoder's own illegal cause (cause=2).
    sw      zero, 0(s1)
    la      t0, _last_cause
    sw      zero, 0(t0)

    csrw    CSR_TSELECT, zero
    la      t0, .L_illegal_target
    csrw    CSR_TDATA2, t0
    li      t0, TD1_M | TD1_EXEC
    csrw    CSR_TDATA1, t0

    j       .L_illegal_target
.option norvc
.balign 4
.L_illegal_target:
    .word   0x00000000              # all-zeros = illegal opcode
.option rvc

    # Handler stored mcause to _last_cause; expect 3 (BREAKPOINT), not 2.
    la      t0, _last_cause
    lw      t0, 0(t0)
    li      t1, 3
    bne     t0, t1, .L_e_fail
    j       .L_e_ok
.L_e_fail:
    ori     a0, a0, 16
.L_e_ok:
    csrw    CSR_TDATA1, zero
    ret

# -------------------------------------------------------------------------
# Trap handler — on BREAKPOINT (mcause=3):
#   increment _hit_flag, advance mepc by 4, mret.
# -------------------------------------------------------------------------
.balign 4
_trap_handler:
    csrr    t0, CSR_MCAUSE
    # Record the actual cause for later inspection (Test E).
    la      t2, _last_cause
    sw      t0, 0(t2)
    li      t1, 3
    bne     t0, t1, _trap_unexpected
    la      t0, _hit_flag
    lw      t1, 0(t0)
    addi    t1, t1, 1
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
_hit_flag:
    .word   0
.balign 8
_payload:
    .dword  0xDEADBEEF
.balign 8
_payload_C:
    .word   0
.balign 8
_payload_D_load:
    .dword  0xCAFEBABE
.balign 8
_payload_D_store:
    .word   0
.balign 8
_last_cause:
    .word   0
