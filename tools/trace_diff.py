#!/usr/bin/env python3
"""Diff two normalized retire traces (Kronos vs Sail).

Strips halt-region and ACT4-signature-region memory writes before comparing,
truncates both traces at the first halt-sentinel write (mem[40000000]), and
drops CSR fields before comparison.

CSR fields are excluded because Kronos traces the RS1 operand (the value
being written) while Sail traces the post-write CSR value, and mstatus.SD
differs due to the Dirty tracking model.  Register and memory effects are
compared faithfully.

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
EFFECT_RE = re.compile(r"(?:x\d+=|f\d+=|mem\[)")

HALT_SENTINEL = f"mem[{HALT_ADDR:016x}]="


def strip_ignored(line: str) -> str:
    """Remove mem[...] effects in halt/sig regions and all CSR fields.

    Returns cleaned line, or empty string if all observable effects are gone.
    """
    had_mem = bool(MEM_RE.search(line))

    def _repl(m: re.Match) -> str:
        addr = int(m.group(1), 16)
        if addr == HALT_ADDR or SIG_LO <= addr < SIG_HI:
            return ""
        return m.group(0)
    cleaned = MEM_RE.sub(_repl, line)
    cleaned = CSR_RE.sub("", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if had_mem and not EFFECT_RE.search(cleaned):
        return ""
    return cleaned


def load(path: Path) -> list[str]:
    lines: list[str] = []
    for raw in path.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        # Truncate both traces at the halt sentinel so the Sail _halt loop
        # (which spins indefinitely) does not cause a spurious length mismatch.
        if HALT_SENTINEL in raw:
            break
        s = strip_ignored(raw)
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
    if len(argv) != 3:
        print(f"Usage: {argv[0]} <kronos_trace> <sail_trace>", file=sys.stderr)
        return 2
    a = load(Path(argv[1]))
    b = load(Path(argv[2]))
    if not a:
        print("MISMATCH: Kronos trace is empty", file=sys.stderr)
        return 1
    # Sync: the Kronos retire trace misses startup instructions (pipeline fill
    # and JAL redirect penalty).  Find the first Kronos line in the Sail trace
    # by matching PC:instr, then compare from that point forward.
    first_key = pc_instr(a[0])
    sail_start = next((i for i, l in enumerate(b) if pc_instr(l) == first_key), None)
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
