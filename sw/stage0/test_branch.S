# test_branch.S — branch instruction test
# Uses a1-a2 (x11-x12) as temporaries to avoid clobbering ra (x1) and sp (x2).
# On exit (via _halt in common.S), a0 (x10) = number of failures (0 = all pass).
.section .text
.global main
main:
  li   a0, 0

  # BEQ taken: 5 == 5
  li   a1, 5
  li   a2, 5
  beq  a1, a2, beq_ok
  addi a0, a0, 1
beq_ok:

  # BNE taken: 5 != 6
  li   a2, 6
  bne  a1, a2, bne_ok
  addi a0, a0, 1
bne_ok:

  # BLT taken: -1 < 0 (signed)
  li   a1, -1
  li   a2, 0
  blt  a1, a2, blt_ok
  addi a0, a0, 1
blt_ok:

  # BGE taken: 5 >= 5
  li   a1, 5
  li   a2, 5
  bge  a1, a2, bge_ok
  addi a0, a0, 1
bge_ok:

  # BLTU taken: 0 < 0xFFFFFFFF (unsigned)
  li   a1, 0
  li   a2, -1          # 0xFFFFFFFF unsigned
  bltu a1, a2, bltu_ok
  addi a0, a0, 1
bltu_ok:

  # BEQ not-taken: 5 != 6 — should fall through
  li   a1, 5
  li   a2, 6
  beq  a1, a2, bneq_fail
  j    bneq_ok
bneq_fail:
  addi a0, a0, 1
bneq_ok:

  ret
