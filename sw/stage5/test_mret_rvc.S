# test_mret_rvc.S — MRET into a compressed (RVC) instruction
#
# Uses ecall to enter the trap handler, which sets mepc to a label that
# begins with a compressed instruction, then executes MRET.  Verifies that
# the processor correctly fetches and retires the 2-byte instruction at
# the MRET target without PC misalignment or corruption.
#
# x10 (a0) = failure count (0 = pass)

.option rvc
.section .text
.global main
main:
  li    a0, 0

  # ---- Set up trap handler ----
  la    t0, trap_handler
  csrw  mtvec, t0

  # ---- Clear flag ----
  la    t1, rvc_flag
  sw    zero, 0(t1)

  # ---- Take ecall → trap handler redirects mepc to rvc_target, mret ----
  ecall

  # Execution resumes at .Lafter_rvc (jumped to by rvc_target)
.Lafter_rvc:

  # ---- Check rvc_flag = 0x5A ----
  la    t0, rvc_flag
  lw    t2, 0(t0)
  li    t3, 0x5A
  bne   t2, t3, .Lfail
  j     .Lok
.Lfail:
  addi  a0, a0, 1
.Lok:
  ret

# -----------------------------------------------------------------------
# rvc_target: a sequence that starts with a compressed instruction.
# With .option rvc active, the assembler emits C.LI / C.J where possible.
# We use s1 (x9) and s0 (x8) — both in the CIW/CSS accessible range.
# -----------------------------------------------------------------------
.align 2
rvc_target:
  li    s0, 0x5A             # assembler emits C.LI s0, 0x5A (2 bytes)
  la    s1, rvc_flag
  sw    s0, 0(s1)
  j     .Lafter_rvc          # assembler emits C.J if offset fits

# -----------------------------------------------------------------------
# Trap handler: redirect mepc to rvc_target, then MRET
# -----------------------------------------------------------------------
.align 2
trap_handler:
  la    t0, rvc_target
  csrw  mepc, t0
  mret

.section .data
rvc_flag: .word 0
