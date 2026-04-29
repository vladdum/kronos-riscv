# Stage 7a — AMO-at-head ordering: AMOSWAP + AMOADD with intermixed loads.
# Per spec §7.4, AMO ops only fire when at ROB head. This test verifies
# that intermixed plain loads do not reorder past the AMO boundary, and
# that the AMO return values and post-AMO memory state are correct.
#
# Sequence:
#   1. Init  mem[A] = V0 (0x1111111111111111)
#   2. AMOSWAP.D t3, t2(t0)  — mem[A] ← V1 (0x2222...), t3 returns V0
#   3. LD   t4, 0(t0)         — must see V1 (plain load after AMO)
#   4. AMOSWAP.D t5, t1(t0)  — mem[A] ← V2 (0x3333...), t5 returns V1
#   5. LD   t6, 0(t0)         — must see V2
#   6. LR.D s1, (t0)          — LR returns V2 (ordering check; sets reservation)
#   7. AMOADD.D s2, s3(t0)   — mem[A] ← V2 + DELTA; s2 returns V2
#   8. LD   s4, 0(t0)         — must see V2 + DELTA (plain load after AMOADD)
#
# PASS: a0 (x10) == 0.

  .section .text
  .globl main
main:
  li    a0, 0                       # error counter

  # ------------------------------------------------------------------
  # Setup: load address and value constants
  # ------------------------------------------------------------------
  la    t0, test_data               # t0 = &mem[A]

  li    t1, 0x3333333333333333      # V2
  li    t2, 0x2222222222222222      # V1
  li    s0, 0x1111111111111111      # V0 (initial value, for comparison)

  # ------------------------------------------------------------------
  # Step 2: first AMOSWAP.D — swap V1 into mem[A], get V0 back
  # ------------------------------------------------------------------
  amoswap.d t3, t2, (t0)           # mem[A] ← V1; t3 ← V0

  # Check: t3 must equal V0 (0x1111...)
  bne   t3, s0, 1f
  j     2f
1:
  addi  a0, a0, 1                   # mismatch: first amoswap returned wrong value
2:

  # ------------------------------------------------------------------
  # Step 3: plain load — must see V1 (first AMO has committed)
  # ------------------------------------------------------------------
  ld    t4, 0(t0)                   # t4 = mem[A], expected V1

  bne   t4, t2, 3f
  j     4f
3:
  addi  a0, a0, 1                   # mismatch: load after first amoswap
4:

  # ------------------------------------------------------------------
  # Step 4: second AMOSWAP.D — swap V2 into mem[A], get V1 back
  # ------------------------------------------------------------------
  amoswap.d t5, t1, (t0)           # mem[A] ← V2; t5 ← V1

  # Check: t5 must equal V1 (0x2222...)
  bne   t5, t2, 5f
  j     6f
5:
  addi  a0, a0, 1                   # mismatch: second amoswap returned wrong value
6:

  # ------------------------------------------------------------------
  # Step 5: plain load — must see V2 (second AMO has committed)
  # ------------------------------------------------------------------
  ld    t6, 0(t0)                   # t6 = mem[A], expected V2

  bne   t6, t1, 7f
  j     8f
7:
  addi  a0, a0, 1                   # mismatch: load after second amoswap
8:

  # ------------------------------------------------------------------
  # Step 6: LR.D — load-reserved; checks ordering (LR sees V2)
  # ------------------------------------------------------------------
  lr.d  s1, (t0)                    # s1 = mem[A], expected V2 (reservation set)

  bne   s1, t1, 9f
  j     10f
9:
  addi  a0, a0, 1                   # mismatch: LR returned wrong value
10:

  # ------------------------------------------------------------------
  # Step 7: AMOADD.D — add DELTA to mem[A], return old value
  # Clears the LR reservation (intervening AMO) as a side-effect.
  # ------------------------------------------------------------------
  li    s3, 0x0001000100010001      # DELTA
  amoadd.d s2, s3, (t0)            # mem[A] ← V2 + DELTA; s2 ← V2

  # Check: s2 must equal V2 (0x3333...)
  bne   s2, t1, 11f
  j     12f
11:
  addi  a0, a0, 1                   # mismatch: amoadd returned wrong value
12:

  # ------------------------------------------------------------------
  # Step 8: plain load — must see V2 + DELTA (AMOADD committed)
  # ------------------------------------------------------------------
  add   s5, t1, s3                  # s5 = V2 + DELTA (expected value)
  ld    s4, 0(t0)                   # s4 = mem[A]

  bne   s4, s5, 13f
  j     14f
13:
  addi  a0, a0, 1                   # mismatch: load after amoadd
14:

  ret

  # ------------------------------------------------------------------
  # Test data: initialized to V0 = 0x1111111111111111
  # ------------------------------------------------------------------
  .section .data
  .balign 8
test_data: .dword 0x1111111111111111
