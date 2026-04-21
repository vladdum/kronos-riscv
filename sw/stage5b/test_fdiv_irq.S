# test_fdiv_irq.S — FDIV result preserved across IRQ/MRET
#
# Verifies that FP register state is intact after a machine timer interrupt
# fires and MRET returns, even when the interrupt is taken immediately after
# two long-latency FDIV.D operations complete.
#
# Flow:
#   1. Execute FDIV.D fa0, fa1, fa2  (4.0/2.0 = 2.0)
#   2. Execute FDIV.D fa3, fa4, fa5  (9.0/3.0 = 3.0)
#   3. Both FDIVs now complete (results in fa0, fa3).
#   4. Trigger IRQ (store to 0x80000000).
#   5. Spin 200 iters; IRQ fires within the spin window.
#   6. Verify:  irq_flag=1, mcause=0x80000007, fa0=2.0, fa3=3.0.
#
# Note: IRQ_HOLD in the simulator (14 cycles with default latencies) is
# shorter than the FDIV stall (~100 cycles), so the IRQ bomb must be armed
# after both FDIVs complete to guarantee the IRQ window overlaps the spin.
#
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
  li    a0, 0

  # ---- Trap handler ----
  la    t0, trap_handler
  csrw  mtvec, t0
  la    t0, irq_flag
  sw    zero, 0(t0)

  # ---- Enable machine timer interrupt ----
  li    t0, 0x80           # MTIE
  csrw  mie, t0
  li    t0, 0x8            # mstatus.MIE
  csrs  mstatus, t0

  # ---- Load operands ----
  li    t0, 0x4010000000000000  # 4.0 double
  fmv.d.x fa1, t0
  li    t0, 0x4000000000000000  # 2.0 double
  fmv.d.x fa2, t0
  li    t0, 0x4022000000000000  # 9.0 double
  fmv.d.x fa4, t0
  li    t0, 0x4008000000000000  # 3.0 double
  fmv.d.x fa5, t0

  # ---- Both FDIVs (pipeline stalls until each completes) ----
  fdiv.d fa0, fa1, fa2         # fa0 = 4.0 / 2.0 = 2.0
  fdiv.d fa3, fa4, fa5         # fa3 = 9.0 / 3.0 = 3.0

  # ---- Both FDIVs done — arm the IRQ bomb ----
  li    t0, 0x80000000
  sw    zero, 0(t0)

  # ---- Spin: IRQ fires within these iterations ----
  li    t1, 200
1:addi  t1, t1, -1
  bnez  t1, 1b

  # ---- Check irq_flag = 1 ----
  la    t0, irq_flag
  lw    t2, 0(t0)
  li    t3, 1
  bne   t2, t3, .Lirq_fail
  j     .Lirq_ok
.Lirq_fail:
  addi  a0, a0, 1
.Lirq_ok:

  # ---- Check mcause = 0x80000007 ----
  csrr  t2, mcause
  li    t3, 0x80000007
  bne   t2, t3, .Lcause_fail
  j     .Lcause_ok
.Lcause_fail:
  addi  a0, a0, 1
.Lcause_ok:

  # ---- Check fa0 = 2.0 ----
  li    t0, 0x4000000000000000
  fmv.d.x ft0, t0
  feq.d t2, fa0, ft0
  beqz  t2, .Lfa0_fail
  j     .Lfa0_ok
.Lfa0_fail:
  addi  a0, a0, 1
.Lfa0_ok:

  # ---- Check fa3 = 3.0 ----
  li    t0, 0x4008000000000000
  fmv.d.x ft0, t0
  feq.d t2, fa3, ft0
  beqz  t2, .Lfa3_fail
  j     .Lfa3_ok
.Lfa3_fail:
  addi  a0, a0, 1
.Lfa3_ok:

  ret

# -----------------------------------------------------------------------
.align 2
trap_handler:
  la    t0, irq_flag
  li    t1, 1
  sw    t1, 0(t0)
  mret

.section .data
irq_flag: .word 0
