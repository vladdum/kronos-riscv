# CLAUDE.md

This file provides guidance to Claude Code when working in the kronos-riscv repository.

## Project Overview

kronos-riscv is a RISC-V CPU core implemented in SystemVerilog, architecturally
inspired by the BOOM (Berkeley Out-of-Order Machine) microarchitecture. It is
developed as a standalone repository and integrated into OpenSoC as a git
submodule, replacing the Ibex core.

Development follows a staged learning progression:

| Stage | Description                                     | ISA              | Bus  | Status   |
|-------|-------------------------------------------------|------------------|------|----------|
| 0     | Single-cycle golden model                       | RV32I            | OBI  | Complete |
| 1     | 5-stage in-order pipeline                       | RV32I            | OBI  | Complete |
| 2     | M extension + CSR hardening                     | RV32IM           | OBI  | Complete |
| 3     | AXI4 switch + C extension + branch predictor    | RV32IMC          | AXI4 | Complete |
| 4     | RV64I + A extension                             | RV64IMAC         | AXI4 | Complete |
| 5a    | F/D extensions (pipelined, no FDIV/FSQRT)       | RV64IMAFD        | AXI4 | Complete |
| 5b    | FDIV/FSQRT (iterative SRT)                      | RV64IMAFDC       | AXI4 | Complete |
| 6a    | Privileged modes (M/S/U) + trap delegation + PMP | RV64IMAFDC      | AXI4 | Complete |
| 6b    | Sv39/Sv48 MMU + iTLB/dTLB + HW PTW + sfence.vma | RV64IMAFDC       | AXI4 | Complete |
| 6c    | Closeout: dhrystone perf gate, integration program, mstatus reset, GLS-s6 docs | RV64IMAFDC | AXI4 | Complete |
| 6d    | RAM wrapper infrastructure (`kronos_ram` SDP, FPGA `xpm` + ASIC stub) | RV64IMAFDC | AXI4 | Complete |
| 6e    | PMA layer for MMIO bypass (parameterised non-cacheable regions in `kronos_dcache`) | RV64IMAFDC | AXI4 | Complete |
| 6f    | BOOM-style frontend rewrite + icache `data_q` BRAM-back | RV64IMAFDC | AXI4 | Complete |
| 6g    | Dcache `data_q` BRAM-back (4 × `kronos_ram`, EX-stage pre-launch) | RV64IMAFDC | AXI4 | Complete |
| 6h    | Cache tag arrays + FP regfile in BRAM/LUTRAM (closes #79)        | RV64IMAFDC | AXI4 | Complete |
| 6i    | Verification overhaul: dcache RAW regression + CRV-s6 + cosim fuzzer | RV64IMAFDC | AXI4 | Complete |
| 7a    | BOOM-style fault-bit propagation + EX1/EX2 split (in-order Fmax push) | RV64IMAFDC | AXI4 | Complete |
| 7b    | RR (register-read) stage + bypass network rebuild               | RV64IMAFDC | AXI4 | Complete |
| 7c    | MEM1/MEM2 split (dTLB/PMP separated from dcache hit)            | RV64IMAFDC | AXI4 | Complete |
| 7d    | *(Stretch)* MEM1B PMP retime + FWD_MEM2 load suppression + trap_vector retime (RTL-only; Pblock floorplan deferred) | RV64IMAFDC | AXI4 | Complete (RTL) |
| 7e    | Stall-network retime (event_bus register) + dTLB pipeline split | RV64IMAFDC | AXI4 | In progress |
| 8     | Out-of-order execution (BOOM-class rename + ROB + IQ + LSU)     | RV64IMAFDC | AXI4 | Planned  |

All completed stage configurations pass the full `riscv-arch-test` (ACT4)
compliance suite. See *ACT4 compliance* below.

## Repository Structure

See `README.md` for the full tree. In brief:

```
kronos-riscv/
├── rtl/{kronos_pkg.sv, stage0/ … stage5/}   # per-stage RTL + shared pkg
├── tb/{tb_pkg.sv, stage0/ … stage5/}        # per-stage testbenches
├── sw/{stage0/ … stage5b/}                  # RISC-V assembly tests
├── sim/
│   ├── Makefile                             # Verilator build + test targets
│   ├── sim_main.cpp / sim_main_obi.cpp      # AXI4 / OBI memory models
│   ├── run_arch_test_s{1..5}.sh             # ACT4 per-test runner (+ timeout)
│   └── obj_dir/                             # build artifacts
├── riscv-arch-test/                         # git submodule (ACT4)
├── .github/workflows/sim.yml                # sim-all + compliance matrix CI
├── docs/                                    # specs (gitignored content)
└── kronos_riscv.core                        # FuseSoC core descriptor
```

## Documentation Ownership

| Document | Owns |
|---|---|
| `docs/architecture.md` | The **current** machine: pipeline, hazards, memory subsystem, FPU, privilege/MMU, CSR map, timing, counters. One design-evolution table (§1) is the only stage-keyed content. |
| `docs/testplan.md` | Verification truth: per-stage coverage, gates (GLS table moves here), CRV, how-to-add-a-test. |
| `README.md` | Build/run/compliance/status: stage table (the single source of stage numbering), ACT4, FPGA flow. |
| Master spec + per-stage specs | Design intent and history; the master spec gains a dated **amendment log** and is never silently edited. |

A stage-closing PR is not done until every document its changes falsified
is true again — the same rule `docs/testplan.md` already states for tests,
extended to all four documents. Stage numbers appear in exactly three
places: the README's Staged Development table (the single source of stage
numbering), `docs/architecture.md` §1, and `docs/testplan.md` section
headers. All other prose cites the reason for a design choice (the failure
it prevents), never the stage that introduced it.

## Bus Interface

**Stages 0–2:** OBI (Open Bus Interface) — req/gnt/rvalid handshake, one
outstanding transaction per port. Two ports: instruction fetch (read-only) and
data (read/write).

**Stages 3–5:** Native AXI4 — single-outstanding AXI4 master ports (one
in-flight transaction per channel), instruction and data on separate ports.

**Stage 6:** Native AXI4 with multiple outstanding IDs — the OOO LSU issues
multiple in-flight memory requests with tagged, out-of-order responses.

## Build Commands

All builds use FuseSoC and Verilator running under WSL/Linux.

```bash
# Lint RTL (canonical flow — `make lint-rtl-s*` from sim/, UNOPTFLAT enabled)
cd sim && make lint-rtl-all     # all stages
cd sim && make lint-rtl-s6      # one stage

# Build per-stage simulators (from sim/)
cd sim && make build-s1   # RV32I
cd sim && make build-s2   # RV32IM
cd sim && make build-s3   # RV32IMC + AXI4
cd sim && make build-s4   # RV64IMAC
cd sim && make build-s5   # RV64IMAFD

# Full parallel regression (unit TBs + stage-4 assembly tests)
cd sim && make sim-all

# ACT4 compliance (see section below)
cd sim && make sim-arch-test-s1   # through -s5
```

## Toolchain

- SystemVerilog compiler/linter: Verilator
- RISC-V compiler: `riscv64-unknown-elf-gcc`
  - RV32I programs: `-march=rv32i -mabi=ilp32`
  - RV64 programs (Stage 4+): `-march=rv64imac -mabi=lp64`
- Compliance tests: `riscv-arch-test` — tracked as a git submodule at
  `riscv-arch-test/`. ELF generation requires `uv` and the Sail reference
  model (`sail_riscv_sim` plus the `sail_riscv_sim_timeout` wrapper).

## Stage Development Rules

- Each stage lives in its own subdirectory under `rtl/stage<N>/` and `tb/stage<N>/`
- Every stage must expose the same top-level module name: `kronos_top`
- The `kronos_riscv.core` file points to the **active** stage's files
- All existing test programs must pass before a stage is considered complete
- Run the `riscv-arch-test` compliance suite before closing a stage

## Testing Strategy

- Unit testbenches: one per RTL module (tb/stage0/tb_alu.sv, etc.)
- Integration: `sim/sim_main.cpp` (AXI4) and `sim/sim_main_obi.cpp` (OBI) —
  C++ Verilator drivers run assembly programs via the appropriate memory model
- Self-checking assembly: test programs store failure count in x10; x10=0 = pass
- Golden model diffing: from Stage 1 onward, diff register state against Stage 0
- ACT4 compliance: every stage passes the official `riscv-arch-test` suite
  (see *ACT4 compliance* below)

## ACT4 compliance

The `riscv-arch-test` submodule is built and run via `sim/Makefile`:

```bash
cd sim && make sim-arch-test-s1        # 46 tests   (RV32I)
cd sim && make sim-arch-test-s2        # 54 tests   (RV32IM)
cd sim && make sim-arch-test-s3        # 81 tests   (RV32IMC)
cd sim && make sim-arch-test-s4        # 104 tests  (RV64IMAC)
cd sim && make sim-arch-test-s5        # 303 tests  (RV64IMAFDC)
cd sim && make sim-arch-test-s6        # 307 tests  (RV64IMAFDC, no priv suite)
cd sim && make sim-arch-test-s6-priv   # ≥333 tests (adds Sv/Svadu/PMPSm priv suites; UDB-driven)
```

Stage 6 has two ACT4 targets: `sim-arch-test-s6` keeps the IMAFDC baseline
(no UDB tooling needed locally; gated on every push by `compliance-s6` in
`sim.yml`); `sim-arch-test-s6-priv` adds the privileged-spec sub-suites
(`Sv`, `Svade`, `Svadu`, `Svbare`, `SvPMP`, `SvaduPMP`, `PMPSm`, `PMPZca`,
`PMPmisaligned`) using a pre-baked `extensions.txt` so UDB regen is
skipped. The priv runner is heavier (~5–10 min, Sail simulates Sv
edge-cases slowly) and runs **nightly** via `compliance-s6-priv` in
`sim-nightly.yml` plus `workflow_dispatch` for manual triggers. Failures
auto-open a tracking issue.

Each target calls `uv run act …` to regenerate ELFs (needs `sail_riscv_sim`
on PATH) and then `run_tests.py` to execute them.

Per-test timeouts are enforced by `sim/run_arch_test_s<N>.sh`:
- `SIM_MAX_CYCLES=5000000` (override via env) — ≈4× the slowest observed test
- Wall-clock `timeout 60s` — safety net under `run_tests.py`'s 5-minute bound

The same targets run as a matrix job in `.github/workflows/sim.yml`
(`compliance-s1` … `compliance-s5`).  On failure, logs from
`riscv-arch-test/work/*/logs` are uploaded as a GitHub Actions artifact.

## Debugging Simulations

When debugging, always enable verbose simulation output from the start rather than running a plain simulation first. Use the appropriate environment variables:

```bash
# Stage 5 (AXI, sim_main.cpp):
SIM_DEBUG=1 SIM_PC_RANGE=<lo_hex>-<hi_hex> ./sim/obj_dir/s5/Vsim_top <hex> [instr_lat] [data_lat]

# ACT4 compliance runner (sim_main_obi.cpp) — set SIM_DEBUG in the shell before running make:
SIM_DEBUG=1 make run-s5-<test>
```

Never run a simulation twice in a row just to get different output — set the debug flags before the first run.

## Subagent Models

The main conversation (brainstorming, plan writing, orchestration) runs on the session model — never downgrade it.

When dispatching subagents, always set the `model` parameter on the Agent call:

- Implementation / execution subagents (task implementers, test writers, fix-up agents): `model: "sonnet"`.
- Exploration and search subagents (Explore, codebase lookups): `model: "sonnet"`.
- Code-review, spec-review, and plan-review subagents: omit the `model` parameter so they inherit the main-session model.

Do not set `CLAUDE_CODE_SUBAGENT_MODEL` in settings — it would override the per-dispatch routing above.

## Development Loop

Stage implementation and debug follow this loop:

1. **Brainstorm → spec → plan** (superpowers:brainstorming, vlad:spec-review against the master design spec, superpowers:writing-plans at full-runnable-code depth). Stop for user review after the spec and after the plan.
2. **Execute with superpowers:subagent-driven-development**: fresh implementer subagent per task (sonnet, per Subagent Models above), task briefs extracted to files, TDD with *observed* fail-then-pass evidence quoted in a per-task report file.
3. **Independent review after every task** (main-session model): spec compliance AND code quality, with the reviewer given the brief, the report, and the full diff as files. Findings enter scoped fix rounds (fix → scoped re-review), never silent discards; minors go to the ledger.
4. **Ledger everything** in `.superpowers/sdd/<plan>/progress.md`: completions, fix rounds, deferred minors, carry-overs between tasks, and user decisions. The ledger survives context loss; trust it and `git log` over recollection.
5. **Synthesis gates**: for any stage with Fmax or resource goals, re-synthesize after RTL-touching tasks. On a timing miss: analyze failing-path classes first, try zero-RTL directive escalation before RTL changes, and make every RTL timing fix behavior-identical and sim-gated.
6. **Final whole-branch review** (most capable model) with the ledger's deferred-minors list for merge triage; ONE fix wave + one scoped re-review.
7. **Hardware last**: the full sim regression, ACT4, and `make ci-local` must be green before any FPGA or GLS run, and every hardware scenario must already have an equivalent simulation twin at the same scale (same program, iteration, and loop counts). Run the stage-transition gates (GLS) before tagging a stage complete.
8. **Update the checked-in documentation as part of closing the work** — a change is not done until the docs that describe it are true again (see Documentation Upkeep below). This is a closing step, not an optional follow-up.

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

## Diagrams

Two diagram tools, chosen by kind:

- **Block diagrams, FSMs, dataflow**: inline Mermaid fenced code blocks
  (` ```mermaid `) directly in the markdown — GitHub renders them natively,
  no build step. Do not add pre-rendered SVGs or ASCII art for these.
- **Timing/waveform diagrams**: WaveDrom JSON sources in
  `docs/diagrams/src/wf-*.json`, rendered to SVG via `make -C docs/diagrams`
  and embedded as images. Mermaid has no timing-diagram type, so waveforms
  stay on this pipeline.

Do not use ASCII art diagrams of either kind.

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

## CI gates

### Branch protection — repository setting

`main` should have a branch protection rule that **requires all PR-blocking CI
checks to pass before merge can be enabled.** Configure once under `Settings ->
Branches -> Add rule for main -> Require status checks to pass before merging`,
and tick every job in `.github/workflows/sim.yml` (compliance-s1..s6,
sim-s5-asm, sim-s6-asm, sim-s6b-asm, sim-fp-top, sim-fp-unit, sim-diff-s5,
sim-diff-s5-traced, sim-crv-smoke, dcache-stress-s6, crv-smoke-s6,
cosim-smoke, perf-baseline-s6, sim-s1s2, sim-s3s4, sim-s5-int, sim-s6-int,
pytest, sim-all). With this enabled, the GitHub merge button is disabled
whenever any of those checks is failing — the human reviewer cannot merge
red.

### Local CI verification — `make ci-local`

Before pushing a PR branch, run `make ci-local` from `sim/`. It runs the full
PR-gating set against the **same toolchain CI uses** (apt
`gcc-riscv64-unknown-elf 13.2.x` at `/usr/bin/`, not the user's local
toolchain) so any failure that would be exposed in CI surfaces locally first.
Push only when this is clean.

### Hard rule — never bypass a failing CI gate

**HARD RULE — never bypass a failing CI gate to enable a PR merge.** This applies
to every agent and every contributor:

- Do **not** add `continue-on-error: true`, `if: false`, or any equivalent gate
  bypass to a CI job that has been deliberately failing because it found a bug.
- Do **not** add a "skip list" / "exclude list" / `KNOWN_FAILURES` mechanism
  whose purpose is to remove failing tests from a gating job. Tests that are
  failing for a real reason must stay in the gate so the PR stays red until the
  underlying bug is fixed.
- Do **not** rename a failing job to `*-informational`, push it to `nightly`,
  or otherwise hide its red signal so the PR-blocking gate goes green.
- Do **not** mark a real failure as `xfail` / "expected to fail" without an
  explicit, documented platform / config exception (e.g. `if-only` matrix gating
  for a known-broken host). The bar for adding such exceptions is high and they
  must reference a tracking issue.

The verification stack exists to catch bugs. A green gate that hides a real
failure is worse than a red gate that exposes it: it tells maintainers the
codebase is healthy when it isn't, and it lets the bug ship.

The correct response to a failing gate is one of:
1. **Fix the underlying bug** so the test passes naturally.
2. **Repair the test** if the test itself is wrong (reproducer is incorrect,
   harness is brittle, etc.).
3. **Wait** — leave the gate red and the PR un-mergeable until 1 or 2 happens.

Filing a tracking issue is necessary but not sufficient. The gate must stay
red until the fix lands.

## SW Tests

When creating a new test under `sw/stage<N>/`, add it to the stage's `Makefile` TESTS list.

Naming convention: use underscores in directory/file names, hyphens in make targets
(e.g. `test_load_store.S` → target `run-test_load-store`).

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

Commit message convention: `type(scope): description`
- Types: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`
- Scopes: `alu`, `decode`, `regfile`, `lsu`, `csr`, `top`, `sim`, `sw`, `pkg`

## Pull Requests

Do not include any reference to Claude or AI tools in PR titles, bodies, or descriptions
(no `🤖 Generated with Claude Code`, no `Co-Authored-By`, no similar footers).

Before creating any PR:

1. Squash all commits on the branch into a single commit.
2. Rebase on main:

```bash
git pull --rebase --autostash origin main
```

When merging, delete the branch:

```bash
gh pr merge --delete-branch
```

## Branch Workflow

One branch per stage. Open it when you start, commit freely during development,
then squash to a single commit and open a PR before merging.

Direct pushes to `main` are blocked — all changes must go through a pull request.

```bash
# 1. Open a stage branch
git checkout -b stage3

# 2. Develop freely — granular commits are fine on the branch

# 3. Squash all branch commits into one
git reset --soft origin/main
git commit -m "feat(stage3): C extension + branch predictor"

# 4. Rebase on main
git pull --rebase --autostash origin main

# 5. Open a pull request
git push -u origin stage3
gh pr create --title "feat(stage3): C extension + branch predictor" --body "..."

# 6. Merge and delete the branch
gh pr merge --delete-branch
```

`main` always has exactly one commit per completed stage, plus the skeleton and docs
commits.

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
  if (!rst_ni) q <= 32'h0;     // explicit width — q is 32-bit
  else         q <= d;
end

// Correct
always_comb begin
  result = a + b;
end
```

### Combinational Logic

- Use `unique case` (not `case`) inside `always_ff` and `always_comb` blocks — it enables lint checks for full coverage and mutual exclusivity. Inside `function automatic` bodies, plain `case` with an explicit `default` is preferred (the `unique` annotation gates lint checks that are less load-bearing when the function returns a value).
- Always include a `default` branch in every `case` statement.
- Do not use `casex` or `casez` — use explicit don't-care masks instead.
- Assign all outputs of an `always_comb` block at the top (defaults), then override in branches. This prevents unintended latches.
- **`if` / `else` bodies on a separate line must use `begin` / `end`.** Single-line bodies (`if (cond) stmt;`) and the reset idiom (`if (!rst_ni) q <= 32'h0; else q <= ...;`) are exempt. The rule prevents the dangling-statement footgun: a future edit that adds a second body line would silently fall outside the `if`.

```systemverilog
// BAD — multi-line if without begin/end
if (fmt_d_q)
  result = double_path;
else
  result = single_path;

// GOOD — wrapped
if (fmt_d_q) begin
  result = double_path;
end else begin
  result = single_path;
end

// GOOD — one-liner exemption
if (cond) flag = 1'b1;

// GOOD — reset idiom exemption
if (!rst_ni) q <= 32'h0;
else         q <= d;
```

```systemverilog
// Correct: default first, then overrides
always_comb begin
  out = 32'h0;        // default — explicit width matches `out`
  unique case (sel)
    2'b00: out = a;
    2'b01: out = b;
    2'b10: out = c;
    default: out = 32'h0;
  endcase
end
```

### Types and Signals

- Declare all signals as `logic`. Do not use `wire` or `reg`.
- Use packed structs and enums from `kronos_pkg` rather than raw bit vectors where it aids readability.
- Avoid implicit net declarations — every signal must be explicitly declared.
- **Never use `'0` or `'1` in plain assignments.** Every zero / all-ones / numeric literal assignment must use an explicit width — `64'h0`, `{XLEN{1'b0}}`, `32'hDEAD_BEEF`, `1'b0`, `1'b1`, etc. The explicit width documents the signal's bit width at the use site, helps catch width-mismatch bugs at lint time, and matches established project style. This applies to assignments, defaults inside `always_comb`/`always_ff`, and reset values inside `if (!rst_ni)` branches.
- **Recognized exception — struct-pattern initializers:** `'{default: '0}` is the standard SystemVerilog idiom for zero-initializing a struct that contains a mix of `logic` and enum fields. Inside the struct pattern, `'0` is per-field-typed (it picks each enum's first value and zeros each `logic` field at its declared width). Verilator rejects `'{default: 1'b0}` for enum fields, so use `'{default: '0}` for struct-zero defaults and resets.
- Use underscores in long literals for readability: `32'hDEAD_BEEF`, `16'b1010_0101_1111_0000`.

### Signal Declaration Order

All module signals (`logic`, struct/enum instances) must be declared in a single block immediately after the port list, in this order:

1. `localparam` / `parameter` constants
2. Imported types (struct / enum instances from `kronos_pkg`)
3. State registers (signals driven by `always_ff`, suffixed `_q`)
4. Combinational signals (signals driven by `always_comb` / `assign`)
5. Submodule interface signals (inputs/outputs of instances)

No additional `logic` / struct / enum declarations may appear elsewhere in the module body. Section comments inside the declaration block are encouraged for grouping (`// PTW signals`, `// miss FSM`).

**Exception:** declarations inside `generate` blocks are allowed (per-instance scope).
**Exception:** `for (int i = …; …)` loop indices may be declared in the loop header.

### No `automatic` variables

Banned in `always_ff`, `always_comb`, `for` / `begin` blocks, and at module scope. The keyword `automatic` may appear **only** on `function` and `task` declarations.

`function automatic` is **allowed and recommended** as the safe default for all helper functions — it provides per-call locals and avoids simulation re-entrancy hazards. Locals declared inside a function are scoped per call and are not affected by the no-in-process-declarations rule.

```systemverilog
// BAD — automatic variable inside always_comb
always_comb begin
  for (int i = 0; i < 4; i++) begin
    automatic logic match = (key == table_q[i]);  // banned
  end
end

// GOOD — declare at module scope, use inside the loop
logic [3:0] match;
always_comb begin
  for (int i = 0; i < 4; i++) match[i] = (key == table_q[i]);
end

// GOOD — function automatic is allowed
function automatic logic [7:0] strobes(input logic [2:0] sz, input logic [2:0] off);
  logic [7:0] s;        // function-local, fine
  ...
endfunction
```

### No declarations inside processes

`always_ff` and `always_comb` bodies contain only assignments and control flow. No `logic`, `int`, `bit`, `reg`, struct, or enum declarations at the top of the always block.

**Exception:** `for (int i = …; …)` loop indices may be declared in the loop header.

**Exception — named block locals:** declarations are allowed inside a labelled `begin : <name>` block. The label introduces a per-execution scope analogous to a function-local frame, so the locals don't leak to module scope and don't have re-entrancy hazards (each `always_*` evaluation enters a fresh frame). This pattern is common in FPU pipeline stages (`always_comb begin : proc_s3_align_amt` with stage-local intermediates).

### State suffix discipline: `_q` and `_d`

Every state-holding signal is named `<name>_q` and is the output of an `always_ff`. Its next-state combinational driver is `<name>_d`, written by an `always_comb` (or a continuous `assign`). At any read site, `foo_q` vs `foo_d` immediately tells you whether you are reading a flop output or a wire.

Port suffixes (`_i`, `_o`, `_ni`) are unchanged. The `_q` / `_d` suffix is internal-only. Use `_d` (not `_next`).

```systemverilog
logic [31:0] count_q, count_d;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) count_q <= 32'h0;
  else         count_q <= count_d;
end

always_comb begin
  count_d = count_q + 32'd1;
end
```

### One always block per logical group

One `always_ff` per related state group, one `always_comb` per related output group. No monolithic always blocks driving many unrelated signals. The test is "are these signals naturally read and written together?".

### `always_comb` must default-assign every driven signal at the top

Every signal driven by an `always_comb` block must be assigned a default value at the top of the block before any `if` / `case` overrides. This prevents inferred latches when a branch is missing.

### No magic numbers — prefer `kronos_pkg` parameters

Bare numeric literals in RTL are discouraged. Before writing a numeric literal, check whether `kronos_pkg` already defines a named parameter for that value (`XLEN`, `FLEN`, `FP_S_BIAS`, `MMIO_BASE`, etc.) and use the package name instead.

Promotion rules:

- **Project-wide constants** (data width, FP widths/biases, address regions, CSR masks, AXI widths) live in `kronos_pkg.sv` and are referenced by name from every consumer. If a literal would be reused by more than one module, add the parameter to `kronos_pkg` rather than a per-file `localparam`.
- **Module-local constants** (cache way count for one cache, FSM state encodings, internal pipeline-stage indices) may stay as a per-file `localparam` if they are not reused outside that module.
- **Single-use literals with obvious meaning** are exempt: `1'b0`, `1'b1`, small loop bounds (`for (int i = 0; i < 4; i++)`), and bit-field widths in port declarations.

Width literals representing data-bus width (`64`, `[63:0]`) must reference `XLEN` from `kronos_pkg`, not the bare number.

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

### No history-flavor comments in committed RTL

Comments must describe *what* the code does and *why*, not *when* it was added. Strip the following patterns from any new or edited comment:

- Sub-stage prefixes: `// Stage 6b: ...`, `// Stage 5h: ...`, `// (Stage 6e) ...`. Stage history belongs in commit messages and the design spec, not the RTL — the prefix decays into noise as soon as the next stage starts.
- Bug/issue references: `// Fix #2: ...`, `// Bug #N: ...`, `// per ticket ABC-123 ...`. Bug context belongs in the PR description and `git blame`.
- Author/date attributions: `// added by X on YYYY-MM-DD`. Use `git blame`.

If the comment after the prefix is substantive (explains a non-obvious invariant, hidden constraint, or workaround), keep the substantive part and drop the prefix. If the comment is only the prefix plus a restatement of what the code already shows, delete the whole comment.

```systemverilog
// BAD
// Stage 6b: cross-page 32-bit fetch fault. Asserted only when translation is on.
// Fix #2: ID-stage forwarding helper signals.

// GOOD
// Cross-page 32-bit fetch fault. Asserted only when translation is on.
// ID-stage forwarding helper signals.
```

### Lint Cleanliness

- All RTL must pass Verilator lint with `--Wall --Wno-UNUSED` before committing.
- No undriven outputs, no implicit truncations, no width mismatches.
- If a port is intentionally unconnected at the instantiation site, tie it explicitly: `()` for outputs, an explicit-width zero (`64'h0`, `{XLEN{1'b0}}`, etc.) for inputs — never `'0`.
- Avoid `$display`, `$finish`, `$readmemh` in synthesisable RTL — testbench only.

### Packages and Imports

- Shared types live in `rtl/kronos_pkg.sv`. Do not duplicate type definitions across files.
- Import the package at module level with `import kronos_pkg::*;` — this brings types into scope for use in the port list, signal declarations, and bodies.
- **Reference package `localparam` / `parameter` constants with the explicit `kronos_pkg::NAME` scope operator** at every use site (`kronos_pkg::XLEN`, `kronos_pkg::FLEN`, `kronos_pkg::MMIO_BASE`, `kronos_pkg::DECODED_INSTR_ZERO`, etc.). The scope prefix lets editor tooling (VSCode hover, LSP go-to-definition) resolve the constant's value without crawling every imported package. The wildcard `import` would otherwise hide the source file from the LSP.
- **Types stay bare.** `decoded_instr_t`, `alu_op_e`, `id_ex_reg_t`, etc. are written without the package prefix in port lists, signal declarations, and `case` selectors. The wildcard import covers them and the type suffix (`_t`, `_e`) already signals package-origin.
- **Enum members stay bare.** `ALU_ADD`, `FWD_NONE`, `PRIV_M`, `WB_ALU`, `FP_FADD`, etc. are written without the package prefix. The enclosing enum type already provides hover context, and scoping every case label would bloat decode tables and `case` statements.
- Do not create per-stage packages; `kronos_pkg` is the single shared package across all stages.

```systemverilog
module kronos_alu
  import kronos_pkg::*;
(
  input  alu_op_e                       op_i,        // type — bare
  input  logic [kronos_pkg::XLEN-1:0]   a_i,         // constant — scoped
  output logic [kronos_pkg::XLEN-1:0]   result_o
);
  always_comb begin
    result_o = {kronos_pkg::XLEN{1'b0}};              // constant — scoped
    unique case (op_i)
      ALU_ADD: result_o = a_i + b_i;                  // enum member — bare
      ALU_SUB: result_o = a_i - b_i;
      default: ;
    endcase
  end
endmodule
```

### Hierarchy and Instantiation

- Flat, shallow hierarchy preferred. Avoid more than 3 levels of nesting within a stage.
- Always use named port connections (`.port_name(signal)`). Never use positional connections.
- Instantiation name: `u_<module_without_prefix>` (e.g. `kronos_alu` → `u_alu`).

### Arithmetic and Widths

- Be explicit about signed vs unsigned: use `$signed()` cast when signed arithmetic is intended.
- Right-shifts on signed values must use `$signed()` to get arithmetic shift: `$signed(a) >>> b`.
- Concatenations must have explicit widths on all operands.
- When extending a value, be explicit: `{{24{byte[7]}}, byte}` not `{byte}`.

## Pre-commit hook

A small Python checker (`scripts/check_rtl_rules.py`) catches the highest-leverage RTL-rule regressions automatically. Install once:

```bash
git config core.hooksPath .githooks
```

After that, every `git commit` runs the hook on staged files in **delta mode** — it only flags violations on lines you added or modified, so legacy issues in untouched files don't block you. The hook checks:

- **R2:** `automatic` keyword on a variable (only `function automatic` / `task automatic` are allowed).
- **R1+R3:** `logic` / `int` / `bit` / `reg` / struct / enum declared after the first `always_*` block in a module body (with `function` / `task` / `generate` / labelled-`begin` carve-outs).
- **History-prefix comments:** `// Stage NX: …`, `// Fix #N: …`.
- **Multi-line `if` body without `begin`/`end`** (with the reset idiom and same-line bodies as carve-outs).

Run a full repository scan manually with `python3 scripts/check_rtl_rules.py` (no `--staged`). Bypass the hook with `git commit --no-verify` only when you have a justified reason.

## OpenSoC Integration

The parent project is at `/home/popes/opensoc`. kronos-riscv is added as a
submodule at `hw/ip/kronos_riscv`. When updating the submodule pointer:

```bash
cd /home/popes/opensoc
git submodule update --remote hw/ip/kronos_riscv
git add hw/ip/kronos_riscv
git commit -m "chore: update kronos-riscv submodule"
```
