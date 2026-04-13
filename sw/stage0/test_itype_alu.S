# test_itype_alu.S — I-type ALU instruction test
# Uses a1-a4 (x11-x14) as temporaries to avoid clobbering ra (x1) and sp (x2).
# On exit (via _halt in common.S), a0 (x10) = number of failures (0 = all pass).
.section .text
.global main
main:
  li   a0, 0

  # ADDI: 10 + 5 = 15
  li   a1, 10
  addi a3, a1, 5
  li   a4, 15
  bne  a3, a4, 1f
  j    2f
1: addi a0, a0, 1
2:
  # ADDI with negative: 10 + (-3) = 7
  addi a3, a1, -3
  li   a4, 7
  bne  a3, a4, 3f
  j    4f
3: addi a0, a0, 1
4:
  # SLLI: 1 << 4 = 16
  li   a1, 1
  slli a3, a1, 4
  li   a4, 16
  bne  a3, a4, 5f
  j    6f
5: addi a0, a0, 1
6:
  # ANDI: 0xFF & 0x0F = 0x0F
  li   a1, 0xFF
  andi a3, a1, 0x0F
  li   a4, 0x0F
  bne  a3, a4, 7f
  j    8f
7: addi a0, a0, 1
8:
  # ORI: 0xF0 | 0x0F = 0xFF
  li   a1, 0xF0
  ori  a3, a1, 0x0F
  li   a4, 0xFF
  bne  a3, a4, 9f
  j    10f
9: addi a0, a0, 1
10:
  ret
