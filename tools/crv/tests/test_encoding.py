"""Unit tests for tools/crv/encoding.py."""
import pytest
from tools.crv.encoding import (
    Reg, FReg, AsmInstr,
    add, addi, sub, sll, srl, sra, slli, srli, srai,
    lui, auipc, jal, jalr, beq, bne, blt, bge, bltu, bgeu,
    lw, ld, sw, sd, lb, lh, sb, sh,
    mul, div, divu, rem, remu,
    fadd_s, fadd_d, fmul_s, fmul_d,
    fdiv_s, fsqrt_s,
    lr_w, sc_w, amoadd_w,
    ecall, ebreak, mret, csrr, csrw,
)


def test_add_assembly():
    instr = add(Reg.X1, Reg.X2, Reg.X3)
    assert instr.to_asm() == "add x1, x2, x3"


def test_addi_immediate_range():
    addi(Reg.X1, Reg.X2, 2047)
    addi(Reg.X1, Reg.X2, -2048)
    with pytest.raises(ValueError):
        addi(Reg.X1, Reg.X2, 2048)
    with pytest.raises(ValueError):
        addi(Reg.X1, Reg.X2, -2049)


def test_lui_immediate_range():
    lui(Reg.X1, 0xFFFFF)
    lui(Reg.X1, 0)
    with pytest.raises(ValueError):
        lui(Reg.X1, 0x100000)


def test_branch_offset_alignment():
    beq(Reg.X1, Reg.X2, 4)
    beq(Reg.X1, Reg.X2, -4096)
    with pytest.raises(ValueError):
        beq(Reg.X1, Reg.X2, 3)
    with pytest.raises(ValueError):
        beq(Reg.X1, Reg.X2, 4096)


def test_load_immediate_range():
    lw(Reg.X1, Reg.X2, 0)
    lw(Reg.X1, Reg.X2, 2047)
    lw(Reg.X1, Reg.X2, -2048)
    with pytest.raises(ValueError):
        lw(Reg.X1, Reg.X2, 2048)


def test_fp_register_separate_namespace():
    fadd_s(FReg.F0, FReg.F1, FReg.F2)
    with pytest.raises(TypeError):
        fadd_s(Reg.X0, FReg.F1, FReg.F2)


def test_fadd_default_rounding_mode():
    instr = fadd_s(FReg.F0, FReg.F1, FReg.F2)
    assert "rm=dyn" in instr.to_asm() or instr.to_asm().endswith("f0, f1, f2")


def test_amoadd_w_assembly():
    instr = amoadd_w(Reg.X1, Reg.X2, Reg.X3, aq=False, rl=False)
    assert "amoadd.w" in instr.to_asm()
    assert "x1, x2, (x3)" in instr.to_asm()


def test_csrrw_assembly():
    instr = csrw(Reg.X0, 0x340, Reg.X1)
    assert "csrw" in instr.to_asm() or "csrrw" in instr.to_asm()


def test_mret_no_operands():
    instr = mret()
    assert instr.to_asm().strip() == "mret"


def test_ecall_no_operands():
    instr = ecall()
    assert instr.to_asm().strip() == "ecall"
