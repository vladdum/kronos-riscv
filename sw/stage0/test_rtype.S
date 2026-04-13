# test_rtype.S — R-type instruction test
# Uses a1-a5 (x11-x15) as temporaries to avoid clobbering ra (x1) and sp (x2).
# On exit (via _halt in common.S), a0 (x10) = number of failures (0 = all pass).
.section .text
.global main
main:
  li   a0, 0          # failure counter

  # ADD: 10 + 20 = 30
  li   a1, 10
  li   a2, 20
  add  a3, a1, a2
  li   a4, 30
  bne  a3, a4, 1f
  j    2f
1: addi a0, a0, 1
2:
  # SUB: 30 - 10 = 20
  li   a1, 30
  li   a2, 10
  sub  a3, a1, a2
  li   a4, 20
  bne  a3, a4, 3f
  j    4f
3: addi a0, a0, 1
4:
  # AND: 0xFF & 0x0F = 0x0F
  li   a1, 0xFF
  li   a2, 0x0F
  and  a3, a1, a2
  li   a4, 0x0F
  bne  a3, a4, 5f
  j    6f
5: addi a0, a0, 1
6:
  # OR: 0xF0 | 0x0F = 0xFF
  li   a1, 0xF0
  li   a2, 0x0F
  or   a3, a1, a2
  li   a4, 0xFF
  bne  a3, a4, 7f
  j    8f
7: addi a0, a0, 1
8:
  # XOR: 0xFF ^ 0xFF = 0
  li   a1, 0xFF
  xor  a3, a1, a1
  bnez a3, 9f
  j    10f
9: addi a0, a0, 1
10:
  # SLT: -1 < 0 → 1
  li   a1, -1
  li   a2, 0
  slt  a3, a1, a2
  li   a4, 1
  bne  a3, a4, 11f
  j    12f
11: addi a0, a0, 1
12:
  ret
