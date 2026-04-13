# test_load_use.S — load-use hazard: load followed immediately by dependent instruction.
# The pipeline must insert exactly one bubble and produce the correct result.
.section .data
val1: .word 0xDEADBEEF
val2: .word 42

.section .text
.global main
main:
  li   a0, 0

  # --- Basic load-use: LW then immediate use ---
  la   t0, val1
  lw   t1, 0(t0)        # t1 = 0xDEADBEEF (load)
  addi t2, t1, 1        # t2 should = 0xDEADBEF0 (uses t1; triggers load-use stall)
  li   t3, 0xDEADBEF0
  # Note: 0xDEADBEEF + 1 = 0xDEADBEF0
  bne  t2, t3, 1f
  j    2f
1:addi a0, a0, 1
2:

  # --- LW then use as address ---
  la   t0, val2
  lw   t1, 0(t0)        # t1 = 42
  lw   t2, 0(t1)        # would fault if t1 wrong; here just verify t1=42
  li   t3, 42
  bne  t1, t3, 3f
  j    4f
3:addi a0, a0, 1
4:

  # --- LW then store (RS2 load-use) ---
  la   t0, val1
  lw   t1, 0(t0)        # t1 = 0xDEADBEEF
  sw   t1, 0(t0)        # RS2=t1 triggers load-use stall; store should write correct value
  lw   t2, 0(t0)        # read back
  li   t3, 0xDEADBEEF
  bne  t2, t3, 5f
  j    6f
5:addi a0, a0, 1
6:

  # --- Two loads in a row, second uses first ---
  la   t0, val2
  lw   t1, 0(t0)        # t1 = 42
  lw   t2, 0(t1)        # uses t1 — load-use stall on t1 (safe since 42 is valid addr in ROM)
  li   t3, 42
  bne  t1, t3, 7f
  j    8f
7:addi a0, a0, 1
8:

  ret
