# test_irq.S — Machine timer interrupt test
#
# Programs MTVEC, enables the machine timer interrupt (MTIE + mstatus.MIE),
# then asks the simulator to fire irq_timer_i by writing to 0x80000000.
# The sim asserts irq_timer_i = 1 for exactly one rising edge on the cycle
# after the store.  The trap handler sets irq_flag = 1 and returns via MRET.
# After the spin loop exits, the test checks irq_flag and mcause.
#
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
    li   a0, 0              # failure counter

    # ---- Set up trap handler ----
    la   t0, trap_handler
    csrw mtvec, t0

    # ---- Clear irq_flag ----
    la   t1, irq_flag
    sw   zero, 0(t1)

    # ---- Enable machine timer interrupt in MIE (MTIE = bit 7) ----
    li   t0, 0x80
    csrw mie, t0

    # ---- Enable global machine interrupts (mstatus.MIE = bit 3) ----
    li   t0, 0x8
    csrs mstatus, t0

    # ---- Request timer IRQ from simulator ----
    # Storing anything to 0x80000000 causes sim_main.cpp to assert
    # irq_timer_i = 1 for one cycle.  OBI gnt/rvalid are still provided
    # normally; no memory write occurs.
    li   t0, 0x80000000
    sw   zero, 0(t0)

    # ---- Spin loop: the interrupt will be taken here ----
    # The handler sets t1 = 1, so after MRET the loop exits within one
    # more decrement (t1 goes to 0 → falls through).
    li   t1, 1000
1:  addi t1, t1, -1
    bnez t1, 1b

    # ---- Check irq_flag = 1 (handler ran) ----
    la   t0, irq_flag
    lw   t2, 0(t0)
    li   t3, 1
    bne  t2, t3, irq_fail_1
    j    irq_ok_1
irq_fail_1: addi a0, a0, 1
irq_ok_1:

    # ---- Check mcause = 0x80000007 (machine timer interrupt) ----
    csrr t2, mcause
    li   t3, 0x80000007
    bne  t2, t3, irq_fail_2
    j    irq_ok_2
irq_fail_2: addi a0, a0, 1
irq_ok_2:

    ret

# -----------------------------------------------------------------------
# Trap handler
# Uses t0 and t1.  Does NOT touch a0 (failure counter).
# Sets t1 = 1 so the caller's spin loop exits after MRET.
# -----------------------------------------------------------------------
.align 2
trap_handler:
    la   t0, irq_flag
    li   t1, 1
    sw   t1, 0(t0)
    mret

.section .data
irq_flag: .word 0
