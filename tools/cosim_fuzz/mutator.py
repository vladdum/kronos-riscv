"""Mutator: parse `// MUTATE:` headers in a C source file and produce a
mutated copy.

Mutation grammar (per line in source):
    // MUTATE: <name> = randint(<lo>, <hi>)
    // MUTATE: <name> = choice([<v1>, <v2>, ...])

The mutator does NOT rewrite the C body. Each base program is responsible
for capturing its mutable parameters in `enum { ... }` constants whose
*values* the mutator substitutes via simple regex replacement on
`<NAME> = <number>` patterns matching the enum identifier in upper case.
"""
from __future__ import annotations
import re
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


_HEADER_RE_RANGE  = re.compile(r"//\s*MUTATE:\s*(\w+)\s*=\s*randint\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)")
_HEADER_RE_CHOICE = re.compile(r"//\s*MUTATE:\s*(\w+)\s*=\s*choice\(\s*\[([^\]]+)\]\s*\)")


@dataclass
class Mutation:
    name: str
    value: object

    def __str__(self) -> str:
        return f"{self.name}={self.value}"


def parse_headers(src: str) -> Dict[str, Tuple[str, list]]:
    decls: Dict[str, Tuple[str, list]] = {}
    for m in _HEADER_RE_RANGE.finditer(src):
        decls[m.group(1)] = ("range", [int(m.group(2)), int(m.group(3))])
    for m in _HEADER_RE_CHOICE.finditer(src):
        opts = [s.strip().strip('"').strip("'") for s in m.group(2).split(",")]
        decls[m.group(1)] = ("choice", opts)
    return decls


def pick(decls: Dict[str, Tuple[str, list]], rng: random.Random) -> List[Mutation]:
    out: List[Mutation] = []
    for name, (kind, args) in decls.items():
        if kind == "range":
            out.append(Mutation(name, rng.randint(args[0], args[1])))
        elif kind == "choice":
            out.append(Mutation(name, rng.choice(args)))
    return out


def apply(src: str, mutations: List[Mutation]) -> str:
    out = src
    for m in mutations:
        upper = m.name.upper()
        pattern = re.compile(rf"\b{re.escape(upper)}\s*=\s*-?\d+")
        out, n = pattern.subn(f"{upper} = {m.value}", out, count=1)
        if n == 0:
            pattern2 = re.compile(rf"\b{re.escape(m.name)}\s*=\s*-?\d+")
            out, _ = pattern2.subn(f"{m.name} = {m.value}", out, count=1)
    return out


def mutate_file(path: Path, seed: int) -> Tuple[str, List[Mutation]]:
    src = path.read_text()
    decls = parse_headers(src)
    rng = random.Random(seed)
    muts = pick(decls, rng)
    return apply(src, muts), muts
