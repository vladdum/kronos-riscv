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
| 5     | F/D extensions (floating point)                 | RV64IMAFDС       | AXI4    | Planned     |
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
│   └── stage4/                # Stage 4: RV64I + A extension
│       ├── kronos_alu.sv      # 64-bit ALU with W-suffix (ADDW/SUBW/…)
│       ├── kronos_decode.sv   # RV64IMAC decoder
│       ├── kronos_decompress.sv # RV64C 16-bit → 32-bit instruction expander
│       ├── kronos_muldiv.sv   # 64-bit multiply/divide unit
│       ├── kronos_lsu.sv      # AXI4 LSU with LR/SC reservation + AMO RMW
│       ├── kronos_csr.sv      # 64-bit CSR file (mstatus.SXL/UXL = 2)
│       └── kronos_top.sv      # Stage4 pipeline top
├── tb/
│   ├── tb_pkg.sv              # Shared testbench utilities
│   ├── stage0/                # Stage 0 testbenches
│   ├── stage1/                # Stage 1 unit testbenches
│   ├── stage2/                # Stage 2 unit testbenches
│   ├── stage3/                # Stage 3 unit testbenches
│   └── stage4/                # Stage 4 unit testbenches
├── sw/
│   ├── stage0/                # Stage 0 test programs (RISC-V assembly)
│   ├── stage1/                # Stage 1 hazard-focused test programs
│   ├── stage2/                # Stage 2 M-extension test programs
│   ├── stage3/                # Stage 3 test programs
│   └── stage4/                # Stage 4 test programs (RV64IMAC)
├── sim/
│   ├── Makefile               # Verilator build and run targets
│   └── sim_main.cpp           # C++ simulation driver
├── kronos_riscv.core          # FuseSoC core descriptor (active: stage4)
├── LICENSE
└── CLAUDE.md                  # Claude Code project instructions
```

## Documentation

| Document | Audience | Description |
|----------|----------|-------------|
| [docs/stage0.md](docs/stage0.md) | Learners | Single-cycle golden model — fetch/decode/execute/writeback |
| [docs/stage1.md](docs/stage1.md) | Learners | 5-stage pipeline — hazards, forwarding, stall/flush |
| [docs/stage2.md](docs/stage2.md) | Learners | M extension — multi-cycle multiply/divide unit |
| [docs/architecture.md](docs/architecture.md) | Advanced | Signal-level reference — interfaces, structs, timing, CSR map |

## Building

Prerequisites: Verilator, FuseSoC, `riscv64-unknown-elf-gcc`.

```bash
# Lint (stage 4, default)
fusesoc --cores-root=. run --target=lint opensoc:ip:kronos_riscv

# Lint earlier stages
fusesoc --cores-root=. run --target=lint-s3 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s2 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s1 opensoc:ip:kronos_riscv
fusesoc --cores-root=. run --target=lint-s0 opensoc:ip:kronos_riscv

# Build simulators
cd sim && make build-s4   # stage 4 (RV64IMAC, AXI4) — active
cd sim && make build-s3   # stage 3 (RV32IMC, AXI4)
cd sim && make build-s2   # stage 2 (RV32IM)
cd sim && make build-s1   # stage 1 (RV32I)

# Run stage 4 tests
cd sim && make run-s4-test_rv64i_basic
cd sim && make run-s4-test_word_ops
cd sim && make run-s4-test_64bit_loadstore
cd sim && make run-s4-test_atomic

# Stage 4 regression (all stages 0–4, ISA-compatible tests)
cd sim && make sim-compliance-s4

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
