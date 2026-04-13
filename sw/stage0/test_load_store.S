# test_load_store.S — load/store instruction test
# On exit (via _halt in common.S), a0 (x10) = number of failures (0 = all pass).
.section .data
test_word:  .word 0xDEADBEEF
test_bytes: .byte 0x11, 0x22, 0x33, 0x44

.section .text
.global main
main:
  li   x10, 0
  la   x5, test_word

  # LW: load 0xDEADBEEF
  lw   x3, 0(x5)
  li   x4, 0xDEADBEEF
  bne  x3, x4, 1f
  j    2f
1: addi x10, x10, 1
2:
  # LBU: load byte 0 → 0xEF
  lbu  x3, 0(x5)
  li   x4, 0xEF
  bne  x3, x4, 3f
  j    4f
3: addi x10, x10, 1
4:
  # LB: load byte 3 (0xDE) → sign-extend → 0xFFFFFFDE
  lb   x3, 3(x5)
  li   x4, 0xFFFFFFDE
  bne  x3, x4, 5f
  j    6f
5: addi x10, x10, 1
6:
  # SW then LW roundtrip
  la   x6, test_bytes
  li   x7, 0x12345678
  sw   x7, 0(x6)
  lw   x3, 0(x6)
  bne  x3, x7, 7f
  j    8f
7: addi x10, x10, 1
8:
  ret
