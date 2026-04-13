# Stage 1: Adding the Pipeline

**ISA:** RV32I | **Status:** Complete | **Source:** `rtl/stage1/`

Prerequisite reading: [Stage 0](stage0.md)

---

## The Throughput Problem

In Stage 0, the clock must be slow enough for every instruction's longest path —
which includes the memory access. The ALU idles during loads. The decoder idles
while the ALU runs. Hardware that costs silicon but does nothing is wasted.

A **pipeline** solves this by dividing the loop into stages and processing
multiple instructions simultaneously — one per stage. While instruction N is in
the ALU, instruction N+1 is being decoded, and instruction N+2 is being fetched.
Throughput approaches one instruction per cycle.

Stage 1 implements a five-stage pipeline: IF → ID → EX → MEM → WB. The ISA is
unchanged — every instruction still has the same architectural effect as Stage 0.
The only difference is that multiple instructions are in flight at once.

---

## The Five Stages

Each stage does one thing, then passes its results to the next through a
**pipeline register** — flip-flops that capture the stage's outputs and hold them
for the next cycle. Each register carries a `valid` bit; a stage with `valid=0`
is a bubble that performs no writeback or side effects.

| Stage | Logic | What it does |
|-------|-------|--------------|
| IF | PC register, OBI instruction port | Fetches the next instruction from memory |
| ID | `kronos_decode`, `kronos_regfile` | Decodes; reads register operands |
| EX | `kronos_alu`, `kronos_csr`, branch comparator | Computes result; resolves branches and traps |
| MEM | `kronos_lsu` | Executes loads and stores |
| WB | Writeback mux, `kronos_regfile` write port | Writes result to register file |

The four pipeline registers (IF/ID, ID/EX, EX/MEM, MEM/WB) are packed structs
in `rtl/kronos_pkg.sv`, owned by `kronos_top`. Each carries everything downstream
stages need: decoded fields, the PC, computed values.

---

## Data Hazards — and Forwarding

A **Read-After-Write (RAW) hazard** occurs when one instruction produces a result
that the next instruction needs before it has been written back.

```asm
ADD x1, x2, x3     # writes x1 — reaches WB at cycle 5
ADD x4, x1, x5     # reads x1 in ID at cycle 3 — stale!
```

**Forwarding** routes the result directly from wherever it lives in the pipeline
to the instruction that needs it, bypassing the register file:

- **EX/MEM → EX**: result from one stage ahead (`ex_mem_q.alu_result`)
- **MEM/WB → EX**: result from two stages ahead (WB mux output)
- **WB → ID bypass**: when WB writes the same register ID is reading in the same
  cycle, the write data is forwarded into the ID/EX register. This bypass lives
  in `kronos_top`, not in `kronos_regfile`, to avoid a combinatorial loop that
  would occur in the Stage 0 single-cycle model.

`kronos_forward` computes `fwd_sel_e` for RS1 and RS2. EX/MEM takes priority
over MEM/WB when both match the same register.

---

## The Load-Use Hazard

Forwarding handles most RAW hazards, but loads are special. A load's result is
not available until the *end* of MEM — one cycle later than a non-load in the
same position.

```asm
LW  x1, 0(x2)       # result ready at end of MEM
ADD x3, x1, x4      # needs x1 at start of EX — same cycle!
```

MEM/WB→EX forwarding would deliver the result, but only at the start of EX, not
the end of MEM. There's a one-cycle gap.

Solution: a **1-cycle stall**. When a load in EX is followed by a dependent
instruction in ID:
- Hold PC and IF/ID (fetch does not advance)
- Insert a bubble into ID/EX (the dependent instruction repeats ID next cycle)
- Let EX and MEM advance normally

After the stall, the load is in MEM/WB with its result available, and MEM/WB→EX
forwarding delivers it correctly.

`kronos_forward` suppresses `FWD_EXMEM` when `ex_mem_is_load_i=1` — that is the
load-use case and must be handled by a stall, not forwarding.

---

## Control Hazards

Branch and jump targets are resolved in EX. By that time, two more instructions
have been fetched and partially decoded behind the branch — from the wrong path.

```
Cycle:  1    2    3    4
BEQ:    IF   ID   EX   MEM
BAD1:        IF   ID   EX   ← wrong path, must be squashed
BAD2:             IF   ID   ← wrong path, must be squashed
```

When `ex_redirect=1` (branch taken, JAL, JALR, ECALL, EBREAK, illegal, MRET, or
interrupt), `kronos_hazard` asserts `if_id_flush=1` and `id_ex_flush=1`, clearing
those registers to NOP. The 2-cycle penalty applies to all redirect sources.

---

## OBI Stalls

When the memory bus takes more than one cycle to respond, `kronos_lsu` asserts
`mem_stall_o=1` and the entire pipeline freezes: all five pipeline register
enables go to 0.

WB must be held too. Without it, WB would see the same `mem_wb_q` contents the
next cycle and perform a double write to the register file.

The LSU uses a two-state FSM:

| State | Meaning |
|-------|---------|
| IDLE | No active transaction. `mem_stall_o=0`. |
| WAIT_RVALID | `gnt` received; waiting for `rvalid`. `mem_stall_o=1`. |

Transitions: `IDLE → WAIT_RVALID` when `req & gnt & ~rvalid`. Back to `IDLE`
when `rvalid` fires. OBI requires a response phase for writes — the LSU waits
for `rvalid` on stores too.

---

## Hazard Priority

When multiple hazard conditions are true simultaneously:

| Priority | Condition | Effect |
|----------|-----------|--------|
| 1 (highest) | `mem_stall=1` | Hold all pipeline registers |
| 2 | Load-use | Hold PC, IF/ID; flush ID/EX to bubble; EX and MEM advance |
| 3 | `ex_redirect=1` | Flush IF/ID and ID/EX |
| 4 (lowest) | None | Normal advance |

A MEM stall suppresses the EX redirect: the redirect will re-assert next cycle
when the stall clears.

---

## New Modules

### `kronos_forward` (`rtl/stage1/kronos_forward.sv`)

Purely combinational. Inspects the RD fields of the EX/MEM and MEM/WB pipeline
registers against the RS1/RS2 fields of the ID/EX register. Outputs `fwd_sel_e`
for each source operand. All forwarding is suppressed when `rd == 5'd0`.

### `kronos_hazard` (`rtl/stage1/kronos_hazard.sv`)

Purely combinational. Takes `ex_redirect`, `mem_stall`, and load-use detection
inputs. Drives the five pipeline register enables and two flush signals. All
hazard decisions are centralised here — `kronos_top` makes none.

---

## Timing Summary

| Instruction class | Cycles |
|-------------------|--------|
| ALU / shift / logic / not-taken branch | 1 |
| Taken branch / JAL / JALR | 3 (2-cycle flush) |
| Load-use (load then dependent) | 3 (1-cycle stall) |
| Load/store, `gnt+rvalid` same cycle | 1 |
| Load/store, `rvalid` one cycle after `gnt` | 2 |
| ECALL / EBREAK / illegal / MRET / interrupt | 3 (2-cycle flush) |
