# test_dcache_raw.S — directed regression for issue #82.
# 5 sub-tests, each writes a known pattern, immediately reads it back, ORs any
# mismatch into x10 (failure count). Self-checking: x10 == 0 = pass.
#
# All accesses use the stack (sp) so they hit cacheable memory in a single line.

.section .text
.global main
main:
  li   a0, 0                 # failure count (a0 = x10 per ABI)

  # ----- sub-test 1: sb -> lbu (the issue #82 reproducer) -----
  li   x11, 0x55
  sb   x11, 0(sp)
  lbu  x12, 0(sp)
  xor  x13, x12, x11         # 0 if equal
  snez x13, x13              # 1 if mismatch
  add  a0, a0, x13

  # ----- sub-test 2: sh -> lhu -----
  li   x11, 0xCAFE
  sh   x11, 4(sp)
  lhu  x12, 4(sp)
  xor  x13, x12, x11
  snez x13, x13
  add  a0, a0, x13

  # ----- sub-test 3: sw -> lw -----
  li   x11, 0xDEADBEEF
  sw   x11, 8(sp)
  lw   x12, 8(sp)
  # sign-extend x11 to 64-bit for compare with lw result
  slli x14, x11, 32
  srai x14, x14, 32
  xor  x13, x12, x14
  snez x13, x13
  add  a0, a0, x13

  # ----- sub-test 4: sd -> ld -----
  li   x11, 0x1122334455667788
  sd   x11, 16(sp)
  ld   x12, 16(sp)
  xor  x13, x12, x11
  snez x13, x13
  add  a0, a0, x13

  # ----- sub-test 5: sw -> lbu (low byte of just-stored word) -----
  li   x11, 0x44332211
  sw   x11, 24(sp)
  lbu  x12, 24(sp)           # expect 0x11
  li   x14, 0x11
  xor  x13, x12, x14
  snez x13, x13
  add  a0, a0, x13

  ret
