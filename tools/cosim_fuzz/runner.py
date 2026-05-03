"""Cosim runner: for each base program × mutation seed, generate, compile,
run on Kronos with retire-trace, run on Sail, diff, and report.

CLI:
  python3 -m tools.cosim_fuzz.runner \\
    --program sw/cosim/recursive_factorial.c \\
    --seed 0 \\
    --out-dir sim/obj_dir/cosim_fuzz/ \\
    --kronos-bin sim/obj_dir/s6/Vsim_top \\
    --sail-trace-script tools/sail_trace.sh \\
    --diff-script tools/trace_diff.py
"""
from __future__ import annotations
import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

from .mutator import mutate_file


CFLAGS = [
    # Match the proven CRV-runner toolchain string. CI's apt-installed
    # gcc-riscv64-unknown-elf does not recognise `_zifencei` as a separate
    # extension; using the same `_zicsr` variant the existing CRV harness
    # uses keeps both runners on a single, supported flag set.
    "-march=rv64imafdc_zicsr", "-mabi=lp64",
    "-nostdlib", "-static", "-Os",
]
TOOLCHAIN = "riscv64-unknown-elf"
HALT_TIMEOUT_S = 30


def _hash(src: str) -> str:
    return hashlib.sha256(src.encode()).hexdigest()[:12]


def compile_program(src: str, common_s: Path, link_ld: Path, out_dir: Path,
                    name: str) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    src_path = out_dir / f"{name}.c"
    elf_path = out_dir / f"{name}.elf"
    hex_path = out_dir / f"{name}.hex"
    src_path.write_text(src)

    cc = ([f"{TOOLCHAIN}-gcc"] + CFLAGS +
          ["-T", str(link_ld), "-o", str(elf_path),
           str(src_path), str(common_s)])
    subprocess.run(cc, check=True)
    subprocess.run([f"{TOOLCHAIN}-objcopy", "-O", "ihex",
                    str(elf_path), str(hex_path)], check=True)
    return elf_path, hex_path


def run_kronos(kronos_bin: Path, hex_path: Path, trace_path: Path) -> int:
    """Returns x10 on halt, -2 on subprocess hang, -1 on missing-x10.

    On hang or sim-side timeout, dumps the tail of the in-progress retire
    trace + stderr so the cosim diagnostic block can show where the program
    wedged.  SIM_MAX_CYCLES is set well above all known cosim-corpus runs
    so the sim's own cycle limit fires before the subprocess timeout —
    the sim's [sim] TIMEOUT message identifies the wedge PC for free.
    """
    env = dict(os.environ)
    env["SIM_TRACE"] = str(trace_path)
    env["SIM_MAX_CYCLES"] = "2000000"
    try:
        res = subprocess.run([str(kronos_bin), str(hex_path)],
                             env=env, capture_output=True,
                             timeout=HALT_TIMEOUT_S)
    except subprocess.TimeoutExpired as exc:
        print(f"  [run_kronos] subprocess timeout after {HALT_TIMEOUT_S}s")
        if trace_path.exists():
            tail = trace_path.read_text().splitlines()[-15:]
            print(f"  trace tail ({len(tail)} of "
                  f"{sum(1 for _ in trace_path.open())} lines):")
            for line in tail:
                print(f"    {line}")
        if exc.stderr:
            stderr_tail = exc.stderr.decode("utf-8", errors="replace").splitlines()[-15:]
            print("  stderr tail:")
            for line in stderr_tail:
                print(f"    {line}")
        return -2
    stdout = res.stdout.decode("utf-8", errors="replace")
    stderr = res.stderr.decode("utf-8", errors="replace")
    for line in stdout.splitlines() + stderr.splitlines():
        if "x10 = " in line:
            try:
                return int(line.split("x10 = ")[1].split()[0])
            except Exception:
                pass
    # No x10 line — sim halted abnormally or hit SIM_MAX_CYCLES.  Dump tail
    # of trace + stderr so the wedge PC is visible in CI logs.
    print(f"  [run_kronos] no halt-x10 line (sim self-terminated or crashed)")
    if trace_path.exists():
        tail = trace_path.read_text().splitlines()[-10:]
        print(f"  trace tail:")
        for line in tail:
            print(f"    {line}")
    if stderr:
        for line in stderr.splitlines()[-10:]:
            print(f"  stderr: {line}")
    return -1


def run_sail(sail_script: Path, elf_path: Path, trace_path: Path) -> None:
    with open(trace_path, "wb") as fp:
        subprocess.run([str(sail_script), str(elf_path)], stdout=fp,
                       check=True, timeout=HALT_TIMEOUT_S)


def diff_traces(diff_script: Path, k_trace: Path, s_trace: Path) -> tuple[bool, str]:
    # --strip-noeffect drops pure-control-flow lines from both traces so the
    # Sail (per-instruction) and Kronos (retire-with-effect-only) streams align.
    res = subprocess.run([str(diff_script), "--strip-noeffect",
                          str(k_trace), str(s_trace)],
                         capture_output=True, text=True)
    return res.returncode == 0, res.stdout + res.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--program", required=True, type=Path)
    ap.add_argument("--seed", required=True, type=int)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--kronos-bin", required=True, type=Path)
    ap.add_argument("--sail-trace-script", required=True, type=Path)
    ap.add_argument("--diff-script", required=True, type=Path)
    ap.add_argument("--common-s", default=Path("sw/cosim/cosim_common.S"), type=Path)
    ap.add_argument("--link-ld", default=Path("sw/stage0/link.ld"), type=Path)
    args = ap.parse_args()

    src_mut, muts = mutate_file(args.program, args.seed)
    name = f"{args.program.stem}_seed{args.seed}_{_hash(src_mut)}"
    print(f"[cosim_fuzz] {name} mutations={[str(m) for m in muts]}")

    out_dir = args.out_dir / name
    elf_path, hex_path = compile_program(src_mut, args.common_s, args.link_ld,
                                         out_dir, name)

    k_trace = out_dir / "kronos.trace"
    s_trace = out_dir / "sail.trace"

    kronos_x10 = run_kronos(args.kronos_bin, hex_path, k_trace)
    if kronos_x10 != 0:
        print(f"[cosim_fuzz] FAIL {name} (kronos x10 = {kronos_x10})")
        sys.exit(1)

    run_sail(args.sail_trace_script, elf_path, s_trace)
    ok, diff = diff_traces(args.diff_script, k_trace, s_trace)
    if not ok:
        print(f"[cosim_fuzz] FAIL {name} (trace diff)")
        # On failure, dump trace sizes + first/last few lines of each so the CI
        # log surfaces enough context to debug Sail-side problems (empty trace,
        # different reset PC, etc.) without needing artefact upload.
        for label, p in (("kronos", k_trace), ("sail", s_trace)):
            if p.exists():
                lines = p.read_text().splitlines()
                print(f"  [{label}] {len(lines)} lines, {p.stat().st_size} bytes")
                for line in lines[:3]:
                    print(f"    {label} head: {line}")
                for line in lines[-3:]:
                    print(f"    {label} tail: {line}")
            else:
                print(f"  [{label}] trace file MISSING")
        print(diff[:4000])
        sys.exit(1)

    print(f"[cosim_fuzz] PASS {name}")


if __name__ == "__main__":
    main()
