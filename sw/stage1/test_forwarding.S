# test_forwarding.S — RAW hazard forwarding paths
# Exercises EX/MEM->EX, MEM/WB->EX, and chained forwarding.
# a0 (x10) = failure count; 0 = all pass.
.section .text
.global main
main:
  li   a0, 0            # failure counter

  # --- EX/MEM -> EX forwarding (1-cycle RAW) ---
  # Producer: addi t1 = 42 (in EX/MEM next cycle)
  # Consumer: addi t2 = t1 + 1 (needs t1 forwarded from EX/MEM)
  li   t0, 42
  add  t1, t0, x0       # t1 = 42
  addi t2, t1, 1        # t2 should be 43
  li   t3, 43
  bne  t2, t3, 1f
  j    2f
1:addi a0, a0, 1
2:

  # --- MEM/WB -> EX forwarding (2-cycle RAW) ---
  # Producer: add t1 = 100
  # 1-instruction gap
  # Consumer: addi t2 = t1 + 5 (needs t1 from MEM/WB)
  li   t0, 100
  add  t1, t0, x0       # t1 = 100
  nop                   # 1 instruction gap
  addi t2, t1, 5        # t2 should be 105
  li   t3, 105
  bne  t2, t3, 3f
  j    4f
3:addi a0, a0, 1
4:

  # --- EX/MEM -> EX for both RS1 and RS2 in same cycle ---
  li   t0, 10
  li   t1, 20
  add  t2, t0, t1       # t2 = 30 (in EX/MEM next cycle)
  add  t3, t0, t1       # t3 = 30 (t2 now in MEM/WB, t3 in EX/MEM)
  add  t4, t2, t3       # RS1=t2 from MEM/WB=30, RS2=t3 from EX/MEM=30 → t4=60
  li   t5, 60
  bne  t4, t5, 5f
  j    6f
5:addi a0, a0, 1
6:

  # --- Chained RAW: each result feeds next immediately ---
  li   t0, 7
  addi t1, t0, 3        # t1 = 10
  addi t2, t1, 5        # t2 = 15 (t1 forwarded from EX/MEM)
  addi t3, t2, 2        # t3 = 17 (t2 forwarded from EX/MEM)
  li   t4, 17
  bne  t3, t4, 7f
  j    8f
7:addi a0, a0, 1
8:

  # --- Forwarding to branch comparator (RS1 and RS2) ---
  li   t0, 5
  addi t1, t0, 0        # t1 = 5 (forwarded to branch RS1)
  addi t2, t0, 0        # t2 = 5 (forwarded to branch RS2)
  bne  t1, t2, 9f       # should not branch (t1 == t2)
  j    10f
9:addi a0, a0, 1
10:

  ret
