# test_ujtype.S — LUI, AUIPC, JAL, JALR instruction test
# Uses a1-a2 (x11-x12) as temporaries to avoid clobbering ra (x1) and sp (x2).
# On exit (via _halt in common.S), a0 (x10) = number of failures (0 = all pass).
.section .text
.global main
main:
  li   a0, 0

  # LUI: load 0x12345000 into a1
  lui  a1, 0x12345
  li   a2, 0x12345000
  bne  a1, a2, 1f
  j    2f
1: addi a0, a0, 1
2:
  # AUIPC: a1 = PC + 0x1000 — just check it's non-zero
  auipc a1, 1
  beqz  a1, 3f
  j     4f
3: addi a0, a0, 1
4:
  # JAL: jump and link — rd should hold return address
  jal  a1, jal_target
jal_ret:
  j    jal_done
jal_target:
  # Check a1 = address of jal_ret
  la   a2, jal_ret
  bne  a1, a2, 5f
  j    6f
5: addi a0, a0, 1
6:
  jalr x0, a1, 0   # return via JALR to jal_ret
jal_done:
  ret
