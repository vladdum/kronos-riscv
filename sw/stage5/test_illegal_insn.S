# test_illegal_insn.S — Systematic illegal-instruction trap coverage
#
# Fires a sequence of illegal encodings and verifies each one:
#   - traps with mcause = 2 (illegal instruction)
#   - the trap handler correctly advances mepc by 2 (RVC) or 4 (32-bit)
#   - execution resumes after the faulting instruction
#
# Illegal encodings exercised:
#   a) 0x0000007B  — opcode bits[6:2] = 0b11110 (reserved), 32-bit
#   b) 0x0000005F  — opcode bits[6:2] = 0b10111 (reserved), 32-bit
#   c) 0x0000000B  — opcode bits[6:2] = 0b00010 (reserved), 32-bit
#   d) 0x0000001F  — opcode bits[6:2] = 0b00111 (reserved), 32-bit
#   e) 0x0000      — 16-bit all-zeros (C.ILLEGAL, bits[1:0]=0b00)
#
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
  li    a0, 0

  # ---- Set up illegal-instruction trap handler ----
  la    t0, trap_handler
  csrw  mtvec, t0

  la    t1, trap_count
  sw    zero, 0(t1)
  la    t1, last_cause
  sw    zero, 0(t1)

  # ---- a) Reserved opcode 0b11110_11 ----
  .4byte 0x0000007B
.La_resume:

  # ---- b) Reserved opcode 0b10111_11 ----
  .4byte 0x0000005F
.Lb_resume:

  # ---- c) Reserved opcode 0b00010_11 ----
  .4byte 0x0000000B
.Lc_resume:

  # ---- d) Reserved opcode 0b00111_11 ----
  .4byte 0x0000001F
.Ld_resume:

  # ---- e) 16-bit C.ILLEGAL (0x0000, bits[1:0]=0b00) ----
  .2byte 0x0000
.Le_resume:

  # ---- Verify trap_count = 5 ----
  la    t0, trap_count
  lw    t1, 0(t0)
  li    t2, 5
  bne   t1, t2, .Lcount_fail
  j     .Lcount_ok
.Lcount_fail:
  addi  a0, a0, 1
.Lcount_ok:

  # ---- Verify last_cause = 2 (all traps were illegal-instruction) ----
  la    t0, last_cause
  lw    t1, 0(t0)
  li    t2, 2
  bne   t1, t2, .Lcause_fail
  j     .Lcause_ok
.Lcause_fail:
  addi  a0, a0, 1
.Lcause_ok:

  ret

# -----------------------------------------------------------------------
# Trap handler
# Saves mcause, increments trap_count, then skips the faulting instruction.
# Size: bits[1:0] of the instruction word at mepc: != 11 → 16-bit (skip 2);
#       == 11 → 32-bit (skip 4).
# -----------------------------------------------------------------------
.align 2
trap_handler:
  # Save mcause
  la    t0, last_cause
  csrr  t1, mcause
  sw    t1, 0(t0)

  # Increment trap_count
  la    t0, trap_count
  lw    t1, 0(t0)
  addi  t1, t1, 1
  sw    t1, 0(t0)

  # Determine instruction size from mepc
  csrr  t0, mepc
  lhu   t1, 0(t0)           # load lower 16 bits of faulting instruction
  andi  t2, t1, 3           # bits[1:0]
  li    t3, 3
  beq   t2, t3, .L32bit

  # 16-bit instruction: advance mepc by 2
  addi  t0, t0, 2
  csrw  mepc, t0
  mret

.L32bit:
  # 32-bit instruction: advance mepc by 4
  addi  t0, t0, 4
  csrw  mepc, t0
  mret

.section .data
trap_count: .word 0
last_cause: .word 0
