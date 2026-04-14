# CLAUDE.md

This file provides guidance to Claude Code when working in the kronos-riscv repository.

## Project Overview

kronos-riscv is a RISC-V CPU core implemented in SystemVerilog, architecturally
inspired by the BOOM (Berkeley Out-of-Order Machine) microarchitecture. It is
developed as a standalone repository and integrated into OpenSoC as a git
submodule, replacing the Ibex core.

Development follows a staged learning progression:

| Stage | Description                          | ISA              | Status      |
|-------|--------------------------------------|------------------|-------------|
| 0     | Single-cycle golden model            | RV32I            | Complete    |
| 1     | 5-stage in-order pipeline            | RV32I            | In progress |
| 2     | M extension + CSR hardening          | RV32IM           | Planned     |
| 3     | C extension + branch predictor       | RV32IMC          | Planned     |
| 4     | RV64I + A extension                  | RV64IMAC         | Planned     |
| 5     | F/D extensions (floating point)      | RV64IMAFDС       | Planned     |
| 6     | Out-of-order execution (BOOM style)  | RV64IMAFDС       | Planned     |

## Repository Structure

```
kronos-riscv/
├── rtl/
│   ├── kronos_pkg.sv          # Shared enums, structs, types
│   └── stage0/                # Stage 0: single-cycle golden model
├── tb/
│   ├── tb_pkg.sv              # Shared testbench tasks
│   └── stage0/                # Stage 0 testbenches
├── sw/
│   └── stage0/                # Stage 0 test programs (assembly)
├── sim/
│   ├── Makefile               # Verilator build and run
│   └── sim_main.cpp           # C++ simulation driver (OBI memory model)
├── docs/
│   └── superpowers/           # Design specs and plans (gitignored)
└── kronos_riscv.core          # FuseSoC core descriptor
```

## Bus Interface

**Stages 0–5:** OBI (Open Bus Interface) — req/gnt/rvalid handshake, one
outstanding transaction per port. Two ports: instruction fetch (read-only) and
data (read/write).

**Stage 6:** Native AXI4 — the OOO LSU needs multiple outstanding requests.
The core will connect directly to the OpenSoC AXI crossbar at that stage.

## Build Commands

All builds use FuseSoC and Verilator running under WSL/Linux.

```bash
# Lint RTL
fusesoc --cores-root=. run --target=lint opensoc:ip:kronos_riscv

# Build simulator (from sim/ directory)
cd sim && make build

# Run a specific test
cd sim && make run-<test_name>

# Run all unit tests
cd sim && make sim-alu
cd sim && make sim-decode
cd sim && make sim-regfile
```

## Toolchain

- SystemVerilog compiler/linter: Verilator
- RISC-V compiler: `riscv64-unknown-elf-gcc`
  - RV32I programs: `-march=rv32i -mabi=ilp32`
  - RV64 programs (Stage 4+): `-march=rv64imac -mabi=lp64`
- Compliance tests: `riscv-arch-test` (gitignored, clone separately)

## Stage Development Rules

- Each stage lives in its own subdirectory under `rtl/stage<N>/` and `tb/stage<N>/`
- Every stage must expose the same top-level module name: `kronos_top`
- The `kronos_riscv.core` file points to the **active** stage's files
- All existing test programs must pass before a stage is considered complete
- Run the `riscv-arch-test` compliance suite before closing a stage

## Testing Strategy

- Unit testbenches: one per RTL module (tb/stage0/tb_alu.sv, etc.)
- Integration: `sim/sim_main.cpp` (C++ Verilator driver) runs assembly programs via the OBI memory model
- Self-checking assembly: test programs store failure count in x10; x10=0 = pass
- Golden model diffing: from Stage 1 onward, diff register state against Stage 0

## Worktrees

Agent worktrees under `.claude/worktrees/` must be removed once the task is complete. Do not leave stale worktrees behind.

Before removing a worktree:
1. Check for uncommitted changes: `git -C .claude/worktrees/<name> status`
2. Check for unpushed commits: `git -C .claude/worktrees/<name> log --oneline origin/main..HEAD`
3. If there are changes worth keeping, commit or cherry-pick them to the appropriate branch first.
4. Then remove the worktree:

```bash
git worktree remove .claude/worktrees/<name>
```

If the worktree has changes that should be discarded, use `--force`.

## Waveforms

Use WaveDrom for all timing diagrams in documentation. Embed diagrams as fenced
code blocks with the `wavedrom` language tag — they render on GitHub and in most
documentation tools without any extra setup:

````markdown
```wavedrom
{ "signal": [
  { "name": "clk", "wave": "P..." },
  { "name": "req", "wave": "0100" }
]}
```
````

Do not use ASCII art timing diagrams.

## Documentation Upkeep

After completing each implementation step:

1. **Update `README.md`** — reflect the current state of the project:
   - Update the stage table (mark the active stage, tick completed substeps)
   - Update build instructions if commands changed
   - Update the repository structure if new files/directories were added

2. **Update the design spec** (`docs/superpowers/specs/2026-04-08-boom-sv-core-design.md`) — keep it accurate as the implementation reveals details that differ from the original design:
   - Correct any interface or signal names that changed
   - Note decisions made during implementation that deviate from the spec
   - Mark completed stages/sections

Both files should always reflect the current state of the code, not the original plan.

## SW Tests

When creating a new test under `sw/stage<N>/`, add it to the stage's `Makefile` TESTS list.

Naming convention: use underscores in directory/file names, hyphens in make targets
(e.g. `test_load_store.S` → target `run-test_load-store`).

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

Commit message convention: `type(scope): description`
- Types: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`
- Scopes: `alu`, `decode`, `regfile`, `lsu`, `csr`, `top`, `sim`, `sw`, `pkg`

## Branch Workflow

One branch per stage. Open it when you start, commit freely during development,
squash to a single commit when the stage is done, then merge to `main` via PR.

Direct pushes to `main` are blocked — all changes must go through a pull request.

```bash
# 1. Open a stage branch
git checkout -b stage3

# 2. Develop freely — granular commits are fine on the branch

# 3. Pick up any commits that landed on main while you worked
git pull --rebase --autostash origin main

# 4. Squash all branch commits into one
git reset --soft origin/main
git commit -m "feat(stage3): C extension + branch predictor"

# 5. Open a pull request and merge
git push -u origin stage3
# Then open a PR on GitHub; merge via squash merge to main
git checkout main
git pull origin main
git branch -d stage3
```

`main` always has exactly one commit per completed stage, plus the skeleton and docs
commits. Use squash merge on GitHub PRs.

Do not include any reference to Claude or AI tools in commit messages
(no `🤖 Generated with Claude Code`, no `Co-Authored-By`, no similar footers).

## SystemVerilog Coding Guidelines

### General Style

- Indent with 2 spaces. No tabs.
- Line length: 100 characters maximum.
- One module per file. File name matches module name (`kronos_alu.sv` → `module kronos_alu`).
- Every file starts with the Apache 2.0 license header:

```systemverilog
// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
```

### Naming Conventions

| Kind | Convention | Example |
|------|-----------|---------|
| Module | `snake_case` | `kronos_alu` |
| Instance | `u_<module>` | `u_alu`, `u_regfile` |
| Package | `snake_case_pkg` | `kronos_pkg` |
| Type/enum/struct | `snake_case_t` / `snake_case_e` | `decoded_instr_t`, `alu_op_e` |
| Input port | `_i` suffix | `clk_i`, `rst_ni` |
| Output port | `_o` suffix | `result_o`, `req_o` |
| Active-low signal | `_n` suffix | `rst_ni`, `gnt_n` |
| Internal signal | plain `snake_case` | `pc_next`, `alu_result` |
| Parameter/localparam | `UPPER_SNAKE_CASE` | `DATA_WIDTH`, `OP_ADD` |
| Generate block | `gen_<description>` | `gen_flops` |

### Always Blocks

- Use `always_ff` for registers (sequential logic). Never use `always @(posedge clk)`.
- Use `always_comb` for combinational logic. Never use `always @(*)`.
- Never use `always_latch` — if a latch appears, it is a bug.
- Each `always_ff` block drives exactly one group of related registers.
- Reset is active-low and asynchronous: `always_ff @(posedge clk_i or negedge rst_ni)`.

```systemverilog
// Correct
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) q <= '0;
  else         q <= d;
end

// Correct
always_comb begin
  result = a + b;
end
```

### Combinational Logic

- Use `unique case` (not `case`) — it enables lint checks for full coverage and mutual exclusivity.
- Always include a `default` branch in every `case` statement.
- Do not use `casex` or `casez` — use explicit don't-care masks instead.
- Assign all outputs of an `always_comb` block at the top (defaults), then override in branches. This prevents unintended latches.

```systemverilog
// Correct: default first, then overrides
always_comb begin
  out = '0;           // default
  unique case (sel)
    2'b00: out = a;
    2'b01: out = b;
    2'b10: out = c;
    default: out = '0;
  endcase
end
```

### Types and Signals

- Declare all signals as `logic`. Do not use `wire` or `reg`.
- Use packed structs and enums from `kronos_pkg` rather than raw bit vectors where it aids readability.
- Avoid implicit net declarations — every signal must be explicitly declared.
- Use `'0` and `'1` for zero/all-ones literals (width-agnostic). Use explicit widths for constants that have a specific meaning (e.g. `32'hDEAD_BEEF`).
- Use underscores in long literals for readability: `32'hDEAD_BEEF`, `16'b1010_0101_1111_0000`.

### Signal Declaration Order

Declare all signals at the top of the module, after the port list and before any `always` blocks or instantiations. Group them in this order:

1. `localparam` / `parameter` constants
2. Imported type instances (structs, enums from `kronos_pkg`)
3. State registers (signals driven by `always_ff`)
4. Combinational signals (signals driven by `always_comb` or `assign`)
5. Submodule interface signals (inputs/outputs to instances)

Exception: signals local to a `generate` block may be declared inside it.

```systemverilog
module kronos_example
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [31:0] data_i,
  output logic [31:0] data_o
);
  // 1. Constants
  localparam int unsigned DEPTH = 4;

  // 2. Structs / enums
  decoded_instr_t dec;

  // 3. State registers
  logic [31:0] count_q;

  // 4. Combinational signals
  logic [31:0] count_next;
  logic        overflow;

  // 5. Submodule interface signals
  logic [31:0] sub_result;

  // --- logic below ---
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) count_q <= '0;
    else         count_q <= count_next;
  end

  assign count_next = count_q + 32'd1;
  assign overflow   = (count_q == '1);
  assign data_o     = sub_result;

endmodule
```

### Module Ports

- Always use the ANSI port declaration style (types in the port list, not separate).
- Group ports: clocks/resets first, then functional inputs, then outputs, then interfaces.
- One port per line.

```systemverilog
module kronos_alu
  import kronos_pkg::*;
(
  input  alu_op_e     op_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] result_o
);
```

### Clocking and Reset

- Single clock domain: `clk_i` (rising edge).
- Single active-low asynchronous reset: `rst_ni`.
- Do not instantiate clock buffers or reset synchronizers inside IP modules — that is the top-level's responsibility.
- Do not use `initial` blocks in synthesisable RTL.

### Lint Cleanliness

- All RTL must pass Verilator lint with `--Wall --Wno-UNUSED` before committing.
- No undriven outputs, no implicit truncations, no width mismatches.
- If a port is intentionally unconnected at the instantiation site, tie it explicitly: `()` for outputs, `'0` for inputs.
- Avoid `$display`, `$finish`, `$readmemh` in synthesisable RTL — testbench only.

### Packages and Imports

- Shared types live in `rtl/kronos_pkg.sv`. Do not duplicate type definitions across files.
- Import packages at the module level with `import kronos_pkg::*;` — do not use the `::` scope operator inline in port lists or always blocks.
- Do not create per-stage packages; `kronos_pkg` is the single shared package across all stages.

### Hierarchy and Instantiation

- Flat, shallow hierarchy preferred. Avoid more than 3 levels of nesting within a stage.
- Always use named port connections (`.port_name(signal)`). Never use positional connections.
- Instantiation name: `u_<module_without_prefix>` (e.g. `kronos_alu` → `u_alu`).

### Arithmetic and Widths

- Be explicit about signed vs unsigned: use `$signed()` cast when signed arithmetic is intended.
- Right-shifts on signed values must use `$signed()` to get arithmetic shift: `$signed(a) >>> b`.
- Concatenations must have explicit widths on all operands.
- When extending a value, be explicit: `{{24{byte[7]}}, byte}` not `{byte}`.

## OpenSoC Integration

The parent project is at `/home/popes/opensoc`. kronos-riscv is added as a
submodule at `hw/ip/kronos_riscv`. When updating the submodule pointer:

```bash
cd /home/popes/opensoc
git submodule update --remote hw/ip/kronos_riscv
git add hw/ip/kronos_riscv
git commit -m "chore: update kronos-riscv submodule"
```
