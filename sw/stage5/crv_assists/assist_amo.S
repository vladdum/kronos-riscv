# assist_amo.S — directed assist for cg_amo coverage bins.
# Exercises LR, SC, AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR,
# AMOMIN, AMOMAX, AMOMINU, AMOMAXU — all on the ATOMIC region
# (0x00016000).
#
# AMO instructions take a register-only address (no offset), so each
# operation is preceded by an explicit address compute into t5.

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # Base address in ATOMIC region
    li      t0, 0x16000     # ATOMIC_BASE

    # -- LR.D / SC.D pair ------------------------------------------------
    li      t1, 0xDEAD
    sd      t1, 0(t0)       # prime memory
    mv      t5, t0
    lr.d    t2, (t5)        # LR: t2 = mem[t0]
    li      t3, 0xBEEF
    sc.d    t4, t3, (t5)    # SC: should succeed (t4 = 0)
    bnez    t4, .Lfail_sc

    # -- AMOADD.W --------------------------------------------------------
    li      t1, 10
    sw      t1, 8(t0)
    li      t2, 5
    addi    t5, t0, 8
    amoadd.w t3, t2, (t5)   # t3 = old (10), mem[8] = 15

    # -- AMOSWAP.W -------------------------------------------------------
    li      t1, 0xABCD
    sw      t1, 16(t0)
    li      t2, 0x1234
    addi    t5, t0, 16
    amoswap.w t3, t2, (t5)  # t3 = old (0xABCD), mem[16] = 0x1234

    # -- AMOXOR.W --------------------------------------------------------
    li      t1, 0xFF00
    sw      t1, 24(t0)
    li      t2, 0x0FF0
    addi    t5, t0, 24
    amoxor.w t3, t2, (t5)   # t3 = 0xFF00, mem[24] = 0xF0F0

    # -- AMOAND.W --------------------------------------------------------
    li      t1, 0xFFFF
    sw      t1, 32(t0)
    li      t2, 0x0F0F
    addi    t5, t0, 32
    amoand.w t3, t2, (t5)   # t3 = 0xFFFF, mem[32] = 0x0F0F

    # -- AMOOR.W ---------------------------------------------------------
    li      t1, 0x00FF
    sw      t1, 40(t0)
    li      t2, 0xFF00
    addi    t5, t0, 40
    amoor.w t3, t2, (t5)    # t3 = 0x00FF, mem[40] = 0xFFFF

    # -- AMOMIN.W (signed) -----------------------------------------------
    li      t1, -1          # 0xFFFFFFFF
    sw      t1, 48(t0)
    li      t2, 1
    addi    t5, t0, 48
    amomin.w t3, t2, (t5)   # min(-1,1)=-1 stays, t3=-1

    # -- AMOMAX.W (signed) -----------------------------------------------
    li      t1, 5
    sw      t1, 56(t0)
    li      t2, 3
    addi    t5, t0, 56
    amomax.w t3, t2, (t5)   # max(5,3)=5 stays, t3=5

    # -- AMOMINU.W -------------------------------------------------------
    li      t1, 0x7FFFFFFF
    sw      t1, 64(t0)
    li      t2, 1
    addi    t5, t0, 64
    amominu.w t3, t2, (t5)  # minu(big,1)=1, t3=big

    # -- AMOMAXU.W -------------------------------------------------------
    li      t1, 1
    sw      t1, 72(t0)
    li      t2, 0x7FFFFFFF
    addi    t5, t0, 72
    amomaxu.w t3, t2, (t5)  # maxu(1,big)=big, t3=1

    ret

.Lfail_sc:
    addi    a0, a0, 1
    ret
