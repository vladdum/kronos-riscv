# test_pma_mmio_store.S — Stage 6e: single-beat NC store with byte-strobe.
#
# Writes a byte into a known doubleword via SB to 0x4001_0001 (offset 1),
# then reads the full doubleword back to confirm only the targeted byte
# changed. Pass = a0 == 0.

.section .text
.global main
main:
    li      a0, 0
    li      t0, 0x40010008          # base
    li      t1, 0x1122334455667788
    sd      t1, 0(t0)               # seed full doubleword

    li      t2, 0xAA
    sb      t2, 1(t0)               # NC byte store at byte 1

    ld      t3, 0(t0)
    li      t4, 0x112233445566AA88   # only byte 1 should be 0xAA
    bne     t3, t4, .L_fail
    j       .L_pass
.L_fail:
    li      a0, 1
.L_pass:
    ret
