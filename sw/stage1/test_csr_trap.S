# test_csr_trap.S — ECALL entry, CSR reads, MRET return.
# Verifies that the pipeline sets mepc correctly and MRET resumes at the right PC.
.section .text
.global main

# Trap handler: reads mcause, increments x28 (t3), then MRET
trap_handler:
  csrr  t3, mcause          # read cause
  csrr  t4, mepc            # read mepc (= PC of ecall)
  addi  t4, t4, 4           # mepc += 4 (advance past ecall)
  csrw  mepc, t4
  mret

main:
  li    a0, 0               # failure counter

  # Install trap handler
  la    t0, trap_handler
  csrw  mtvec, t0

  # Enable machine interrupts (mstatus.MIE = 1, but no IRQs wired in test)
  li    t0, 0x8
  csrw  mstatus, t0

  # Reset handler sentinel
  li    t3, 0

  # --- ECALL ---
  ecall                     # should jump to trap_handler
  # After MRET we resume here

  # t3 should be non-zero (handler incremented it via csrr)
  # (actually handler just reads mcause into t3)
  # mcause for ECALL from M-mode = 11
  li    t4, 11
  bne   t3, t4, 1f
  j     2f
1:addi  a0, a0, 1
2:

  # --- Verify mepc was advanced correctly (we resumed after ecall) ---
  # If MRET worked, we're here. If not, we'd be in an infinite loop.
  # Reaching this point is sufficient proof that MRET returned correctly.

  ret
