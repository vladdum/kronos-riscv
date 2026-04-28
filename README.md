# kronos-riscv

A RISC-V CPU core implemented in SystemVerilog, architecturally inspired by the
[BOOM (Berkeley Out-of-Order Machine)](https://github.com/riscv-boom/riscv-boom)
microarchitecture.

The project is structured as a **learning progression** — each stage produces a
working, testable core that can boot real software. Later stages add
microarchitectural complexity, culminating in a BOOM-class out-of-order
superscalar design.

## Target ISA

**Final target:** RV64GC (RV64IMAFDС)

The pipeline is 64-bit wide from Stage 4. Stages 0–3 implement RV32I/IM/IMC;
Stage 4 widens all datapath elements to 64 bits and adds the A extension.

## Staged Development

| Stage | Description                                     | ISA              | Bus     | Status      |
|-------|-------------------------------------------------|------------------|---------|-------------|
| 0     | Single-cycle golden model                       | RV32I            | OBI     | Complete    |
| 1     | 5-stage in-order pipeline                       | RV32I            | OBI     | Complete    |
| 2     | M extension + CSR hardening                     | RV32IM           | OBI     | Complete    |
| 3     | AXI4 switch + C extension + branch predictor   | RV32IMC          | AXI4    | Complete    |
| 4     | RV64I + A extension                             | RV64IMAC         | AXI4    | Complete    |
| 5a    | F/D extensions (pipelined, no FDIV/FSQRT)       | RV64IMAFD        | AXI4    | Complete    |
| 5b    | FDIV/FSQRT (iterative SRT)                      | RV64IMAFDC       | AXI4    | Complete    |
| 5c    | Performance counters (Zicntr + partial Zihpm)   | RV64IMAFDC       | AXI4    | Complete    |
| 5d    | CRV harness (random gen + Sail diff + 144-bin coverage) | RV64IMAFDC | AXI4    | Complete    |
| 5e    | Instruction cache (16 KB / 4-way / Tree-PLRU)   | RV64IMAFDC       | AXI4    | Complete    |
| 5f    | Data cache (16 KB / 4-way / write-back+allocate) | RV64IMAFDC      | AXI4    | Complete    |
| 5g    | FENCE.I → D-cache flush + LSU TB cleanup        | RV64IMAFDC       | AXI4    | Complete    |
| 5h    | Debug & trace layer (Sdtrig, event taxonomy, sim-side trace) | RV64IMAFDC | AXI4 | Complete |
| 6a    | Privileged modes (M/S/U) + trap delegation + PMP | RV64IMAFDC      | AXI4    | Complete    |
| 6b    | Sv39/Sv48 MMU + iTLB/dTLB + HW PTW + sfence.vma | RV64IMAFDC       | AXI4    | Complete    |
| 6c    | Closeout: dhrystone perf gate, integration program, mstatus reset, GLS-s6 docs | RV64IMAFDC | AXI4 | Complete |
| 7     | Out-of-order execution (BOOM style)             | RV64IMAFDС       | AXI4    | Planned     |

Each stage lives in its own `rtl/stage<N>/` directory and exposes the same
`kronos_top` module interface, so the testbench and SoC integration point never
change between stages.

## Bus Interface

**Stages 0–2:** OBI (Open Bus Interface) — a simple req/gnt/rvalid handshake
with one outstanding transaction per port (instruction fetch + data).

**Stages 3–5:** Native AXI4 — single-outstanding AXI4 master ports (one
in-flight transaction per channel). The `axi_from_mem` bridge used in earlier
stages is removed; the core connects directly to the AXI crossbar.

**Stage 6:** AXI4 with multiple outstanding IDs — the out-of-order LSU issues
multiple in-flight memory requests with tagged, out-of-order responses.

## Repository Structure

```
kronos-riscv/
├── rtl/
│   ├── kronos_pkg.sv          # Shared enums, structs, types
│   ├── stage0/                # Stage 0: single-cycle golden model
│   ├── stage1/                # Stage 1: 5-stage pipeline
│   │   ├── kronos_lsu.sv      # LSU with 2-state OBI FSM + mem_stall
│   │   ├── kronos_forward.sv  # Data forwarding mux selects (pure comb)
│   │   ├── kronos_hazard.sv   # Stall/flush control (pure comb)
│   │   └── kronos_top.sv      # Pipeline top (IF→ID→EX→MEM→WB)
│   ├── stage2/                # Stage 2: RV32M multiply/divide
│   │   ├── kronos_decode.sv   # RV32I+M decoder (extends stage0)
│   │   ├── kronos_muldiv.sv   # Multi-cycle mul/div FSM (2–34 cycles)
│   │   └── kronos_top.sv      # Stage2 pipeline top (muldiv + combined stall)
│   ├── stage3/                # Stage 3: AXI4 bus + C extension + branch predictor
│   │   ├── kronos_lsu.sv      # AXI4 LSU (single-outstanding, replaces OBI LSU)
│   │   ├── kronos_decompress.sv # RV32C 16-bit → 32-bit instruction expander
│   │   ├── kronos_align.sv    # Fetch alignment buffer (variable-width instructions)
│   │   ├── kronos_bpred.sv    # Bimodal branch predictor with BTB
│   │   └── kronos_top.sv      # Stage3 pipeline top (AXI4 + C ext + bpred)
│   ├── stage4/                # Stage 4: RV64I + A extension
│   │   ├── kronos_alu.sv      # 64-bit ALU with W-suffix (ADDW/SUBW/…)
│   │   ├── kronos_decode.sv   # RV64IMAC decoder
│   │   ├── kronos_decompress.sv # RV64C 16-bit → 32-bit instruction expander
│   │   ├── kronos_muldiv.sv   # 64-bit multiply/divide unit
│   │   ├── kronos_lsu.sv      # AXI4 LSU with LR/SC reservation + AMO RMW
│   │   ├── kronos_csr.sv      # 64-bit CSR file (mstatus.SXL/UXL = 2)
│   │   └── kronos_top.sv      # Stage4 pipeline top
│   └── stage5/                # Stage 5a: F/D floating-point (no FDIV/FSQRT)
│       ├── kronos_decode.sv   # RV64IMAFD decoder with FP rm resolution
│       ├── kronos_regfile_fp.sv # 3R1W 32×64-bit FP register file
│       ├── kronos_lsu.sv      # AXI4 LSU + FLW/FLD/FSW/FSD with NaN-boxing
│       ├── kronos_csr.sv      # CSR + FFLAGS/FRM/FCSR/mstatus.FS
│       ├── kronos_top.sv      # Stage5 pipeline top (FPU integrated)
│       └── fpu/
│           ├── kronos_fpu_fmisc.sv  # 1-cycle: FSGNJ, FMIN, FMAX, FCLASS, CMP, FMV
│           ├── kronos_fpu_fcvt.sv   # 2-cycle: FCVT int↔FP and S↔D
│           ├── kronos_fpu_fadd.sv   # 5-cycle: FADD/FSUB
│           ├── kronos_fpu_fmul.sv   # 4-cycle: FMUL
│           ├── kronos_fpu_fma.sv    # 5-cycle: FMADD/FMSUB/FNMADD/FNMSUB
│           ├── kronos_fpu_scoreboard.sv # WAW busy-table + WB port reservation
│           ├── kronos_fpu_top.sv    # FPU dispatch wrapper
│           ├── kronos_fpu_iter.sv   # FDIV/FSQRT wrapper FSM (variable latency)
│           ├── kronos_fpu_fdiv_core.sv  # Radix-2 SRT division core
│           └── kronos_fpu_fsqrt_core.sv # Radix-2 SRT square root core
├── tb/
│   ├── tb_pkg.sv              # Shared testbench utilities
│   ├── stage0/                # Stage 0 testbenches
│   ├── stage1/                # Stage 1 unit testbenches
│   ├── stage2/                # Stage 2 unit testbenches
│   ├── stage3/                # Stage 3 unit testbenches
│   ├── stage4/                # Stage 4 unit testbenches
│   ├── stage5/                # Stage 5 FPU unit + integration testbenches
│   └── gls/                   # Gate-level sim testbench + AXI memory model
├── sw/
│   ├── stage0/                # Stage 0 test programs (RISC-V assembly)
│   ├── stage1/                # Stage 1 hazard-focused test programs
│   ├── stage2/                # Stage 2 M-extension test programs
│   ├── stage3/                # Stage 3 test programs
│   ├── stage4/                # Stage 4 test programs (RV64IMAC)
│   ├── stage5/                # Stage 5a FP test programs (RV64IMAFD)
│   └── stage5b/               # Stage 5b FDIV/FSQRT test programs
├── sim/
│   ├── Makefile               # Verilator build and run targets
│   ├── sim_main.cpp           # AXI4 C++ simulation driver (stages 3–5)
│   ├── sim_main_obi.cpp       # OBI C++ simulation driver (stages 0–2)
│   └── run_arch_test_s{1..5}.sh   # ACT4 per-test runner (SIM_MAX_CYCLES + timeout)
├── fpga/
│   ├── kv260/                 # Vivado synthesis flow for KV260
│   │   ├── synth.tcl          # Synthesis + P&R script
│   │   ├── synth.cfg          # Frequency / options overrides
│   │   └── synth_directives.xdc  # Timing constraints
│   └── gls/                   # Gate-level simulation flow (xsim)
│       ├── synth_ooc.tcl      # Out-of-context synth + funcsim/timesim emit
│       └── run_xsim.tcl       # xsim batch runner
├── riscv-arch-test/           # git submodule (official ACT4 compliance suite)
├── .github/workflows/sim.yml  # sim-all + compliance-s{1..5} matrix CI
├── tools/
│   └── coverage_gate.py       # LCOV line-coverage gate (≥95% threshold)
├── Makefile                   # Top-level: lint, build, regression, compliance, synth
├── kronos_riscv.core          # FuseSoC core descriptor (active: stage5)
├── LICENSE
└── CLAUDE.md                  # Claude Code project instructions
```

## Documentation

See [`docs/architecture.md`](docs/architecture.md) for the full architecture reference covering all completed stages (0–5b).

See [`docs/testplan.md`](docs/testplan.md) for the catalog of every verification test and how to run it.

## Building

Prerequisites: Verilator, FuseSoC, `riscv64-unknown-elf-gcc`.

The top-level `Makefile` covers the common workflow. All targets accept
`STAGE=<0-5>` (default 5) and `JOBS=<N>` (default: nproc).

```bash
make help          # list all targets and options

make lint          # Verilator lint (STAGE=5 by default)
make lint STAGE=3  # lint an earlier stage

make build         # build Verilator simulator (STAGE=5 by default)
make build STAGE=4

make regression    # full unit-testbench suite across all stages

make compliance          # ACT4 compliance suite (STAGE=5 by default)
make compliance STAGE=1  # run for a specific stage (stages 1–5 only)

make coverage      # line coverage gate (≥95% threshold, stage 5)

make synth                      # Vivado synthesis + P&R at 200 MHz (KV260)
make synth SYNTH_FREQ_MHZ=180   # sweep a different frequency
```

### Unit testbenches

Per-module testbenches are run directly from `sim/`:

```bash
# Stage 5 FPU unit testbenches
cd sim && make sim-fpu-fmisc       # FSGNJ/FMIN/FMAX/FCLASS/CMP/FMV
cd sim && make sim-fpu-fcvt        # FCVT (int↔FP, S↔D)
cd sim && make sim-fpu-fadd        # FADD/FSUB (5-stage)
cd sim && make sim-fpu-fmul        # FMUL (4-stage)
cd sim && make sim-fpu-fma         # FMA (5-stage)
cd sim && make sim-fpu-fdiv-core   # FDIV radix-2 SRT core
cd sim && make sim-fpu-fsqrt-core  # FSQRT radix-2 SRT core
cd sim && make sim-fpu-iter        # FDIV/FSQRT wrapper (SoftFloat-verified)
cd sim && make sim-fpu-top-iter    # iter integration in FPU top

# Stage 5 integration testbenches
cd sim && make sim-core-fp-basic       # basic FMV + FADD end-to-end
cd sim && make sim-core-fp-forwarding  # FMUL→FADD with forwarding

# Stage 4 unit testbenches
cd sim && make sim-alu-s4      # 64-bit ALU
cd sim && make sim-decode-s4   # RV64IMAC decoder
cd sim && make sim-muldiv-s4   # 64-bit multiply/divide
cd sim && make sim-lsu-s4      # AXI4 LSU with LR/SC + AMO

# Stage 3 unit testbenches
cd sim && make sim-decompress  # RV64C instruction expander
cd sim && make sim-bpred       # branch predictor
cd sim && make sim-lsu-s3      # AXI4 LSU

# Stage 2 unit testbenches
cd sim && make sim-muldiv

# Stage 1 unit testbenches
cd sim && make sim-forward   # forwarding unit
cd sim && make sim-hazard    # hazard/stall control
cd sim && make sim-lsu-s1    # LSU OBI FSM
```

## FPGA Implementation (KV260)

Requires Vivado 2025.x and a KV260 board support package. The flow targets
`kronos_kv260_top` (a thin timing harness wrapping `kronos_top` with a Zynq
PS clock) on XCK26-SFVC784-2LV-c silicon.

Post-route Fmax measured on this stage (Vivado 2025.2, xck26-sfvc784-2LV):

| Target clock | WNS (ns) | Status |
|--------------|----------|--------|
| 200 MHz      | 0.000    | **Closes** (0 failing endpoints) |
| 220 MHz      | ≈ −0.34  | Does not close — see issue #37 |

The 220 MHz gap is dominated by DSP48 cascade intrinsic delays on the 53×53
FPU multipliers; closing it requires a Karatsuba-style decomposition tracked
in issue #37.

```bash
make synth                     # synthesis + P&R at 200 MHz (default)
make synth SYNTH_FREQ_MHZ=180  # sweep a different frequency
```

Reports land in `build/vivado_kv260_<freq>/`:

| File | Contents |
|------|----------|
| `post_route_timing.txt` | WNS, TNS, worst path |
| `post_route_utilization.txt` | LUT / FF / DSP / BRAM counts |
| `post_synth_timing.txt` | Estimated WNS after synthesis |

### Gate-Level Simulation

Gate-level simulation (GLS) runs the synthesized `kronos_top` netlist under
xsim against the same stage-5 assembly tests used by the Verilator RTL flow.
This catches synthesis-induced regressions that 2-state Verilator hides —
X-propagation, retiming-induced semantic drift, DSP/BRAM inference bugs,
and (with SDF) reset glitches and races at real cell delays.

The flow synthesizes `kronos_top` **out-of-context** so the AXI ports stay
on the netlist boundary, then drives the netlist from a SystemVerilog
testbench (`tb/gls/tb_gls_top.sv`) backed by a pure-SV AXI memory model
(`tb/gls/axi_mem_model.sv`) that mirrors `sim/sim_main.cpp`'s semantics.

Two phases:

- **Phase A — funcsim** (`make gls-funcsim`): zero-delay post-synth netlist,
  8-test stage-5 smoke subset (integer / M / branches / FP / icache / dcache
  / CSR). First run ~10–15 min (Vivado OOC synth + xsim); subsequent runs
  without RTL changes ~2–5 min (cached netlist via stamp file).
- **Phase B — SDF timing sim** (`make gls-sdf`): post-route netlist with
  back-annotated SDF, single smoke test (`test_blt64`). First run ~30–45 min
  (P&R adds ~25 min); SDF makes xsim ~5–10× slower than funcsim.

Pass criterion: store of `x10 == 0` to the `0x4000_0000`–`0x7FFF_FFFF`
sentinel region, identical to the Verilator flow. Logs land in
`build/gls/logs/<test>.<mode>.log`.

GLS is **not run in CI** — Vivado is too heavy for the existing GitHub
Actions matrix. Run locally before merging changes that touch the RTL.

## ACT4 compliance

All five completed stages pass the official
[`riscv-arch-test`](https://github.com/riscv-non-isa/riscv-arch-test) (ACT4)
suite, tracked as a git submodule at `riscv-arch-test/`.

| Stage   | Config                       | Tests   |
|---------|------------------------------|---------|
| s1      | `kronos-rv32i`               | 46/46   |
| s2      | `kronos-rv32im`              | 54/54   |
| s3      | `kronos-rv32imc`             | 81/81   |
| s4      | `kronos-rv64imac`            | 104/104 |
| s5      | `kronos-rv64imafd`           | 303/303 |
| s6      | `kronos-rv64imafdc-priv`     | 307/307 (IMAFDC subset; no priv suite) |
| s6-priv | `kronos-rv64imafdc-priv`     | ≥333    (adds Sv/Svadu/PMPSm priv suites — UDB-driven; runs **nightly** in sim-nightly.yml, not on push) |

```bash
cd sim && make sim-arch-test-s1        # …-s2 …-s3 …-s4 …-s5 …-s6
cd sim && make sim-arch-test-s6-priv   # priv runner (CI uses pre-baked extensions.txt; no Ruby/UDB needed)
```

Each `sim-arch-test-s<N>` target regenerates ELFs via `uv run act …` (requires
the [Sail reference model](https://github.com/riscv/sail-riscv) with a
`sail_riscv_sim_timeout` wrapper on `$PATH`) and then runs every ELF through
the per-stage Verilator binary. Per-test limits live in
`sim/run_arch_test_s<N>.sh`:

- `SIM_MAX_CYCLES=5_000_000` — ≈4× the slowest observed test, override via env
- `timeout 60s` — wall-clock safety net under `run_tests.py`'s 5 min bound

## Verification

**Constrained-random verification:** A Python random-program generator
(`tools/crv/`) emits seven scenario classes that stress
microarchitectural corners (hazards, mul/div, memory ordering, FP,
FDIV/FSQRT, branches, traps).  Each test runs on Kronos and Sail; the
existing `tools/trace_diff.py` confirms architectural agreement.
PR-blocking smoke (`make sim-crv-coverage`) gates 100% functional
coverage across 84 bins (with 23 documented exclusions for
known-limitation paths); nightly `crv-deep` runs 50 seeds per scenario.
See `docs/superpowers/specs/2026-04-26-crv-harness-design.md`.

**Instruction cache:** A 16 KB, 4-way set-associative instruction cache
(`rtl/stage5/kronos_icache.sv`) sits between the fetch unit and the AXI4
master.  Tree-PLRU replacement, critical-word-first WRAP refill, FENCE.I
full invalidate.  AXI bus widened to 64-bit (data + address) as part of
this work.  See `docs/superpowers/specs/2026-04-26-icache-design.md`.

**Data cache:** A 16 KB, 4-way set-associative write-back / write-allocate
data cache (`rtl/stage5/kronos_dcache.sv`) replaces the LSU's role as AXI
master.  Tree-PLRU replacement, critical-word-first WRAP refill, INCR
writeback bursts.  AMO RMW, LR/SC reservation tracking, and `FENCE.I` →
full writeback + invalidate (Stage 5g) all live inside the cache; the LSU
is now a thin adapter (size mux + sign-extension + NaN-boxing).  See
`docs/superpowers/specs/2026-04-27-dcache-design.md` and
`docs/superpowers/specs/2026-04-27-stage5g-cleanup-design.md`.

## Continuous integration

`.github/workflows/sim.yml` runs on every push and PR:

- `sim-all` — Verilator lint, unit TBs, stage-4 regression
- `compliance-s{1..5}` — matrix job; installs Verilator, the official RISC-V
  GCC release, the Sail reference model and `uv`, then runs
  `make sim-arch-test-s<N>` for its stage. On failure, the per-stage
  `riscv-arch-test/work/*/logs` directory is uploaded as an artifact.

## Integration with OpenSoC

kronos-riscv is designed to plug into
[OpenSoC](https://github.com/vladdum/opensoc) as a git submodule at
`hw/ip/kronos_riscv`, replacing the Ibex core. Stages 0–2 use OBI and connect
via OpenSoC's existing `axi_from_mem` bridges. From Stage 3 onward the core
exposes native AXI4 master ports and connects directly to the AXI crossbar,
removing the need for the bridge.

## License

Copyright 2026 Vlad-Dumitru Popescu.
Licensed under the [Apache License, Version 2.0](LICENSE).
