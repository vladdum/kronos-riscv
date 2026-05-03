#!/usr/bin/env python3
"""Diff two normalized retire traces (Kronos vs Sail).

Strips halt-region and ACT4-signature-region memory writes before comparing,
and truncates both traces at the first halt-sentinel write (mem[40000000]).

CSR, register, and memory effects are compared faithfully. As of stage 6c,
Kronos's retire_csr_wdata_o emits the post-write CSR value (matching Sail),
so csr[...] writes are diffed directly.

Reports the first mismatching line (or length mismatch) to stdout and exits
non-zero. Identical traces exit 0 silently.
"""
import re
import sys
from pathlib import Path

HALT_ADDR = 0x40000000
SIG_LO = 0x0000000080002000
SIG_HI = 0x0000000080004000

MEM_RE = re.compile(r"mem\[([0-9a-fA-F]{16})\]=[0-9a-fA-F]{16}")
CSR_RE = re.compile(r"\s*csr\[[0-9a-fA-F]{3}\]=[0-9a-fA-F]{16}")
INSTR_RE = re.compile(r"^[0-9a-fA-F]{16}:([0-9a-fA-F]{1,8})\b")
EFFECT_RE = re.compile(r"(?:x\d+=|f\d+=|mem\[)")

HALT_SENTINEL = f"mem[{HALT_ADDR:016x}]="


def _csr_write_visible(line: str) -> bool:
    """True iff the instr is a Zicsr op that actually writes the CSR per priv-spec.

    Filters two classes of csr[...] mismatch between Kronos and Sail:
      1. Sail emits implicit csr[...] for FP ops (fflags/fcsr/mstatus.FS),
         trap entry (mcause/mepc/mtval/mstatus), and mret/sret (mstatus restore).
         Kronos's retire trace doesn't surface these.
      2. csrrs/csrrc with rs1=x0 (or csrrsi/csrrci with uimm=0) are read-only
         per priv-spec § 9.1: Sail emits no CSR write, but Kronos's
         retire_csr_wen_o asserts unconditionally on any Zicsr instruction.

    Returning False causes csr[...] to be stripped from the trace line.
    """
    m = INSTR_RE.match(line)
    if not m:
        return False
    instr = int(m.group(1), 16)
    # RVC (lo two bits != 11) is never a CSR instruction.
    if (instr & 0x3) != 0x3:
        return False
    # 32-bit SYSTEM (opcode 0x73) with funct3 in {1,2,3,5,6,7} = csrrw/s/c (immediate or not).
    # funct3 == 0 covers ECALL/EBREAK/MRET/SRET/WFI/SFENCE — all implicit effects.
    if (instr & 0x7F) != 0x73:
        return False
    funct3 = (instr >> 12) & 0x7
    if funct3 == 0 or funct3 == 4:
        return False
    # csrrw / csrrwi (funct3[1:0] == 01) always writes regardless of operand.
    if (funct3 & 0x3) == 0x1:
        return True
    # csrrs / csrrc (and immediate variants): writes iff rs1 specifier != 0
    # (for immediate variants, the "rs1" field encodes the uimm — same gate).
    rs1 = (instr >> 15) & 0x1F
    return rs1 != 0


def strip_ignored(line: str, strip_noeffect: bool = False) -> str:
    """Remove mem[...] effects in halt/sig regions and csr[...] effects on
    non-CSR instructions (implicit FS/fflags/trap-CSR writes that Kronos's
    retire trace doesn't surface).

    Explicit csr[...] writes on Zicsr instructions are kept and diffed.

    When `strip_noeffect=True`, also drop any line whose remaining content has
    no observable effect (no register / memory / CSR write — e.g. pure
    control-flow branches and NOPs). Kronos only emits retire events for
    instructions with effects; Sail emits one per instruction. Cosim diffs use
    this to align the two streams. The directed pytest fixtures intentionally
    use no-effect lines to test line-number alignment, so they leave it off.

    Returns cleaned line, or empty string if all observable effects are gone.
    """
    had_mem = bool(MEM_RE.search(line))

    def _repl(m: re.Match) -> str:
        addr = int(m.group(1), 16)
        if addr == HALT_ADDR or SIG_LO <= addr < SIG_HI:
            return ""
        return m.group(0)
    cleaned = MEM_RE.sub(_repl, line)
    if not _csr_write_visible(cleaned):
        cleaned = CSR_RE.sub("", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if had_mem and not EFFECT_RE.search(cleaned):
        return ""
    if strip_noeffect and not EFFECT_RE.search(cleaned):
        return ""
    return cleaned


def load(path: Path, strip_noeffect: bool = False) -> list[str]:
    lines: list[str] = []
    for raw in path.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        # Truncate both traces at the halt sentinel so the Sail _halt loop
        # (which spins indefinitely) does not cause a spurious length mismatch.
        if HALT_SENTINEL in raw:
            break
        s = strip_ignored(raw, strip_noeffect=strip_noeffect)
        if s:
            lines.append(s)
    return lines


PC_RE = re.compile(r"^([0-9a-fA-F]{16}):[0-9a-fA-F]{8}(.*)")


def pc_instr(line: str) -> str:
    """Return the '<pc>:<instr>' prefix of a normalized trace line."""
    return line.split(" ", 1)[0]


def for_compare(line: str) -> str:
    """Return '<pc> [effects]', dropping the instruction encoding.

    Kronos traces the decompressed (32-bit) encoding for C-extension
    instructions; Sail traces the original 16-bit encoding.  Both encode
    the same operation, so we compare by PC + write effects only.
    """
    m = PC_RE.match(line)
    if m:
        return (m.group(1) + m.group(2)).strip()
    return line


def main(argv: list[str]) -> int:
    # Backward-compatible CLI: the historical positional form is
    #   trace_diff.py <kronos> <sail>
    # The cosim runner (Phase 4) passes an extra --strip-noeffect flag to
    # drop pure-control-flow lines so Sail (per-instruction) and Kronos
    # (retire-with-effect-only) align. Existing callers (sim-diff-s5,
    # pytest fixtures) keep the default off.
    strip_noeffect = False
    args = list(argv[1:])
    if "--strip-noeffect" in args:
        strip_noeffect = True
        args = [a for a in args if a != "--strip-noeffect"]
    if len(args) != 2:
        print(f"Usage: {argv[0]} [--strip-noeffect] <kronos_trace> <sail_trace>",
              file=sys.stderr)
        return 2
    a = load(Path(args[0]), strip_noeffect=strip_noeffect)
    b = load(Path(args[1]), strip_noeffect=strip_noeffect)
    if not a:
        print("MISMATCH: Kronos trace is empty", file=sys.stderr)
        return 1
    # Sync: the Kronos retire trace misses startup instructions (pipeline fill
    # and JAL redirect penalty).  Find the first Kronos line in the Sail trace
    # by matching PC:instr, then compare from that point forward.  Fallback
    # to PC-only sync when the encoding differs — Kronos retire-traces the
    # decompressed (32-bit) form for C-extension instructions while Sail traces
    # the original 16-bit form, so the same PC has different opcode bytes in
    # the two streams.  for_compare() already ignores the encoding for content
    # comparison, so it is safe to anchor on PC alone.
    first_key = pc_instr(a[0])
    sail_start = next((i for i, l in enumerate(b) if pc_instr(l) == first_key), None)
    if sail_start is None:
        first_pc = a[0].split(":", 1)[0]
        sail_start = next((i for i, l in enumerate(b) if l.split(":", 1)[0] == first_pc), None)
    if sail_start is None:
        print(f"SYNC FAIL: Kronos first instruction '{first_key}' not found in Sail trace")
        return 1
    b = b[sail_start:]
    n = min(len(a), len(b))
    for i in range(n):
        if for_compare(a[i]) != for_compare(b[i]):
            print(f"MISMATCH at line {i+1}")
            print(f"  kronos: {a[i]}")
            print(f"  sail  : {b[i]}")
            return 1
    if len(a) != len(b):
        print(
            f"MISMATCH length: kronos={len(a)} sail={len(b)} "
            f"(first divergence after line {n})"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
