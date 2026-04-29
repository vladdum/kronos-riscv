# Stage 7a — ROB-keyed bypass: RAW chains across multi-cycle producers.
# Three chains verify that the ID stage correctly reads rob_q[prod_idx].result
# once the producer has completed but before it commits.
#
# Chain 1: FADD.D → FMV.X.D  (FP-to-int via ROB bypass)
#   fa0 = 1.0d, fa1 = 2.0d
#   ft1 = fa0 + fa1 = 3.0d     (7-stage FADD pipeline; consumer stalls)
#   t1  = bits(ft1)             (reads ft1 from ROB once FADD done)
#   Expected: t1 == 0x4008000000000000 (3.0d)
#
# Chain 2: LW → ADD  (load-to-int, first instance)
#   mem[test_data+0] = 99
#   t2 = lw mem[test_data+0] = 99
#   t3 = t2 + 1 = 100
#   Expected: t3 = 100
#
# Chain 3: LW → ADD  (load-to-int, second instance, different offset)
#   mem[test_data+4] = 42
#   t2 = lw mem[test_data+4] = 42
#   t3 = t2 + 8 = 50
#   Expected: t3 = 50
#
# All chains exercise the same ROB-keyed bypass mechanism: the consumer
# dispatches while the producer's ROB entry shows complete=0 (stalling),
# then reads rob_q[prod_idx].result once complete=1.
#
# PASS: a0 (x10) == 0.

  .section .text
  .globl main
main:
  li    a0, 0                   # error counter

  # ----------------------------------------------------------------
  # Chain 1: FADD.D → FMV.X.D  (DP FP producer, int consumer)
  # IEEE 754 DP: 1.0d = 0x3FF0000000000000
  #              2.0d = 0x4000000000000000
  #              3.0d = 0x4008000000000000
  # ----------------------------------------------------------------
  li    t0, 0x3FF0000000000000
  fmv.d.x fa0, t0               # fa0 = 1.0d
  li    t0, 0x4000000000000000
  fmv.d.x fa1, t0               # fa1 = 2.0d

  fadd.d ft1, fa0, fa1          # ft1 = 1.0d + 2.0d = 3.0d  (multi-cycle producer)
  fmv.x.d t1, ft1               # consumer: reads ft1 via ROB bypass once FADD done

  li    t2, 0x4008000000000000  # expected: 3.0d bits
  beq   t1, t2, 1f              # match → skip failure count
  addi  a0, a0, 1               # mismatch: count failure
1:

  # ----------------------------------------------------------------
  # Chain 2: LW → ADD  (load-to-int, first instance)
  # ----------------------------------------------------------------
  la    t0, test_data           # base addr in RAM
  li    t1, 99
  sw    t1, 0(t0)               # store known value
  lw    t2, 0(t0)               # multi-cycle load (producer)
  addi  t3, t2, 1               # t3 = t2 + 1 = 100 (consumes t2 via ROB)
  li    t4, 100
  beq   t3, t4, 2f              # match → skip failure count
  addi  a0, a0, 1               # mismatch: count failure
2:

  # ----------------------------------------------------------------
  # Chain 3: LW → ADD  (load-to-int, second instance, different offset)
  # ----------------------------------------------------------------
  la    t0, test_data           # base addr in RAM
  li    t1, 42
  sw    t1, 4(t0)               # store known value at offset 4
  lw    t2, 4(t0)               # multi-cycle load (producer)
  addi  t3, t2, 8               # t3 = t2 + 8 = 50 (consumes t2 via ROB)
  li    t4, 50
  beq   t3, t4, 3f              # match → skip failure count
  addi  a0, a0, 1               # mismatch: count failure
3:

  ret

  # ----------------------------------------------------------------
  .section .data
  .align 2
test_data:    .word 0
              .word 0
