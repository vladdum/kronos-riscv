"""End-to-end test runner: generate → build → run on Kronos+Sail → diff.

Usage:
    python -m tools.crv.runner --scenario int_hazards --seed 0 --length 200
                                --build-dir obj_dir/crv \
                                --kronos-bin sim/obj_dir/s5/Vsim_top \
                                --link-script sw/stage0/link.ld \
                                --common-s sw/stage0/common.S \
                                --sail-trace-script tools/sail_trace.sh \
                                --diff-script tools/trace_diff.py

Exit codes:
    0  pass (traces match)
    1  divergence (artefacts saved under <build-dir>/<scenario>_<seed>/)
    2  build/run error before diff could occur
"""
from __future__ import annotations
import argparse
import os
import subprocess
import sys
from pathlib import Path

from .generator import generate_program


def run(scenario: str, seed: int, length: int, build_dir: Path,
        kronos_bin: Path, link_script: Path, common_s: Path,
        sail_trace_script: Path, diff_script: Path) -> int:
    name = f"{scenario}_{seed}"
    work = build_dir / name
    work.mkdir(parents=True, exist_ok=True)

    s_path    = work / "prog.S"
    elf_path  = work / "prog.elf"
    hex_path  = work / "prog.hex"
    vmem_path = work / "prog.vmem"
    kronos_trace = work / "kronos.trace"
    sail_trace   = work / "sail.trace"
    diff_out     = work / "diff.txt"

    # 1. Generate
    generate_program(scenario, seed, length, s_path)

    # 2. Build
    rc = subprocess.run([
        "riscv64-unknown-elf-gcc",
        "-march=rv64imafdc_zicsr", "-mabi=lp64",
        "-nostdlib", "-static", f"-T{link_script}",
        str(s_path), str(common_s),
        "-o", str(elf_path),
    ], capture_output=True, text=True)
    if rc.returncode != 0:
        sys.stderr.write(f"[crv-runner] gcc failed for {name}:\n{rc.stderr}\n")
        return 2

    rc = subprocess.run([
        "riscv64-unknown-elf-objcopy", "-O", "ihex",
        str(elf_path), str(hex_path),
    ], capture_output=True, text=True)
    if rc.returncode != 0:
        sys.stderr.write(f"[crv-runner] objcopy failed for {name}:\n{rc.stderr}\n")
        return 2

    # Also generate plain $readmemh-compatible verilog hex (for tb_crv_cov)
    rc = subprocess.run([
        "riscv64-unknown-elf-objcopy", "-O", "verilog",
        "--verilog-data-width", "4",
        str(elf_path), str(vmem_path),
    ], capture_output=True, text=True)
    if rc.returncode != 0:
        sys.stderr.write(f"[crv-runner] objcopy (vmem) failed for {name}:\n{rc.stderr}\n")
        return 2

    # 3. Run Kronos
    env = os.environ.copy()
    env["SIM_TRACE"] = str(kronos_trace)
    rc = subprocess.run([str(kronos_bin), str(hex_path)],
                        env=env, capture_output=True, text=True)
    if rc.returncode != 0:
        sys.stderr.write(f"[crv-runner] kronos run failed for {name}:\n{rc.stderr[:500]}\n")
        return 2

    # 4. Run Sail (sail_trace.sh emits trace on stdout)
    sail_out = subprocess.run([str(sail_trace_script), str(elf_path)],
                              capture_output=True, text=True)
    if sail_out.returncode != 0:
        sys.stderr.write(f"[crv-runner] sail run failed for {name}:\n{sail_out.stderr[:500]}\n")
        return 2
    sail_trace.write_text(sail_out.stdout)

    # 5. Diff
    diff = subprocess.run([str(diff_script), str(kronos_trace), str(sail_trace)],
                          capture_output=True, text=True)
    diff_out.write_text(diff.stdout + "\n--- stderr ---\n" + diff.stderr)
    if diff.returncode != 0:
        sys.stderr.write(f"[crv-runner] DIVERGENCE in {name}\n")
        sys.stderr.write(f"  artefacts: {work}\n")
        return 1

    # 6. Pass — clean up trace artefacts (keep .S for re-run/inspection).
    for f in (kronos_trace, sail_trace, diff_out):
        f.unlink(missing_ok=True)
    return 0


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--scenario", required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--length", type=int, default=200)
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--kronos-bin", type=Path, required=True)
    p.add_argument("--link-script", type=Path, required=True)
    p.add_argument("--common-s", type=Path, required=True)
    p.add_argument("--sail-trace-script", type=Path, required=True)
    p.add_argument("--diff-script", type=Path, required=True)
    args = p.parse_args()
    rc = run(args.scenario, args.seed, args.length, args.build_dir,
             args.kronos_bin, args.link_script, args.common_s,
             args.sail_trace_script, args.diff_script)
    sys.exit(rc)


if __name__ == "__main__":
    main()
