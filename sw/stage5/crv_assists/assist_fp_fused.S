# assist_fp_fused.S — directed assist for cg_instr_class.op_fmsub, op_fnmsub, op_fnmadd
#                     and cg_instr_class.op_load_fp, op_store_fp
# Why: FMSUB/FNMSUB/FNMADD (opcodes 0b1000111, 0b1001011, 0b1001111) and FP load/store
#      (FLW/FLD/FSW/FSD, opcodes 0b0000111 / 0b0100111) were not covered by existing
#      scenarios. FMADD was already covered; the other three fused ops are exercised here.

.section .text
.global main
main:
    li      a0, 0           # failure counter

    # ---- op_load_fp: FLD (load double) — 1.0 = 0x3FF0000000000000 ----
    # Build 0x3FF0000000000000 via LUI+SLLI and store it.
    lui     t0, 0x3FF00
    slli    t0, t0, 32      # t0 = 0x3FF0000000000000
    addi    sp, sp, -32
    sd      t0, 0(sp)
    fld     fa0, 0(sp)      # fa0 = 1.0d — op_load_fp

    # ---- op_store_fp: FSD (store double) ----
    fsd     fa0, 8(sp)      # op_store_fp
    nop
    nop
    nop
    ld      t1, 8(sp)
    nop
    nop
    bne     t0, t1, 1f
    j       2f
1:  addi    a0, a0, 1
2:

    # Set fa1 = 1.0 double
    fmv.d   fa1, fa0        # fa1 = 1.0d

    # ---- op_fmsub: FMSUB.D  fa2 = fa0 * fa1 - fa1 = 1.0*1.0 - 1.0 = 0.0 ----
    fmsub.d fa2, fa0, fa1, fa1
    fsd     fa2, 16(sp)
    nop
    nop
    nop
    ld      t2, 16(sp)
    # 0.0 double = 0x0000000000000000
    nop
    nop
    bnez    t2, 3f
    j       4f
3:  addi    a0, a0, 1
4:

    # ---- op_fnmsub: FNMSUB.D  fa3 = -(fa0*fa1 - fa1) = -(0.0) ----
    # Result is +0.0 or -0.0, both acceptable
    fnmsub.d fa3, fa0, fa1, fa1
    # Just verify the instruction executed (a0 unchanged)

    # ---- op_fnmadd: FNMADD.D  fa4 = -(fa0*fa1 + fa1) = -(1.0+1.0) = -2.0 ----
    fnmadd.d fa4, fa0, fa1, fa1
    fsd     fa4, 24(sp)
    # Add NOPs to avoid any potential load-after-store pipeline hazard.
    nop
    nop
    nop
    ld      t5, 24(sp)
    # -2.0d = 0xC000000000000000, bit63 must be 1 (negative)
    # Use BGEZ to check NOT negative (fail path)
    nop
    nop
    bgez    t5, 5f          # if t5 >= 0 (NOT negative), fail
    j       6f
5:  addi    a0, a0, 1
6:

    # ---- FLW / FSW (single precision) — 1.0f = 0x3F800000 ----
    li      t0, 0x3F800000
    fmv.w.x ft0, t0         # load integer into FP reg (op_load_fp-like but not load)
    sw      t0, 0(sp)
    flw     ft1, 0(sp)      # op_load_fp (single) — exercises the load opcode
    fsw     ft1, 4(sp)      # op_store_fp (single) — stores lower 32b = 0x3F800000
    nop
    nop
    nop
    lw      t1, 4(sp)       # sign-extends: bit31=0 → t1 = 0x3F800000
    nop
    nop
    bne     t1, t0, 7f
    j       8f
7:  addi    a0, a0, 1
8:

    addi    sp, sp, 32
    ret
