"""RV64IMAFDC instruction encoder.

Each instruction is a small dataclass with a `to_asm()` method that returns
the GAS-compatible mnemonic.  We emit `.S` source (not raw bytes) so the
existing toolchain (riscv64-unknown-elf-gcc) handles assembly + linking;
this also keeps generated tests human-readable for debug.
"""
from __future__ import annotations
from dataclasses import dataclass
from enum import Enum
from typing import Optional


class Reg(Enum):
    X0 = 0; X1 = 1; X2 = 2; X3 = 3; X4 = 4; X5 = 5; X6 = 6; X7 = 7
    X8 = 8; X9 = 9; X10 = 10; X11 = 11; X12 = 12; X13 = 13; X14 = 14; X15 = 15
    X16 = 16; X17 = 17; X18 = 18; X19 = 19; X20 = 20; X21 = 21; X22 = 22; X23 = 23
    X24 = 24; X25 = 25; X26 = 26; X27 = 27; X28 = 28; X29 = 29; X30 = 30; X31 = 31

    def asm(self) -> str:
        return f"x{self.value}"


class FReg(Enum):
    F0 = 0; F1 = 1; F2 = 2; F3 = 3; F4 = 4; F5 = 5; F6 = 6; F7 = 7
    F8 = 8; F9 = 9; F10 = 10; F11 = 11; F12 = 12; F13 = 13; F14 = 14; F15 = 15
    F16 = 16; F17 = 17; F18 = 18; F19 = 19; F20 = 20; F21 = 21; F22 = 22; F23 = 23
    F24 = 24; F25 = 25; F26 = 26; F27 = 27; F28 = 28; F29 = 29; F30 = 30; F31 = 31

    def asm(self) -> str:
        return f"f{self.value}"


class RoundingMode(Enum):
    RNE = 0
    RTZ = 1
    RDN = 2
    RUP = 3
    RMM = 4
    DYN = 7

    def asm(self) -> str:
        return {0: "rne", 1: "rtz", 2: "rdn", 3: "rup", 4: "rmm", 7: "dyn"}[self.value]


@dataclass(frozen=True)
class AsmInstr:
    """A single line of generated assembly. `to_asm()` returns the source."""
    mnemonic: str
    operands: tuple[str, ...]

    def to_asm(self) -> str:
        if not self.operands:
            return self.mnemonic
        return f"{self.mnemonic} {', '.join(self.operands)}"


def _check_simm(value: int, bits: int, name: str) -> None:
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not (lo <= value <= hi):
        raise ValueError(f"{name}={value} out of range [{lo}, {hi}]")


def _check_uimm(value: int, bits: int, name: str) -> None:
    if not (0 <= value < (1 << bits)):
        raise ValueError(f"{name}={value} out of range [0, {(1 << bits) - 1}]")


def _check_branch_offset(offset: int) -> None:
    _check_simm(offset, 13, "branch offset")
    if offset & 1:
        raise ValueError(f"branch offset {offset} must be multiple of 2")


def _check_jal_offset(offset: int) -> None:
    _check_simm(offset, 21, "jal offset")
    if offset & 1:
        raise ValueError(f"jal offset {offset} must be multiple of 2")


def _gp(name: str, x) -> Reg:
    if not isinstance(x, Reg):
        raise TypeError(f"{name} must be a Reg, got {type(x).__name__}")
    return x


def _fp(name: str, x) -> FReg:
    if not isinstance(x, FReg):
        raise TypeError(f"{name} must be an FReg, got {type(x).__name__}")
    return x


def add(rd, rs1, rs2):  return AsmInstr("add",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def sub(rd, rs1, rs2):  return AsmInstr("sub",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def sll(rd, rs1, rs2):  return AsmInstr("sll",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def srl(rd, rs1, rs2):  return AsmInstr("srl",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def sra(rd, rs1, rs2):  return AsmInstr("sra",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))


def addi(rd, rs1, imm):
    _check_simm(imm, 12, "I-type imm")
    return AsmInstr("addi", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), str(imm)))


def slli(rd, rs1, shamt):
    _check_uimm(shamt, 6, "shamt")
    return AsmInstr("slli", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), str(shamt)))


def srli(rd, rs1, shamt):
    _check_uimm(shamt, 6, "shamt")
    return AsmInstr("srli", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), str(shamt)))


def srai(rd, rs1, shamt):
    _check_uimm(shamt, 6, "shamt")
    return AsmInstr("srai", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), str(shamt)))


def lui(rd, imm):
    _check_uimm(imm, 20, "U-type imm")
    return AsmInstr("lui", (_gp("rd", rd).asm(), str(imm)))


def auipc(rd, imm):
    _check_uimm(imm, 20, "U-type imm")
    return AsmInstr("auipc", (_gp("rd", rd).asm(), str(imm)))


def jal(rd, label_or_offset):
    if isinstance(label_or_offset, int):
        _check_jal_offset(label_or_offset)
        return AsmInstr("jal", (_gp("rd", rd).asm(), str(label_or_offset)))
    return AsmInstr("jal", (_gp("rd", rd).asm(), str(label_or_offset)))


def jalr(rd, rs1, imm):
    _check_simm(imm, 12, "I-type imm")
    return AsmInstr("jalr", (_gp("rd", rd).asm(), str(imm), f"({_gp('rs1', rs1).asm()})"))


def _branch(mnemonic, rs1, rs2, label_or_offset):
    if isinstance(label_or_offset, int):
        _check_branch_offset(label_or_offset)
    return AsmInstr(mnemonic, (_gp("rs1", rs1).asm(), _gp("rs2", rs2).asm(), str(label_or_offset)))


def beq(rs1, rs2, off):  return _branch("beq",  rs1, rs2, off)
def bne(rs1, rs2, off):  return _branch("bne",  rs1, rs2, off)
def blt(rs1, rs2, off):  return _branch("blt",  rs1, rs2, off)
def bge(rs1, rs2, off):  return _branch("bge",  rs1, rs2, off)
def bltu(rs1, rs2, off): return _branch("bltu", rs1, rs2, off)
def bgeu(rs1, rs2, off): return _branch("bgeu", rs1, rs2, off)


def _load(mnemonic, rd, rs1, imm):
    _check_simm(imm, 12, "I-type imm")
    return AsmInstr(mnemonic, (_gp("rd", rd).asm(), f"{imm}({_gp('rs1', rs1).asm()})"))


def lb(rd, rs1, imm): return _load("lb", rd, rs1, imm)
def lh(rd, rs1, imm): return _load("lh", rd, rs1, imm)
def lw(rd, rs1, imm): return _load("lw", rd, rs1, imm)
def ld(rd, rs1, imm): return _load("ld", rd, rs1, imm)


def _store(mnemonic, rs2, rs1, imm):
    _check_simm(imm, 12, "S-type imm")
    return AsmInstr(mnemonic, (_gp("rs2", rs2).asm(), f"{imm}({_gp('rs1', rs1).asm()})"))


def sb(rs2, rs1, imm): return _store("sb", rs2, rs1, imm)
def sh(rs2, rs1, imm): return _store("sh", rs2, rs1, imm)
def sw(rs2, rs1, imm): return _store("sw", rs2, rs1, imm)
def sd(rs2, rs1, imm): return _store("sd", rs2, rs1, imm)


def mul(rd, rs1, rs2):  return AsmInstr("mul",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def div(rd, rs1, rs2):  return AsmInstr("div",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def divu(rd, rs1, rs2): return AsmInstr("divu", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def rem(rd, rs1, rs2):  return AsmInstr("rem",  (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))
def remu(rd, rs1, rs2): return AsmInstr("remu", (_gp("rd", rd).asm(), _gp("rs1", rs1).asm(), _gp("rs2", rs2).asm()))


def _amo_suffix(aq: bool, rl: bool) -> str:
    if aq and rl: return ".aqrl"
    if aq:        return ".aq"
    if rl:        return ".rl"
    return ""


def lr_w(rd, rs1, aq=False, rl=False):
    return AsmInstr(f"lr.w{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), f"({_gp('rs1', rs1).asm()})"))


def sc_w(rd, rs2, rs1, aq=False, rl=False):
    return AsmInstr(f"sc.w{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), _gp("rs2", rs2).asm(), f"({_gp('rs1', rs1).asm()})"))


def amoadd_w(rd, rs2, rs1, aq=False, rl=False):
    return AsmInstr(f"amoadd.w{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), _gp("rs2", rs2).asm(), f"({_gp('rs1', rs1).asm()})"))


def lr_d(rd, rs1, aq=False, rl=False):
    return AsmInstr(f"lr.d{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), f"({_gp('rs1', rs1).asm()})"))


def sc_d(rd, rs2, rs1, aq=False, rl=False):
    return AsmInstr(f"sc.d{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), _gp("rs2", rs2).asm(), f"({_gp('rs1', rs1).asm()})"))


def _amoop(op, width, rd, rs2, rs1, aq=False, rl=False):
    return AsmInstr(f"amo{op}.{width}{_amo_suffix(aq, rl)}",
                    (_gp("rd", rd).asm(), _gp("rs2", rs2).asm(), f"({_gp('rs1', rs1).asm()})"))


def amoswap_w(rd, rs2, rs1, aq=False, rl=False):  return _amoop("swap", "w", rd, rs2, rs1, aq, rl)
def amoand_w(rd, rs2, rs1, aq=False, rl=False):   return _amoop("and",  "w", rd, rs2, rs1, aq, rl)
def amoor_w(rd, rs2, rs1, aq=False, rl=False):    return _amoop("or",   "w", rd, rs2, rs1, aq, rl)
def amoxor_w(rd, rs2, rs1, aq=False, rl=False):   return _amoop("xor",  "w", rd, rs2, rs1, aq, rl)
def amomin_w(rd, rs2, rs1, aq=False, rl=False):   return _amoop("min",  "w", rd, rs2, rs1, aq, rl)
def amomax_w(rd, rs2, rs1, aq=False, rl=False):   return _amoop("max",  "w", rd, rs2, rs1, aq, rl)
def amominu_w(rd, rs2, rs1, aq=False, rl=False):  return _amoop("minu", "w", rd, rs2, rs1, aq, rl)
def amomaxu_w(rd, rs2, rs1, aq=False, rl=False):  return _amoop("maxu", "w", rd, rs2, rs1, aq, rl)


def _fp_op3(mnemonic, rd, rs1, rs2, rm: RoundingMode):
    if rm == RoundingMode.DYN:
        return AsmInstr(mnemonic, (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(), _fp("rs2", rs2).asm()))
    return AsmInstr(mnemonic, (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(), _fp("rs2", rs2).asm(), rm.asm()))


def fadd_s(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fadd.s", rd, rs1, rs2, rm)
def fadd_d(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fadd.d", rd, rs1, rs2, rm)
def fmul_s(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fmul.s", rd, rs1, rs2, rm)
def fmul_d(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fmul.d", rd, rs1, rs2, rm)


def fdiv_s(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fdiv.s", rd, rs1, rs2, rm)
def fdiv_d(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fdiv.d", rd, rs1, rs2, rm)
def fsub_s(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fsub.s", rd, rs1, rs2, rm)
def fsub_d(rd, rs1, rs2, rm=RoundingMode.DYN): return _fp_op3("fsub.d", rd, rs1, rs2, rm)


def fsqrt_s(rd, rs1, rm=RoundingMode.DYN):
    if rm == RoundingMode.DYN:
        return AsmInstr("fsqrt.s", (_fp("rd", rd).asm(), _fp("rs1", rs1).asm()))
    return AsmInstr("fsqrt.s", (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(), rm.asm()))


def fsqrt_d(rd, rs1, rm=RoundingMode.DYN):
    if rm == RoundingMode.DYN:
        return AsmInstr("fsqrt.d", (_fp("rd", rd).asm(), _fp("rs1", rs1).asm()))
    return AsmInstr("fsqrt.d", (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(), rm.asm()))


def _fp_op4(mnemonic, rd, rs1, rs2, rs3, rm: RoundingMode):
    """FMADD/FMSUB/FNMADD/FNMSUB — 4-register FP fused multiply-add."""
    if rm == RoundingMode.DYN:
        return AsmInstr(mnemonic, (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(),
                                   _fp("rs2", rs2).asm(), _fp("rs3", rs3).asm()))
    return AsmInstr(mnemonic, (_fp("rd", rd).asm(), _fp("rs1", rs1).asm(),
                               _fp("rs2", rs2).asm(), _fp("rs3", rs3).asm(), rm.asm()))


def fmadd_s(rd, rs1, rs2, rs3, rm=RoundingMode.DYN): return _fp_op4("fmadd.s", rd, rs1, rs2, rs3, rm)
def fmadd_d(rd, rs1, rs2, rs3, rm=RoundingMode.DYN): return _fp_op4("fmadd.d", rd, rs1, rs2, rs3, rm)


def _fp_load(mnemonic, rd, rs1, imm):
    _check_simm(imm, 12, "I-type imm")
    return AsmInstr(mnemonic, (_fp("rd", rd).asm(), f"{imm}({_gp('rs1', rs1).asm()})"))


def flw(rd, rs1, imm): return _fp_load("flw", rd, rs1, imm)
def fld(rd, rs1, imm): return _fp_load("fld", rd, rs1, imm)


def _fp_store(mnemonic, rs2, rs1, imm):
    _check_simm(imm, 12, "S-type imm")
    return AsmInstr(mnemonic, (_fp("rs2", rs2).asm(), f"{imm}({_gp('rs1', rs1).asm()})"))


def fsw(rs2, rs1, imm): return _fp_store("fsw", rs2, rs1, imm)
def fsd(rs2, rs1, imm): return _fp_store("fsd", rs2, rs1, imm)


def csrr(rd, csr_addr):
    return AsmInstr("csrr", (_gp("rd", rd).asm(), f"0x{csr_addr:03x}"))


def csrw(rd, csr_addr, rs1):
    return AsmInstr("csrrw", (_gp("rd", rd).asm(), f"0x{csr_addr:03x}", _gp("rs1", rs1).asm()))


def ecall():  return AsmInstr("ecall",  ())
def ebreak(): return AsmInstr("ebreak", ())
def mret():   return AsmInstr("mret",   ())
