# Stage 2: Multiply and Divide

**ISA:** RV32IM | **Status:** Complete | **Source:** `rtl/stage2/`

Prerequisite reading: [Stage 1](stage1.md)

---

## The Problem

The RISC-V M extension adds eight instructions: MUL, MULH, MULHSU, MULHU, DIV,
DIVU, REM, REMU. These cannot complete in a single EX cycle — a 32×32 multiply
needs time to settle through adder trees, and iterative division takes one bit of
quotient per cycle.

The solution is a **multi-cycle stall protocol**: when a muldiv instruction
reaches EX, the unit starts computing and the entire pipeline freezes. When the
result is ready, the unit pulses `valid_o` for one cycle, the pipeline captures
the result, and execution continues.

---

## What Changes in Stage 2

Three new files; everything else is reused unchanged:

| File | Status | Description |
|------|--------|-------------|
| `rtl/stage2/kronos_decode.sv` | New | Recognises M-ext opcodes (`OP` + `funct7=0000001`) |
| `rtl/stage2/kronos_muldiv.sv` | New | Multi-cycle multiply/divide FSM |
| `rtl/stage2/kronos_top.sv` | New | Wires muldiv into the combined stall |
| `rtl/stage1/kronos_forward.sv` | Reused | Forwarding — unchanged |
| `rtl/stage1/kronos_hazard.sv` | Reused | Hazard control — unchanged |
| `rtl/stage1/kronos_lsu.sv` | Reused | LSU — unchanged |
| `rtl/stage0/kronos_alu.sv` | Reused | ALU — unchanged |
| `rtl/stage0/kronos_regfile.sv` | Reused | Register file — unchanged |
| `rtl/stage0/kronos_csr.sv` | Reused | CSR (with `MISA_EXT=26'h1100` for I+M) |

The key wiring change in `kronos_top`:

```systemverilog
assign muldiv_stall   = id_ex_q.valid & id_ex_q.dec.is_muldiv & ~muldiv_valid;
assign combined_stall = mem_stall | muldiv_stall;
// combined_stall feeds kronos_hazard as mem_stall_i — interface unchanged
```

`kronos_hazard` doesn't know or care whether the stall came from the LSU or the
muldiv unit. It just freezes the pipeline.

---

## Multiply — 2-Cycle Latency

The four MUL variants differ in how operands are sign-treated:

| Instruction | A | B | Result bits |
|-------------|---|---|-------------|
| MUL | Signed | Signed | [31:0] |
| MULH | Signed | Signed | [63:32] |
| MULHSU | Signed | Unsigned | [63:32] |
| MULHU | Unsigned | Unsigned | [63:32] |

A single 33-bit multiplier handles all four: signed operands get `{a[31], a}`
(sign extension), unsigned get `{1'b0, a}` (zero extension). The 66-bit product
covers every variant.

FSM:
1. **IDLE** — `req_i` fires: the combinational product is computed and stored in
   `result_q`. State → **MUL_BUSY**.
2. **MUL_BUSY** — one cycle of latency. State → **DONE**.
3. **DONE** — `valid_o=1`. Pipeline captures `result_o`. State → **IDLE**.

Total: 2 cycles from `req_i` to `valid_o`.

---

## Divide — The Restoring Algorithm

Division uses an iterative restoring algorithm: one bit of quotient per cycle,
32 iterations, then sign correction.

Each cycle in COMPUTE:
1. Shift partial remainder left, bring in next dividend bit:
   `rem_shifted = {remainder_q[31:0], dividend_q[31]}`
2. Try subtracting the divisor:
   `rem_sub = rem_shifted - {1'b0, abs_b_q}`
3. If `rem_sub[32]=0` (no underflow): accept — quotient bit = 1,
   `remainder = rem_sub[31:0]`
4. If `rem_sub[32]=1` (underflow): restore — quotient bit = 0,
   `remainder = rem_shifted[31:0]`
5. Shift `dividend_q` left for next bit

After 32 iterations, negate the quotient and/or remainder as needed for signed
variants.

Total: 34 cycles (IDLE + 32×COMPUTE + DONE). Edge cases skip directly to DONE
in 2 cycles.

---

## Edge Cases

Four results are mandated by the RISC-V M-extension spec and handled before the
iterative algorithm runs:

| Condition | Instruction | Mandated result |
|-----------|-------------|-----------------|
| `b == 0` | DIV / DIVU | `0xFFFF_FFFF` (−1) |
| `b == 0` | REM / REMU | `a` (dividend unchanged) |
| `a == 0x8000_0000`, `b == 0xFFFF_FFFF` | DIV | `0x8000_0000` (INT_MIN) |
| `a == 0x8000_0000`, `b == 0xFFFF_FFFF` | REM | `0x0000_0000` |

All four are detected in the IDLE state. The FSM writes the result directly into
`result_q` and jumps to DONE, skipping COMPUTE entirely.

---

## Forwarding with Variable Latency

During a muldiv operation, `muldiv_stall=1` freezes the pipeline. The muldiv
instruction stays in ID/EX for the full duration (2 cycles for MUL, up to 34 for
DIV). When `valid_o` fires:

1. `muldiv_stall` drops to 0 — pipeline unfreezes.
2. `ex_result = muldiv_result` is written into `ex_mem_q.alu_result` as the
   instruction advances to MEM.
3. The following instruction (which was held in ID/EX) now enters EX and sees
   the result via EX/MEM→EX forwarding — exactly as it would for a normal ALU
   result.

No changes to `kronos_forward` or `kronos_hazard` were needed.

---

## Known Limitation

`req_i` to `kronos_muldiv` is gated by `~mem_stall`:

```systemverilog
.req_i (id_ex_q.valid & id_ex_q.dec.is_muldiv & muldiv_idle & ~mem_stall),
```

This prevents a LOAD immediately followed by a MULDIV from sampling forwarded
operands before the load data has settled through the forwarding paths. In
practice this adds zero latency for any program that inserts at least one
independent instruction between a load and a dependent muldiv. It will be
addressed in Stage 3.
