# assist_traps.S — directed assist for cg_trap bins
# Targets: cg_trap.illegal, cg_trap.ecall_m, cg_trap.ebreak, cg_trap.irq_timer
# Why: The trap coverage predicate in tb_crv_cov.sv uses retire_trap_taken_o /
#      retire_trap_cause_o (new debug ports), which fire on hardware trap entry.
#      This assist exercises each trap type to hit the corresponding coverage bin.
#      For irq_timer: write to 0x80000000 causes the TB to assert irq_timer_i.
#
# NOTE: We verify only the sync traps (illegal/ecall/ebreak) by checking the
# trap_count in .data.  The IRQ trap is exercised but not verified in Vsim_top
# (the mtvec-based handler interaction with the spin loop is fragile under the
# sim_main.cpp IRQ model).  Coverage is recorded by tb_crv_cov.sv separately.

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # ---- Set up trap handler ----
    la      t0, trap_handler
    csrw    mtvec, t0
    la      t1, trap_count
    sw      zero, 0(t1)
    la      t1, last_cause
    sw      zero, 0(t1)

    # ---- 1. Illegal instruction (cause = 2) ----
    .4byte  0x0000007B      # reserved opcode — illegal
.Lresume_illegal:

    # ---- 2. ECALL (cause = 11 in M-mode) ----
    ecall
.Lresume_ecall:

    # ---- 3. EBREAK (cause = 3) ----
    ebreak
.Lresume_ebreak:

    # ---- Verify 3 sync traps were taken ----
    la      t0, trap_count
    lw      t1, 0(t0)
    li      t2, 3
    bne     t1, t2, .Lfail
    j       .Lirq_setup

.Lfail:
    addi    a0, a0, 1
    j       .Lirq_setup

.Lirq_setup:
    # ---- 4. IRQ timer (cause = 0x80000007) ----
    # Enable MIE and MTIE, then trigger the IRQ via the sim magic address.
    # We do NOT try to "prove" the IRQ was taken because the spin-loop
    # interaction with the TB IRQ model causes non-termination under sim_main.
    # The CRV coverage TB (tb_crv_cov.sv) records cg_trap.irq_timer when the
    # hardware takes the interrupt.
    li      t0, 8           # mstatus.MIE = bit 3
    csrrs   zero, mstatus, t0
    li      t0, 0x80        # mie.MTIE = bit 7
    csrrs   zero, mie, t0

    # Trigger the IRQ.
    li      t0, 0x80000000
    sw      zero, 0(t0)     # write to IRQ trigger address

    # Execute a few NOPs to give the IRQ time to fire.  The TB asserts
    # irq_timer_i for 16 cycles; the pipeline takes the interrupt within a
    # few cycles once MIE and MTIE are both set.
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    # After the IRQ fires, MIE is cleared by the trap handler.
    # Execution resumes here (mepc advances past the interrupted NOP).

    ret

# -----------------------------------------------------------------------
# Trap handler: save cause, increment counter, return past faulting instr.
# For IRQ (cause bit 31 set), clear MIE via MPIE so MRET does not re-enable it.
# -----------------------------------------------------------------------
.align 2
trap_handler:
    # Save mcause
    la      t0, last_cause
    csrr    t1, mcause
    sw      t1, 0(t0)

    # Increment trap_count
    la      t0, trap_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)

    # Check interrupt vs sync trap: stage5 stores mcause = {32'b0, trap_cause_i}
    # so bit63 is always 0; interrupt causes have bit31=1 (e.g. 0x80000007).
    csrr    t1, mcause
    srliw   t2, t1, 31      # t2 = 1 if interrupt (bit31 set), 0 otherwise
    bnez    t2, .Lirq

    # Synchronous trap: advance mepc past faulting instruction.
    csrr    t0, mepc
    lhu     t2, 0(t0)
    andi    t3, t2, 3
    li      t4, 3
    beq     t3, t4, .L32bit
    addi    t0, t0, 2
    csrw    mepc, t0
    mret

.L32bit:
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

.Lirq:
    # IRQ: advance mepc past the interrupted instruction (4 bytes).
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    # Clear MPIE so that MRET does NOT re-enable MIE.
    li      t0, 0x80
    csrrc   zero, mstatus, t0
    mret

.section .data
trap_count: .word 0
last_cause: .word 0
