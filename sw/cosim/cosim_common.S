# cosim_common.S — cosim corpus startup. Calls cosim_main, halts on return
# with the program's int return value as the exit code (mirrors sw/stage0/common.S
# but renames the entry point to avoid clashing if cosim corpus is ever linked
# alongside stage tests).
.section .text.start
.global _start
_start:
  la    sp, _stack_top
  li    t0, 0x6000              # mstatus.FS = Dirty
  csrrs zero, mstatus, t0
  mv    a0, zero
  mv    a1, zero
  call  cosim_main
_halt:
  li    t0, 0x40000000
  sw    a0, 0(t0)
  j     _halt

# Minimal libc stubs — GCC may emit calls to these even with -Os.
.section .text
.global memcpy
memcpy:
  # a0=dst, a1=src, a2=n — byte-at-a-time copy, return original dst
  mv    t0, a0
1:beqz  a2, 2f
  lb    t1, 0(a1)
  sb    t1, 0(t0)
  addi  t0, t0,  1
  addi  a1, a1,  1
  addi  a2, a2, -1
  j     1b
2:ret

.global memset
memset:
  # a0=dst, a1=val, a2=n — return original dst
  mv    t0, a0
1:beqz  a2, 2f
  sb    a1, 0(t0)
  addi  t0, t0,  1
  addi  a2, a2, -1
  j     1b
2:ret
