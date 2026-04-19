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
| 6     | Out-of-order execution (BOOM style)             | RV64IMAFDС       | AXI4    | Planned     |

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
│   └── stage5/                # Stage 5 FPU unit + integration testbenches
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
├── riscv-arch-test/           # git submodule (official ACT4 compliance suite)
├── .github/workflows/sim.yml  # sim-all + compliance-s{1..5} matrix CI
├── tools/
│   └── coverage_gate.py       # LCOV line-coverage gate (≥95% threshold)
├── kronos_riscv.core          # FuseSoC core descriptor (active: stage5)
├── LICENSE
└── CLAUDE.md                  # Claude Code project instructions
```

## Documentation

See [`docs/architecture.md`](docs/architecture.md) for the full architecture reference covering all completed stages (0–5b).

## Building

Prerequisites: Verilator, FuseSoC, `riscv64-unknown-elf-gcc`.

```bash
# Lint (stage 5, default)
fusesoc --cores-root=. run --target=lint opensoc:ip:kronos_riscv

# Lint earlier stages
fusesoc --cores-root=. run --target=lint-s4 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s3 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s2 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s0 opensoc:ip:kronos_riscv

# Build simulators
cd sim && make build-s5   # stage 5 (RV64IMAFD, AXI4) — active
cd sim && make build-s4   # stage 4 (RV64IMAC, AXI4)
cd sim && make build-s3   # stage 3 (RV32IMC, AXI4)
cd sim && make build-s2   # stage 2 (RV32IM)
cd sim && make build-s1   # stage 1 (RV32I)

# Stage 5 FPU unit testbenches
cd sim && make sim-fpu-fmisc   # FSGNJ/FMIN/FMAX/FCLASS/CMP/FMV
cd sim && make sim-fpu-fcvt    # FCVT (int↔FP, S↔D)
cd sim && make sim-fpu-fadd    # FADD/FSUB (5-stage)
cd sim && make sim-fpu-fmul    # FMUL (4-stage)
cd sim && make sim-fpu-fma     # FMA (5-stage)
cd sim && make sim-fpu-fdiv-core   # FDIV radix-2 SRT core
cd sim && make sim-fpu-fsqrt-core  # FSQRT radix-2 SRT core
cd sim && make sim-fpu-iter    # FDIV/FSQRT wrapper (SoftFloat-verified)
cd sim && make sim-fpu-top-iter # iter integration in FPU top

# Stage 5 integration testbenches
cd sim && make sim-core-fp-basic       # basic FMV + FADD end-to-end
cd sim && make sim-core-fp-forwarding  # FMUL→FADD with forwarding

# Stage 5 full regression + coverage gate (≥95% line coverage)
cd sim && make sim-s5
cd sim && make sim-s5b    # Stage 5b FDIV/FSQRT assembly tests
cd sim && make coverage

# Stage 4 regression
cd sim && make sim-s4

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

Requires Vivado 2024.x and a KV260 board support package. The flow targets
`kronos_kv260_top` (a thin timing harness wrapping `kronos_top` with a Zynq PS
clock) at 200 MHz on the XCK26 -2LV speed grade.

```bash
# Full synthesis + place & route at 200 MHz
vivado -mode batch -source fpga/kv260/synth.tcl \
       -tclargs PULP_AXI_ROOT=/path/to/pulp/axi

# Override target frequency (e.g. timing sweep at 180 MHz)
vivado -mode batch -source fpga/kv260/synth.tcl \
       -tclargs SYNTH_FREQ_MHZ=180 PULP_AXI_ROOT=/path/to/pulp/axi
```

Reports land in `build/vivado_kv260/`:

| File | Contents |
|------|----------|
| `post_route_timing.txt` | WNS, TNS, worst path |
| `post_route_utilization.txt` | LUT / FF / DSP / BRAM counts |
| `post_synth_timing.txt` | Estimated WNS after synthesis |

The CI job (`.github/workflows/synth.yml`) runs this flow on a self-hosted
Vivado runner for every PR that touches `rtl/stage5/` and fails if post-route
WNS < −0.5 ns.

## ACT4 compliance

All five completed stages pass the official
[`riscv-arch-test`](https://github.com/riscv-non-isa/riscv-arch-test) (ACT4)
suite, tracked as a git submodule at `riscv-arch-test/`.

| Stage | Config                | Tests   |
|-------|-----------------------|---------|
| s1    | `kronos-rv32i`        | 46/46   |
| s2    | `kronos-rv32im`       | 54/54   |
| s3    | `kronos-rv32imc`      | 81/81   |
| s4    | `kronos-rv64imac`     | 104/104 |
| s5    | `kronos-rv64imafd`    | 303/303 |

```bash
cd sim && make sim-arch-test-s1    # …-s2 …-s3 …-s4 …-s5
```

Each `sim-arch-test-s<N>` target regenerates ELFs via `uv run act …` (requires
the [Sail reference model](https://github.com/riscv/sail-riscv) with a
`sail_riscv_sim_timeout` wrapper on `$PATH`) and then runs every ELF through
the per-stage Verilator binary. Per-test limits live in
`sim/run_arch_test_s<N>.sh`:

- `SIM_MAX_CYCLES=5_000_000` — ≈4× the slowest observed test, override via env
- `timeout 60s` — wall-clock safety net under `run_tests.py`'s 5 min bound

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
