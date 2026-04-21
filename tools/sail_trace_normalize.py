#!/usr/bin/env python3
"""Normalize a Sail riscv-sim instruction trace into the Kronos trace format.

Reads Sail's raw trace on stdin, writes normalized lines on stdout:
  <pc_16hex>:<instr_8hex> [x<n>=<16hex>] [f<n>=<16hex>]
    [mem[<16hex>]=<16hex>] [csr[<3hex>]=<16hex>]

Sail instruction line format:
  [STEP] [MODE]: 0xPC (0xINSN) DISASM
followed by effect lines until the next instruction:
  x<n> <- 0xVAL
  f<n> <- 0xVAL
  CSR <name> (0xADDR) <- 0xVAL
  mem[W,0xADDR] <- 0xVAL
"""
import re
import sys

# Instruction commit line:  [42] [M]: 0x0000000000001234 (0xdeadbeef) disasm...
SAIL_COMMIT_RE = re.compile(
    r'^\[(\d+)\] \[[MSU]\]: 0x([0-9a-fA-F]+) \(0x([0-9a-fA-F]+)\)'
)

REG_WRITE_RE = re.compile(r'^x(\d+) <- 0x([0-9a-fA-F]+)')
FP_WRITE_RE  = re.compile(r'^f(\d+) <- 0x([0-9a-fA-F]+)')
# mem[W,0xADDR] <- 0xVAL
MEM_WRITE_RE = re.compile(r'^mem\[W,0x([0-9a-fA-F]+)\] <- 0x([0-9a-fA-F]+)')
# CSR <name> (0xADDR) <- 0xVAL   (also handles CSR ... -> writes)
CSR_WRITE_RE = re.compile(r'^CSR \S+ \(0x([0-9a-fA-F]+)\) <- 0x([0-9a-fA-F]+)')


def _flush(pending: list) -> str | None:
    """Emit one normalized line from a (pc, instr, effects) tuple."""
    if not pending:
        return None
    pc, instr, effects = pending
    parts = [f"{pc:016x}:{instr:08x}"]
    for effect_line in effects:
        rm = REG_WRITE_RE.match(effect_line)
        if rm:
            n, v = int(rm.group(1)), int(rm.group(2), 16)
            if n != 0:
                parts.append(f"x{n}={v:016x}")
            continue
        fm = FP_WRITE_RE.match(effect_line)
        if fm:
            n, v = int(fm.group(1)), int(fm.group(2), 16)
            parts.append(f"f{n}={v:016x}")
            continue
        mm = MEM_WRITE_RE.match(effect_line)
        if mm:
            a, v = int(mm.group(1), 16), int(mm.group(2), 16)
            parts.append(f"mem[{a:016x}]={v:016x}")
            continue
        cm = CSR_WRITE_RE.match(effect_line)
        if cm:
            a, v = int(cm.group(1), 16), int(cm.group(2), 16)
            parts.append(f"csr[{a:03x}]={v:016x}")
    return " ".join(parts)


def main() -> int:
    pending_pc: int | None = None
    pending_instr: int | None = None
    pending_effects: list[str] = []

    for raw in sys.stdin:
        line = raw.rstrip("\n")

        m = SAIL_COMMIT_RE.match(line)
        if m:
            # Flush previous instruction
            if pending_pc is not None:
                out = _flush((pending_pc, pending_instr, pending_effects))
                if out is not None:
                    print(out)
            pending_pc = int(m.group(2), 16)
            pending_instr = int(m.group(3), 16)
            pending_effects = []
        elif pending_pc is not None:
            # Accumulate effect lines for the current instruction
            pending_effects.append(line)

    # Flush last instruction
    if pending_pc is not None:
        out = _flush((pending_pc, pending_instr, pending_effects))
        if out is not None:
            print(out)

    return 0


if __name__ == "__main__":
    sys.exit(main())
