# test_csr_warl.S — WARL/WLRL CSR field probing
#
# Probes kronos CSR hardware for read-only and constrained-write behaviour:
#   1. mstatus bit 63 (SD) is read-only (derived from mstatus.FS).
#   2. mie: writing all-ones and reading back; reserved bits should not cause
#      a trap (architecture allows storing them or masking them).
#   3. mtvec: writing with mode=2 (reserved) in bits[1:0] and reading back.
#   4. frm: write 5 (illegal RM value per rm_is_illegal), read back = 5;
#      an FP op with rm=DYN resolves to frm=5 → decoder traps (mcause=2).
#      Note: frm=7 does NOT trap (rm_is_illegal only rejects 5 and 6).
#   5. mepc: writing an odd address, reading it back (hardware stores as-is;
#      we do NOT mret with the bad value — just verify storage).
#
# x10 (a0) = failure count (0 = pass)

.section .text
.global main
main:
  li    a0, 0

  # ---- 1. mstatus bit63 (SD) is read-only ----
  # mstatus.FS is Dirty (set by common.S startup).  SD should be 1.
  # Write 0 to bit63 via csrc — hardware ignores writes to SD.
  csrr  t1, mstatus
  li    t2, 1
  slli  t2, t2, 63
  csrc  mstatus, t2           # try to clear SD
  csrr  t3, mstatus
  # Check SD (bit63) did NOT change (still 1 because FS=Dirty)
  srli  t4, t3, 63
  li    t5, 1
  bne   t4, t5, .Lsd_fail
  j     .Lsd_ok
.Lsd_fail:
  addi  a0, a0, 1
.Lsd_ok:

  # ---- 2. mie: write all-ones, verify no trap, read back non-zero ----
  li    t0, -1
  csrw  mie, t0
  csrr  t1, mie
  beqz  t1, .Lmie_fail
  j     .Lmie_ok
.Lmie_fail:
  addi  a0, a0, 1
.Lmie_ok:
  # Restore mie = 0
  csrw  mie, zero

  # ---- 3. mtvec mode=2 (reserved): store and read back ----
  csrr  t0, mtvec
  # OR in mode bits[1:0] = 2
  ori   t1, t0, 2
  csrw  mtvec, t1
  csrr  t2, mtvec
  # We just verify the CSR write/read completes without trap (a0 unchanged).
  # Restore mtvec
  csrw  mtvec, t0

  # ---- 4. frm=5 then FP op with rm=DYN traps ----
  # rm_is_illegal returns true for rm ∈ {5,6} but NOT 7.
  # Write frm=5, then use DYN; decoder resolves DYN→5, traps.
  la    t0, illegal_handler
  csrw  mtvec, t0
  la    t0, trap_count
  sw    zero, 0(t0)

  # Write frm = 5 (reserved RM, triggers rm_is_illegal)
  li    t0, 5
  csrw  frm, t0
  # Verify frm reads back as 5
  csrr  t1, frm
  li    t2, 5
  bne   t1, t2, .Lfrm_fail
  j     .Lfrm_ok
.Lfrm_fail:
  addi  a0, a0, 1
.Lfrm_ok:

  # FADD.S with rm=DYN (rm=7): decoder resolves to frm=5 → rm_is_illegal → trap
  li    t0, 0x3F800000       # 1.0f
  fmv.w.x fa0, t0
  fmv.w.x fa1, t0
  .4byte 0x001070D3          # fadd.s fa1, fa0, fa1, rm=7 (DYN → resolves to frm=5)
.Lafter_fadd:

  # Check trap_count = 1
  la    t0, trap_count
  lw    t1, 0(t0)
  li    t2, 1
  bne   t1, t2, .Ltrap_fail
  j     .Ltrap_ok
.Ltrap_fail:
  addi  a0, a0, 1
.Ltrap_ok:

  # Check saved mcause = 2 (illegal instruction)
  la    t0, saved_cause
  lw    t1, 0(t0)
  li    t2, 2
  bne   t1, t2, .Lcause_fail
  j     .Lcause_ok
.Lcause_fail:
  addi  a0, a0, 1
.Lcause_ok:

  # ---- 5. mepc: write odd address, read back ----
  li    t0, 0xDEAD           # odd address
  csrw  mepc, t0
  csrr  t1, mepc
  bne   t0, t1, .Lmepc_fail
  j     .Lmepc_ok
.Lmepc_fail:
  addi  a0, a0, 1
.Lmepc_ok:

  ret

# -----------------------------------------------------------------------
# Trap handler for illegal-instruction test (item 4)
# Saves mcause, increments trap_count, skips the faulting 4-byte insn.
# -----------------------------------------------------------------------
.align 2
illegal_handler:
  la    t0, saved_cause
  csrr  t1, mcause
  sw    t1, 0(t0)
  la    t0, trap_count
  lw    t1, 0(t0)
  addi  t1, t1, 1
  sw    t1, 0(t0)
  # Advance mepc by 4 (the fadd.s is 4 bytes)
  csrr  t0, mepc
  addi  t0, t0, 4
  csrw  mepc, t0
  mret

.section .data
trap_count:  .word 0
saved_cause: .word 0
