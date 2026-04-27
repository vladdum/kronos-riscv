# test_priv_smoke.S — Stage 6a: end-to-end privilege smoke run.
#
# Sequence: M -> S (via mret) -> U (via sret) -> ecall -> M handler ->
#           M -> U (via mret) -> ecall -> M handler -> done.
#
# Asserts on each transition by checking trap counters and incrementing a0
# on any unexpected path. x10 = 0 on full success.

.equ CSR_MSTATUS,  0x300
.equ CSR_MEPC,     0x341
.equ CSR_MTVEC,    0x305
.equ CSR_MCAUSE,   0x342
.equ CSR_STVEC,    0x105
.equ CSR_SEPC,     0x141
.equ CSR_SCAUSE,   0x142
.equ CSR_MEDELEG,  0x302

.section .text
.global main
main:
    li      a0, 0

    # Install M-mode trap handler (catches anything not delegated).
    la      t0, _mhandler
    csrw    CSR_MTVEC, t0

    # Install S-mode trap handler (handles the U->S delegated ecall).
    la      t0, _shandler
    csrw    CSR_STVEC, t0

    # Delegate cause 8 (U-mode ecall) to S.
    li      t0, 0x100
    csrw    CSR_MEDELEG, t0

    # ---- Stage 1: M -> S via mret ----
    li      t0, 0x800                # MPP = S
    csrw    CSR_MSTATUS, t0
    la      t0, .L_smode
    csrw    CSR_MEPC, t0
    mret
.L_after_smode:
    # Should not fall through; .L_smode -> sret -> U -> ecall -> S handler.
    ori     a0, a0, 0x40
    ret

.L_smode:
    # In S. Sanity: confirm S-mode handler still set.
    la      t0, _shandler
    csrw    CSR_STVEC, t0
    # Mark "S reached".
    la      t0, _stage_reached_s
    li      t1, 1
    sw      t1, 0(t0)
    # Drop S -> U via sret. SPP=0 (reset default).
    la      t0, .L_umode_a
    csrw    CSR_SEPC, t0
    .word   0x10200073               # sret -> U

.L_umode_a:
    # In U (delegated path). ecall here is delegated to S handler.
    la      t0, _stage_reached_u_a
    li      t1, 1
    # Note: U cannot write to M/S CSRs, but a plain store to RAM is fine.
    sw      t1, 0(t0)
    ecall                            # cause 8 -> S handler via medeleg

.L_after_u_a:
    # S handler returned to here via M-mode (it sret'd into U briefly, then
    # we ecall again to bounce up to M to start phase 2). For simplicity,
    # the S handler advances sepc by 4 and sret's back here, leaving us in
    # U mode. We then ecall to climb back to M.
    ecall                            # cause 8 in U; medeleg -> S handler again,
                                     # which on the second visit redirects to M

.L_phase2:
    # Phase 2: M -> U directly. (mret with MPP=U should land in U.)
    li      t0, 0
    csrw    CSR_MSTATUS, t0          # MPP = U
    la      t0, .L_umode_b
    csrw    CSR_MEPC, t0
    mret

.L_umode_b:
    la      t0, _stage_reached_u_b
    li      t1, 1
    sw      t1, 0(t0)
    # ecall in U with medeleg=0x100 -> still routes to S handler. The S
    # handler will detect we are in phase 2 (via _phase_done flag) and
    # ultimately bounce us to M to finish.
    ecall

.L_done:
    # Verify all stage flags were set.
    la      t0, _stage_reached_s
    lw      t1, 0(t0)
    li      t2, 1
    bne     t1, t2, .L_fail_s
    la      t0, _stage_reached_u_a
    lw      t1, 0(t0)
    bne     t1, t2, .L_fail_ua
    la      t0, _stage_reached_u_b
    lw      t1, 0(t0)
    bne     t1, t2, .L_fail_ub
    ret

.L_fail_s:
    ori     a0, a0, 0x01
    ret
.L_fail_ua:
    ori     a0, a0, 0x02
    ret
.L_fail_ub:
    ori     a0, a0, 0x04
    ret

# ---------------------------------------------------------------------------
# S-mode handler — handles delegated U-mode ecall (cause 8).
# First two visits: sret back to U (phase 1 path).
# Third visit:      bump priv up to M by raising an explicit ecall-from-S
#                   (cause 9) which is NOT delegated, so it lands in M handler.
# ---------------------------------------------------------------------------
.balign 4
_shandler:
    csrr    t0, CSR_SCAUSE
    li      t1, 8
    bne     t0, t1, .L_shandler_unexpected

    la      t0, _phase_count
    lw      t1, 0(t0)                # t1 = pre-increment count
    addi    t2, t1, 1
    sw      t2, 0(t0)

    # Visit 1 (first; pre=0): came from .L_umode_a -> sret to .L_after_u_a (U).
    beqz    t1, .L_s_visit1
    # Visit 2 (second; pre=1): came from .L_after_u_a -> climb to M via S-ecall
    # (cause 9 is NOT delegated and goes to M handler).
    li      t3, 1
    beq     t1, t3, .L_s_visit2
    # Visit 3 (third+; pre>=2): came from .L_umode_b -> climb to M for .L_done.
    j       .L_s_visit3

.L_s_visit1:
    la      t0, .L_after_u_a
    csrw    CSR_SEPC, t0
    .word   0x10200073               # sret -> U at .L_after_u_a

.L_s_visit2:
    # Trigger ecall-from-S (cause 9) — not delegated -> lands in M handler.
    ecall

.L_s_visit3:
    # Trigger ecall-from-S — M handler will redirect mepc to .L_done.
    ecall

.L_shandler_unexpected:
    li      a0, 50
    ret

# ---------------------------------------------------------------------------
# M-mode handler — catches non-delegated ecalls.
# First M-visit (cause 9): redirect mepc to .L_phase2 (start phase 2).
# Second M-visit (cause 9): redirect mepc to .L_done.
# ---------------------------------------------------------------------------
.balign 4
_mhandler:
    csrr    t0, CSR_MCAUSE
    li      t1, 9                    # ecall-from-S
    bne     t0, t1, .L_mhandler_unexpected

    la      t0, _m_visits
    lw      t1, 0(t0)                # t1 = pre-increment count (0 on first visit)
    addi    t2, t1, 1
    sw      t2, 0(t0)

    beqz    t1, .L_m_visit1          # first visit: go to .L_phase2
    j       .L_m_visit2              # subsequent: go to .L_done

.L_m_visit1:
    li      t0, 0x1800               # MPP = M so mret returns to M-mode
    csrs    CSR_MSTATUS, t0
    la      t0, .L_phase2
    csrw    CSR_MEPC, t0
    mret

.L_m_visit2:
    li      t0, 0x1800               # MPP = M so mret returns to M-mode
    csrs    CSR_MSTATUS, t0
    la      t0, .L_done
    csrw    CSR_MEPC, t0
    mret

.L_mhandler_unexpected:
    li      a0, 60
    ret

.section .data
.balign 8
_stage_reached_s:    .word 0
_stage_reached_u_a:  .word 0
_stage_reached_u_b:  .word 0
_phase_count:        .word 0
_m_visits:           .word 0
