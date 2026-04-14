# test_atomic.S — LR/SC + AMO instruction tests
.section .text
.globl main
main:
    li   a0, 0
    la   t6, data

    # ---- LR.W / SC.W ----

    li   t0, 42
    sw   t0, 0(t6)

    # LR.W: load-reserved
    lr.w t1, (t6)
    li   t2, 42
    bne  t1, t2, fail

    # SC.W: store-conditional (reservation valid → should succeed, result=0)
    li   t3, 99
    sc.w t4, t3, (t6)
    bne  t4, x0, fail
    lw   t5, 0(t6)
    li   t0, 99
    bne  t5, t0, fail

    # SC.W without prior LR (reservation cleared) → should fail, result=1
    li   t3, 200
    sc.w t4, t3, (t6)
    li   t5, 1
    bne  t4, t5, fail
    lw   t0, 0(t6)
    li   t1, 99
    bne  t0, t1, fail            # memory must NOT have changed

    # ---- AMOADD.W ----
    li   t0, 100
    sw   t0, 8(t6)
    addi t3, t6, 8
    li   t1, 25
    amoadd.w t2, t1, (t3)       # t2 = old (100), mem[8] = 125
    li   t4, 100
    bne  t2, t4, fail
    lw   t5, 8(t6)
    li   t0, 125
    bne  t5, t0, fail

    # ---- AMOSWAP.W ----
    li   t0, 0xAA
    sw   t0, 16(t6)
    addi t3, t6, 16
    li   t1, 0xBB
    amoswap.w t2, t1, (t3)     # t2 = old (0xAA), mem[16] = 0xBB
    li   t4, 0xAA
    bne  t2, t4, fail
    lw   t5, 16(t6)
    li   t0, 0xBB
    bne  t5, t0, fail

    # ---- AMOAND.W ----
    li   t0, 0xFF
    sw   t0, 24(t6)
    addi t3, t6, 24
    li   t1, 0x0F
    amoand.w t2, t1, (t3)      # t2 = old (0xFF), mem[24] = 0x0F
    li   t4, 0xFF
    bne  t2, t4, fail
    lw   t5, 24(t6)
    li   t0, 0x0F
    bne  t5, t0, fail

    # ---- AMOOR.W ----
    li   t0, 0xA0
    sw   t0, 32(t6)
    addi t3, t6, 32
    li   t1, 0x0F
    amoor.w t2, t1, (t3)       # t2 = old (0xA0), mem[32] = 0xAF
    li   t4, 0xA0
    bne  t2, t4, fail
    lw   t5, 32(t6)
    li   t0, 0xAF
    bne  t5, t0, fail

    li   a0, 0
    ret

fail:
    li   a0, 1
    ret

.section .data
.align 3
data:
    .zero 64
