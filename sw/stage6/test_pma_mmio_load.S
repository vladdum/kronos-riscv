# test_pma_mmio_load.S — Stage 6e: single-beat NC load round-trip.
#
# Pre-stages a 32-bit sentinel at 0x4001_0000 by writing it via an NC store,
# then reads it back via an NC load and asserts equality. Pass = a0 == 0.

.section .text
.global main
main:
    li      a0, 0
    li      t0, 0x40010000
    li      t1, 0xCAFEBABE
    sw      t1, 0(t0)               # NC store -- single-beat AW/W/B
    lwu     t2, 0(t0)               # NC load (unsigned to match zero-extended t1)
    beq     t1, t2, .L_pass
.L_fail:
    li      a0, 1
.L_pass:
    ret
