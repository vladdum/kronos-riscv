# kronos-riscv Architecture Reference

**ISA:** RV64IMAFDC &nbsp;|&nbsp; **Microarchitecture:** 5-stage in-order pipeline &nbsp;|&nbsp; **Bus:** AXI4 &nbsp;|&nbsp; **Branch prediction:** bimodal (64-entry PHT + 16-entry BTB) &nbsp;|&nbsp; **Active stage:** Stage 5h

kronos-riscv is a 5-stage in-order RISC-V processor implementing the RV64IMAFDC ISA. Instructions flow through Instruction Fetch (IF), Instruction Decode (ID), Execute (EX), Memory (MEM), and Writeback (WB). The IF stage includes an alignment unit that handles variable-width compressed instructions and a bimodal branch predictor that speculatively redirects fetch before branch resolution. The EX stage contains the 64-bit ALU, a multi-cycle 64-bit multiply/divide unit, branch resolution logic, and the CSR unit. The MEM stage drives an AXI4 load/store unit supporting atomic operations (LR/SC, AMO) and floating-point loads/stores. A separate FPU with six pipelined units handles the F and D extensions; the FPU uses a scoreboard rather than the integer forwarding network for hazard management. Hazard and forwarding control modules sit outside the pipeline stages and manage stalls, flushes, and operand forwarding.

![Pipeline overview](diagrams/svg/top-level.svg)

The five pipeline registers — IF/ID, ID/EX, EX/MEM, MEM/WB — carry decoded instruction state across stages. Each register has an `en` enable and a `flush` (clear-to-NOP) control driven by `kronos_hazard`. Operand forwarding is handled by `kronos_forward`, which selects between the register-file read value, the EX/MEM result, and the MEM/WB result. FP operand hazards are managed by `kronos_fpu_scoreboard` rather than the integer forwarding network.

---

## 1. Design Evolution

One row per stage. The core pipeline structure (5 stages, AXI4 bus, bimodal branch predictor) was established in Stage 3 and has not changed since.

| Stage | ISA | Key modules introduced | Key concept |
|-------|-----|----------------------|-------------|
| 0 | RV32I | `kronos_decode`, `kronos_regfile`, `kronos_alu`, `kronos_lsu` (OBI), `kronos_csr` | Single-cycle golden model |
| 1 | RV32I | `kronos_lsu` (OBI FSM), `kronos_forward`, `kronos_hazard` | 5-stage pipeline, data/control hazards |
| 2 | RV32IM | `kronos_muldiv` | Multi-cycle stall protocol |
| 3 | RV32IMC | `kronos_lsu` (AXI4), `kronos_decompress`, `kronos_align`, `kronos_bpred` | Native AXI4, C extension, branch prediction |
| 4 | RV64IMAC | `kronos_alu` (64-bit), `kronos_muldiv` (64-bit), `kronos_decompress` (RV64C), `kronos_lsu` (LR/SC + AMO), `kronos_csr` (64-bit) | 64-bit datapath widening, atomic operations |
| 5a | RV64IMAFD | `kronos_regfile_fp`, `kronos_fpu_top`, `kronos_fpu_scoreboard`, `kronos_fpu_fmisc`, `kronos_fpu_fcvt`, `kronos_fpu_fadd`, `kronos_fpu_fmul`, `kronos_fpu_fma` | Separate FP register file, multi-unit FPU dispatch, scoreboard hazard model |
| 5b | RV64IMAFDC | `kronos_fpu_iter`, `kronos_fpu_fdiv_core`, `kronos_fpu_fsqrt_core` | Iterative FDIV/FSQRT (radix-2 SRT) |

---

## 2. Module Hierarchy

Full instantiation tree for Stage 5 `kronos_top`. The stage column shows when each module was introduced; modules marked "reused" were not modified in later stages.

```
kronos_top  (rtl/stage5/kronos_top.sv)
├── u_align         kronos_align             (rtl/stage3/kronos_align.sv)              [stage 3]
├── u_bpred         kronos_bpred             (rtl/stage3/kronos_bpred.sv)              [stage 3]
├── u_decompress    kronos_decompress        (rtl/stage4/kronos_decompress.sv)         [stage 4: RV64C]
├── u_decode        kronos_decode            (rtl/stage5/kronos_decode.sv)             [stage 5: IMAFDC]
├── u_regfile       kronos_regfile           (rtl/stage0/kronos_regfile.sv)            [stage 0, reused]
├── u_regfile_fp    kronos_regfile_fp        (rtl/stage5/kronos_regfile_fp.sv)         [stage 5a]
├── u_alu           kronos_alu               (rtl/stage4/kronos_alu.sv)                [stage 4: 64-bit]
├── u_csr           kronos_csr               (rtl/stage5/kronos_csr.sv)                [stage 5: FCSR/FRM]
├── u_lsu           kronos_lsu               (rtl/stage5/kronos_lsu.sv)                [stage 5: FP loads/stores]
├── u_muldiv        kronos_muldiv            (rtl/stage4/kronos_muldiv.sv)             [stage 4: 64-bit]
├── u_forward       kronos_forward           (rtl/stage1/kronos_forward.sv)            [stage 1, reused]
├── u_hazard        kronos_hazard            (rtl/stage1/kronos_hazard.sv)             [stage 1, reused]
└── u_fpu           kronos_fpu_top           (rtl/stage5/fpu/kronos_fpu_top.sv)       [stage 5a]
    ├── u_fmisc     kronos_fpu_fmisc         1-cycle: FSGNJ/FMIN/FMAX/FCLASS/CMP/FMV
    ├── u_fcvt      kronos_fpu_fcvt          2-cycle: FCVT
    ├── u_fadd      kronos_fpu_fadd          5-cycle: FADD/FSUB
    ├── u_fmul      kronos_fpu_fmul          4-cycle: FMUL
    ├── u_fma       kronos_fpu_fma           5-cycle: FMADD/FMSUB/FNMADD/FNMSUB
    ├── u_iter      kronos_fpu_iter          variable: FDIV/FSQRT wrapper FSM          [stage 5b]
    │   ├── u_fdiv  kronos_fpu_fdiv_core     radix-2 SRT division                      [stage 5b]
    │   └── u_fsqrt kronos_fpu_fsqrt_core   radix-2 SRT square root                   [stage 5b]
    └── u_scoreboard kronos_fpu_scoreboard   WAW busy-table + WB port arbitration
```

---

## 3. IF Stage — Fetch, Alignment, Decompression, Branch Prediction

### 3a. Fetch FSM

The fetch FSM has two states: **FETCH_IDLE** and **FETCH_WAIT_R**.

![Fetch FSM](diagrams/svg/if-fetch-fsm.svg)

In FETCH_IDLE the FSM asserts `arvalid` when a new fetch is needed (`align_needs_fetch` is high). It transitions to FETCH_WAIT_R on the same cycle that `arready` is seen, then waits for `rvalid`. When `rvalid` arrives, the 32-bit word is handed to the alignment unit and the FSM returns to FETCH_IDLE, immediately issuing the next fetch if `align_needs_fetch` is still asserted.

`align_needs_fetch` gates every new AXI4 AR transaction. The alignment unit raises it when it has consumed its current word and needs the next one. For spanning instructions (a 16-bit compressed instruction whose upper half sits at the start of the next aligned word), the fetch FSM computes the next-word address by incrementing the current aligned PC by 4 (`NEED_UPPER` path).

![AXI4 instruction fetch waveform](diagrams/svg/wf-axi-fetch.svg)

### 3b. Alignment Unit

RVC instructions are 16 bits wide; RVI instructions are 32 bits wide. Both arrive from memory as 32-bit aligned words, so the alignment unit must extract instructions of varying width from a fixed-width stream.

![Alignment unit states](diagrams/svg/if-align-states.svg)

The alignment unit operates as a three-state FSM:

- **NORMAL** — the upper 16 bits of the fetched word have not yet been consumed. The current instruction is taken directly from the word. If it is 16-bit, the unit stays in NORMAL (or moves to BUFFERED for the upper half); if it is 32-bit spanning two aligned words, it transitions to NEED_UPPER.
- **BUFFERED** — the lower 16 bits of the previous word held a 16-bit instruction that was emitted. The upper 16 bits (`skip_lower_q`) are now at the head of the stream and may form the start of the next instruction.
- **NEED_UPPER** — the lower 16 bits of the current word hold the start of a 32-bit instruction whose upper 16 bits are in the next word. A new fetch is issued immediately; once `rvalid` arrives, the two halves are concatenated and emitted together.

`skip_lower_q` latches the upper half-word whenever a 16-bit instruction is extracted from the lower half of a fetched word, so the next decode sees the buffered upper half without issuing a new fetch.

![32-bit instruction pass-through](diagrams/svg/wf-align-32b.svg)

![16-bit instruction buffering](diagrams/svg/wf-align-16b.svg)

![Spanning instruction (NEED_UPPER)](diagrams/svg/wf-align-spanning.svg)

### 3c. Decompression

Decompression is purely combinational. `kronos_decompress` accepts a 16-bit or 32-bit instruction word and expands it to a canonical 32-bit equivalent. If `inst[1:0]` are both `1`, the input is already 32-bit and is passed through unchanged. Stage 4 extended the decompressor to cover the RV64C-only encodings: C.ADDIW, C.LDSP, C.SDSP, C.LD, C.SD, C.ADDW, C.SUBW. Reserved or undefined compressed encodings set `illegal_o`, which propagates through the pipeline and triggers a trap in EX.

### 3d. Branch Predictor

The branch predictor combines a **bimodal pattern history table (PHT)** with a **branch target buffer (BTB)**.

- **PHT:** 64 entries indexed by `PC[7:2]`, each holding a 2-bit saturating counter (00 = strongly not-taken, 11 = strongly taken).
- **BTB:** 16 entries indexed by `PC[5:2]`, each holding a valid bit and a 64-bit target address. Direct-mapped; no tag, so aliasing is possible.

![Branch predictor internals](diagrams/svg/if-bpred.svg)

**Lookup (combinational):** On every cycle the current PC indexes both structures simultaneously. If the BTB entry is valid and the PHT counter MSB is `1`, the predictor asserts `pred_taken` and drives `pred_target` from the BTB. The IF stage uses `pred_target` as the next PC instead of `PC+2/4`.

**Update (registered):** The EX stage sends the resolved direction and target back to the predictor. The PHT counter is incremented on taken, decremented on not-taken, saturating at the extremes. On a taken outcome the BTB is written with the resolved target. On a not-taken outcome where the counter has saturated to `00`, the BTB entry is invalidated.

**Misprediction detection:** EX compares its resolved outcome against the prediction carried in the pipeline register. A misprediction is flagged when the direction disagrees, or when both sides agree the branch was taken but the predicted target differs from the resolved target. Either condition triggers a two-cycle flush of IF and ID and a PC redirect.

![Correct prediction waveform](diagrams/svg/wf-bpred-correct.svg)

![Misprediction flush waveform](diagrams/svg/wf-bpred-mispredict.svg)

---

## 4. ID Stage — Decode and Register Read

![ID stage block diagram](diagrams/svg/id-stage.svg)

`kronos_decode` is a purely combinational decoder. It accepts a 32-bit instruction word (already decompressed) and produces the `decoded_instr_t` struct carried by all downstream pipeline registers. It handles the full RV64IMAFDC instruction set. For FP instructions with `rm = 3'b111` (dynamic rounding mode), the rounding mode field is resolved at decode by reading `fcsr_frm_i`; the resolved rounding mode is carried in the pipeline register so that FPU units do not need CSR access.

`kronos_regfile` implements 32 registers of 64 bits each. Reads are asynchronous (combinational): `rs1_rdata_o` and `rs2_rdata_o` reflect the current register contents in the same cycle the addresses are presented. Writes are synchronous on the rising clock edge. Reads and writes to `x0` are both suppressed — reads return `'0`, writes are ignored.

`kronos_regfile_fp` implements 32 floating-point registers of 64 bits each. It provides three simultaneous read ports (`fs1`, `fs2`, `fs3`) and one write port (`fd`). The NaN-boxing invariant is maintained at the LSU boundary: FLW forces the upper 32 bits to `32'hFFFF_FFFF` before writing, and FPU units check NaN-boxing on single-precision source operands.

A WB→ID bypass mux sits between the integer register file read ports and the ID/EX pipeline register. When the WB stage is writing a register that ID is simultaneously reading, the bypass mux selects the write-data path rather than the stale register file output. There is no equivalent FP bypass; FP hazards are managed entirely by the scoreboard.

---

## 5. EX Stage — Execute, Branch Resolution, Muldiv

![EX stage block diagram](diagrams/svg/ex-stage.svg)

**Forwarding muxes.** Two muxes, one for each source operand (RS1, RS2), select among three sources controlled by `fwd_rs1_sel` / `fwd_rs2_sel` from `kronos_forward`:

| Select | Source |
|--------|--------|
| `FWD_NONE` | ID/EX register value (from register file or WB→ID bypass) |
| `FWD_EXMEM` | EX/MEM `alu_result` (instruction two stages ahead of the consumer) |
| `FWD_MEMWB` | MEM/WB `wb_result` (instruction one stage ahead of the consumer) |

`FWD_EXMEM` is suppressed when the producing instruction is a load — load data is not available until the MEM stage completes, which generates a load-use hazard instead. All forwarding is suppressed when `rd = x0`.

**ALU.** Single-cycle, fully combinational. All operations are 64-bit wide. W-suffix instructions (ADDW, SUBW, SLLW, SRLW, SRAW, and their immediate variants) operate on the lower 32 bits and sign-extend the result to 64 bits per spec. Operations: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND, PASSB (used by LUI to pass the immediate through unchanged). The A-operand mux selects between the forwarded RS1 value and the instruction PC (for AUIPC and branch offset computation). The B-operand mux selects between the forwarded RS2 value and the sign-extended immediate.

**Muldiv.** `kronos_muldiv` implements all eight M-extension operations for both 32-bit and 64-bit operands. MUL operations require **2 cycles**. DIV and REM operations require **34 cycles** (32-bit) or **66 cycles** (64-bit) in the normal case. Division by zero and `INT_MIN / -1` are detected early and produce a result in **2 cycles**. While `muldiv_stall` is asserted the entire pipeline freezes.

![MUL stall waveform](diagrams/svg/wf-muldiv-stall.svg)

![DIV stall waveform](diagrams/svg/wf-div-stall.svg)

**Branch resolution.** EX evaluates every branch condition using the forwarded operands. JAL, JALR, and taken branches write `pc_next` into EX/MEM and assert `redirect`. JALR adds RS1 to the sign-extended 12-bit immediate and clears bit 0. The branch predictor update signals (resolved direction and target) are also driven from EX.

**Trap cause priority.** When multiple exception sources are simultaneously active, EX selects the cause in this order (highest first): external interrupt (`irq_pending`) > illegal instruction > ECALL > EBREAK. All traps and MRET assert `redirect` and set `pc_next` to the trap vector or `mepc` respectively.

**CSR unit.** `kronos_csr` implements CSRRW, CSRRS, and CSRRC plus their immediate variants. CSR reads return the old value; writes take effect one cycle later. MISA reports I, M, A, F, D, and C extensions; MXL = 2 (64-bit). FCSR, FFLAGS, and FRM are readable/writable; the FPU reads `fcsr_frm_o` from the CSR unit and writes accumulated exception flags back via `fflags_i`. `mstatus.FS` tracks floating-point state (Off / Initial / Clean / Dirty).

---

## 6. FPU

The FPU handles all F and D extension instructions. It is logically separate from the integer pipeline: FP instructions are dispatched from EX to `kronos_fpu_top`, which routes them to one of six pipelined units. Results are written directly to `kronos_regfile_fp` through the FPU's dedicated writeback interface, bypassing the integer WB mux.

### 6a. Dispatch and Scoreboard

`kronos_fpu_top` receives the decoded FP instruction from EX when `is_fp` is asserted. It selects the target unit based on `fpu_op`, presents the three FP register read values, and arbitrates the writeback port when multiple units complete in the same cycle.

`kronos_fpu_scoreboard` implements the FP hazard model:

**WAW busy-table:** One bit per FP register. Set when an instruction is dispatched to any unit that writes `fd`. Cleared on writeback. A new FP instruction is stalled (`fpu_stall_o` asserted) while any of its source registers (`fs1`, `fs2`, `fs3`) or its destination register (`fd`) have their busy bit set. This prevents RAW and WAW hazards without operand forwarding.

**WB port arbitration:** All six units share one write port to `kronos_regfile_fp`. When multiple units complete in the same cycle, the scoreboard grants the port to the highest-priority unit and holds lower-priority units in a DONE state until the port is free.

### 6b. FPU Unit Table

| Unit | Module | Latency | Operations |
|------|--------|---------|------------|
| fmisc | `kronos_fpu_fmisc` | 1 cycle | FSGNJ, FMIN, FMAX, FCLASS, FCMP, FMV.X.W, FMV.W.X, FMV.X.D, FMV.D.X |
| fcvt | `kronos_fpu_fcvt` | 2 cycles | FCVT.W.S, FCVT.WU.S, FCVT.L.S, FCVT.LU.S, FCVT.S.W, FCVT.S.WU, FCVT.S.L, FCVT.S.LU, FCVT.S.D, FCVT.D.S, and D variants |
| fadd | `kronos_fpu_fadd` | 5 cycles | FADD.S, FSUB.S, FADD.D, FSUB.D |
| fmul | `kronos_fpu_fmul` | 4 cycles | FMUL.S, FMUL.D |
| fma | `kronos_fpu_fma` | 5 cycles | FMADD.S, FMSUB.S, FNMADD.S, FNMSUB.S, FMADD.D, FMSUB.D, FNMADD.D, FNMSUB.D |
| iter | `kronos_fpu_iter` | ≤ 29 (S) / ≤ 58 (D) cycles | FDIV.S, FDIV.D, FSQRT.S, FSQRT.D |

All units implement IEEE 754-2019 rounding and exception flag generation. The resolved rounding mode is carried from decode through the pipeline register.

### 6c. FDIV/FSQRT — Iterative SRT

`kronos_fpu_fdiv_core` and `kronos_fpu_fsqrt_core` implement radix-2 SRT iterative division and square root. One quotient/root bit is produced per cycle after an initial normalization step.

- Single precision (23-bit mantissa): ≤ 29 cycles
- Double precision (52-bit mantissa): ≤ 58 cycles

`kronos_fpu_iter` wraps both cores in a 3-state FSM: `IDLE → RUNNING → DONE`. While in RUNNING, `iter_busy_o` is asserted; the scoreboard propagates this as `fpu_stall_o`, freezing integer dispatch for the duration. Both cores handle special cases (±0, ±Inf, NaN, subnormals) combinationally before the iteration begins and short-circuit to DONE when applicable.

---

## 7. MEM Stage — AXI4 Load/Store Unit

![LSU FSM](diagrams/svg/mem-lsu-fsm.svg)

The LSU is a seven-state FSM that drives the AXI4 data channel. All memory operations go through it; non-memory instructions pass through in one cycle with `mem_stall_o` deasserted.

**Load path:** `IDLE → LOAD_ADDR → LOAD_DATA → LOAD_DONE`

The FSM asserts `arvalid` in LOAD_ADDR and waits for `arready`. It then waits for `rvalid` in LOAD_DATA. On `rvalid`, the returned data is sign- or zero-extended according to `funct3` and latched. The FSM moves to LOAD_DONE and drops `mem_stall_o` for one cycle to let the pipeline advance.

**Store path:** `IDLE → STORE_SEND → STORE_RESP → STORE_DONE`

In STORE_SEND the FSM asserts both `awvalid` and `wvalid` simultaneously. Two flags — `aw_acked_q` and `w_acked_q` — track which handshakes have completed. The FSM remains in STORE_SEND until both are acknowledged, then moves to STORE_RESP to wait for `bvalid`. STORE_DONE releases `mem_stall_o`.

**LR/SC (Stage 4):** LR follows the load path and sets a reservation register with the physical address. The reservation is cleared by any store from this hart. SC checks the reservation: on match, performs the store path and writes `0` to `rd`; on miss, skips the store and writes `1` to `rd`. Both outcomes release `mem_stall_o` via STORE_DONE.

**AMO (Stage 4):** Atomic RMW uses the full sequence: `IDLE → LOAD_ADDR → LOAD_DATA → LOAD_DONE → STORE_SEND → STORE_RESP → STORE_DONE`. The RMW operation (SWAP, ADD, AND, OR, XOR, MIN, MAX, signed/unsigned variants) is applied combinationally between LOAD_DONE and STORE_SEND. The original loaded value is forwarded to the integer WB mux as the instruction result.

**FP loads/stores (Stage 5):** FLW and FLD follow the standard load path; on completion, the data is routed to the FP writeback interface. FLW applies NaN-boxing (upper 32 bits forced to `32'hFFFF_FFFF`). FSW and FSD follow the standard store path, sourcing write data from `kronos_regfile_fp` rather than the integer pipeline register.

**`mem_done_q` latch:** When the pipeline is stalled by an instruction fetch (`instr_fetch_stall`) at the same cycle the LSU would otherwise complete, `mem_done_q` latches the completion event. On the cycle `instr_fetch_stall` clears, `mem_done_q` drives `mem_stall_o` low for one cycle. `lsu_rdata_latch` holds load data stable across this window.

![AXI4 load transaction waveform](diagrams/svg/wf-axi-load.svg)

![AXI4 store transaction waveform](diagrams/svg/wf-axi-store.svg)

![mem_done_q latch scenario](diagrams/svg/wf-mem-done-latch.svg)

---

## 8. WB Stage — Writeback

![Writeback mux](diagrams/svg/wb-mux.svg)

The integer writeback mux selects the value written to `kronos_regfile` based on `wb_sel` from the decoded instruction:

| `wb_sel` | Source | Used by |
|----------|--------|---------|
| `WB_ALU` | `alu_result` from EX/MEM | ALU, muldiv, AUIPC, LUI, AMO (loaded value) |
| `WB_MEM` | `lsu_rdata` from LSU | Integer load instructions (LB, LH, LW, LD, LBU, LHU, LWU) |
| `WB_PC4` | `pc + 2/4` from EX/MEM | JAL, JALR (link address) |
| `WB_CSR` | `csr_rdata` from EX/MEM | CSR read-modify-write instructions |

The selected value is written when `rd_wen` is asserted and `rd ≠ x0`. It is also driven to the WB→ID bypass mux and exposed as `FWD_MEMWB` to the EX forwarding muxes.

FP writeback is a separate path from `kronos_fpu_top` directly to `kronos_regfile_fp`. It does not go through `wb_sel`. FLW/FLD results are routed through the FPU's writeback interface so that NaN-boxing is applied uniformly.

---

## 9. Hazard and Forwarding Control

![Hazard and forwarding control plane](diagrams/svg/hazard-forward.svg)

Two modules sit outside the pipeline stages and control all integer pipeline flow:

**`kronos_forward`** computes `fwd_rs1_sel` and `fwd_rs2_sel` combinationally from the instruction addresses in EX, MEM, and WB. Priority: EX/MEM result is preferred over MEM/WB result when both would forward to the same operand. `FWD_EXMEM` is suppressed for loads; all forwarding is suppressed for `rd = x0`.

**`kronos_hazard`** drives the `en` and `flush` control inputs to all five pipeline registers. It implements a strict priority ordering:

```
combined_stall = mem_stall | muldiv_stall | instr_fetch_stall | fpu_stall
```

| Priority | Condition | Effect |
|----------|-----------|--------|
| 1 (highest) | `combined_stall` | Freeze entire pipeline (all `en=0`, no flushes) |
| 2 | Load-use hazard | Stall IF, ID, EX; insert bubble into EX/MEM |
| 3 | Misprediction / trap / MRET | Flush IF/ID and ID/EX; redirect PC |
| 4 (lowest) | None | Normal advance (all `en=1`, no flushes) |

`fpu_stall` is asserted by `kronos_fpu_scoreboard` when a WAW conflict is detected on dispatch, a WB port collision requires holding a unit's result, or `iter_busy_o` is high. During `fpu_stall` the integer pipeline is frozen exactly as during `mem_stall`; the scoreboard continues its own internal state transitions independently.

FP hazards are managed entirely by the scoreboard. `kronos_forward` and `kronos_hazard` have no visibility into FP register state. FP loads (FLW, FLD) do not generate load-use hazards to the integer pipeline.

**Load-use detection.** A load-use hazard exists when the instruction in EX is a valid integer load (`id_ex_valid & id_ex_is_load`), its destination is not `x0`, and the instruction in ID reads the same register as RS1 or RS2. The hazard inserts one bubble: IF and ID are held, the ID/EX register is flushed to NOP.

![Load-use hazard waveform](diagrams/svg/wf-load-use-hazard.svg)

---

## 10. Timing Table

Cycles measured from the instruction entering EX to its result being available in WB (or to the first valid instruction after a redirect for branches and traps). FPU latencies are measured from dispatch (EX) to writeback.

| Instruction class | Cycles |
|---|:---:|
| ALU / logic / not-taken branch (predicted correctly) | 1 |
| Taken branch / JAL / JALR (predicted correctly) | 1 |
| Mispredicted branch / JAL / JALR | 3 |
| Load-use (integer load then dependent) | 3 |
| Integer load (AXI4) | 3 |
| Integer store (AXI4) | 3 |
| ECALL / EBREAK / illegal / MRET / interrupt | 3 |
| MUL / MULH / MULHSU / MULHU (32-bit or 64-bit) | 2 |
| DIV / REM (32-bit, normal) | 34 |
| DIV / REM (64-bit, normal) | 66 |
| DIV / REM (div-by-0 or INT_MIN / −1, any width) | 2 |
| LR.W / LR.D | 3 |
| SC.W / SC.D | 3 |
| AMO (AMOSWAP / AMOADD / …) | 6 |
| FP load (FLW / FLD, AXI4) | 3 |
| FP store (FSW / FSD, AXI4) | 3 |
| FSGNJ / FMIN / FMAX / FCLASS / FCMP / FMV | 1 |
| FCVT (any variant) | 2 |
| FADD / FSUB / FMUL (S or D) | 4 |
| FMADD / FMSUB / FNMADD / FNMSUB (S or D) | 5 |
| FDIV.S / FSQRT.S | ≤ 29 |
| FDIV.D / FSQRT.D | ≤ 58 |

---

## 11. CSR Register Map

| Address | Name | Description |
|---------|------|-------------|
| `0x001` | FFLAGS | FP accrued exception flags: NX (bit 0), UF (bit 1), OF (bit 2), DZ (bit 3), NV (bit 4). Aliased from FCSR[4:0]. |
| `0x002` | FRM | FP rounding mode: RNE=0, RTZ=1, RDN=2, RUP=3, RMM=4. Aliased from FCSR[7:5]. |
| `0x003` | FCSR | Combined FFLAGS (bits 4:0) + FRM (bits 7:5). |
| `0x300` | MSTATUS | MIE (bit 3): global interrupt enable. MPIE (bit 7): saved MIE on trap entry. FS[1:0] (bits 14:13): FP state — Off=0, Initial=1, Clean=2, Dirty=3. |
| `0x301` | MISA | ISA. MXL=2 (64-bit). Extensions: I, M, A, F, D, C. |
| `0x304` | MIE | Interrupt enable mask. MTIE (bit 7) enables the machine timer interrupt. |
| `0x305` | MTVEC | Trap vector base address. Direct mode (`[1:0] = 2'b00`). |
| `0x340` | MSCRATCH | Scratch register for M-mode software. |
| `0x341` | MEPC | PC of the trapping instruction; restored by MRET. |
| `0x342` | MCAUSE | Trap cause. Bit 63 = 1 for interrupts, 0 for exceptions (64-bit register). |
| `0x344` | MIP | Interrupt pending (read-only). MTIP (bit 7). |

### MCAUSE Codes

| Code | Cause |
|------|-------|
| `0x0000000000000002` | Illegal instruction |
| `0x0000000000000003` | EBREAK |
| `0x000000000000000B` | ECALL from M-mode |
| `0x8000000000000007` | Machine timer interrupt |

---

## 12. Performance counters (Zicntr + partial Zihpm)

Stage 5c adds architectural performance counters so subsequent
microarchitectural changes (caches, MMU, OOO) can be measured
quantitatively.

**CSR additions** (all 64-bit on RV64):

| Address       | Name                | Access      | Notes                                                |
|---------------|---------------------|-------------|------------------------------------------------------|
| 0x320         | `mcountinhibit`     | M-mode RW   | Bit X gates increment of counter X (bit 0=mcycle, 2=minstret, 3..10=mhpmcounter3..10). |
| 0xB00         | `mcycle`            | M-mode RW   | Was read-only; now spec-compliant.                   |
| 0xB02         | `minstret`          | M-mode RW   | Was read-only; now spec-compliant.                   |
| 0xB03–0xB0A   | `mhpmcounter3..10`  | M-mode RW   | 8 programmable 64-bit event counters.                |
| 0xC03–0xC0A   | `hpmcounter3..10`   | U-mode RO   | Aliases of the M-mode counters.                      |
| 0x323–0x32A   | `mhpmevent3..10`    | M-mode RW   | Event-select; only bits [7:0] are meaningful.        |

**Event-ID table** (wired now; reserved IDs documented for later):

| ID    | Event                                       |
|-------|---------------------------------------------|
| 0x00  | No event (counter held)                     |
| 0x01  | Branch retired (conditional B-type)         |
| 0x02  | Branch mispredicted                         |
| 0x03  | Load retired                                |
| 0x04  | Store retired                               |
| 0x05  | AXI memory-stall cycle                      |
| 0x06  | Muldiv busy cycle                           |
| 0x07  | FPU busy cycle (any FPU unit busy)          |
| 0x08  | Trap or interrupt taken                     |
| 0x10–0x1F | reserved for future I$/D$/TLB miss, ROB full, IQ full, etc. |

The event bus is assembled in `rtl/stage5/kronos_top.sv` from the
existing pipeline signals (plus three small derivations:
`bpred_mispredict_pulse`, `fpu_busy_any`, `trap_taken_pulse`) and fed
into `kronos_csr` via the `event_bus_i [15:0]` input. Per-counter
increment logic in `kronos_csr` selects the bus line indexed by the
low 8 bits of `mhpmevent[i]` and is gated by `mcountinhibit[i]`. SW
writes to a counter on the same cycle as a selected event leave the
counter at the SW-written value (write wins).

**Pipeline-visibility delay:** CSR reads execute in EX, while events
fire in WB and the counter increment is registered. A `csrr` of a
counter sees the value flopped at the *previous* posedge — events
that retire in the same cycle as the read are not yet visible.
Software that wants an exact post-event count should leave ~2
instructions of slack between the event and the read (e.g. the asm
test in `sw/stage5/test_perf_counters.S` inserts two `nop`s before
its readback). This matches the standard RISC-V perf-counter
semantic; no forwarding path is provided.

See `docs/superpowers/specs/2026-04-26-perf-counters-design.md` for
the full design spec.

---

### Constrained-random verification (Stage 5d)

The CRV harness lives at `tools/crv/`.  A Python generator emits random
RV64IMAFDC programs across seven scenarios:

| Scenario             | Stresses                                              |
|----------------------|-------------------------------------------------------|
| `int_hazards`        | EX/MEM/WB forwarding, load-use, WB→ID bypass          |
| `muldiv_interleave`  | Multi-cycle stall protocol, muldiv forwarding         |
| `mem_ordering`       | LSU AXI4 protocol; plain LD/ST sequences (AMOs and LR/SC deferred — see notes) |
| `fp_arith`           | FPU dispatch, scoreboard, sticky FFLAGS               |
| `fdiv_fsqrt`         | Iterative FPU late-grant, back-pressure               |
| `branch_pred`        | Bpred + alignment buffer                              |
| `traps`              | CSR trap entry/exit, pipeline flush                   |

Each test compiles via the existing toolchain to a `.hex`, runs on
Kronos and Sail, and is diffed by `tools/trace_diff.py`.  A
SystemVerilog covergroup TB (`tb/stage5/tb_crv_cov.sv`) wraps the core
via the existing `retire_*` outputs and defines 82 bins covering
instruction class, ALU op × sign, branch type, memory size × alignment,
AMO type, FP rounding mode, and trap cause.  Coverage is computed via
manual bit-array tracking (Verilator 5.046's native covergroup support
is incomplete) and merged through `tools/crv_cov_merge.py`.  Bins random
can't reach have directed assist tests under `sw/stage5/crv_assists/`.

PR path runs `sim-crv-coverage` (smoke + assists, 100% gate after
exclusions).  Nightly runs `sim-crv-deep` (50 seeds × 7 scenarios,
opens an issue on failure).

Trap entry is surfaced to the coverage predicates via the dedicated
`retire_trap_taken_o` and `retire_trap_cause_o` outputs added in Stage
5d; the TB does not rely on `retire_csr_wen` to `mcause` for trap
detection.

**Known limitations** (tracked as exclusions in
`tools/crv/coverage_excludes.txt`):

- AMO retire-trace gap: `retire_mem_wen_o` does not assert for the
  write-back half of an AMO RMW operation.  All 12 AMO-related bins
  (`cg_instr_class.op_amo`, `cg_amo.*`) are excluded from the gate
  until the retire bus is extended to flag AMO writes.
- LR/SC (`cg_amo.lr`, `cg_amo.sc`): the Sail riscv reference model
  is built with `RsrvNone`, which disables reservation; LR/SC pairs
  cannot be randomly generated without diverging from Sail.
- SLT/SLTU result sign (`cg_alu_sign.slt_neg`, `cg_alu_sign.sltu_neg`):
  these instructions write exactly 0 or 1, so bit63 is always 0 and the
  `_neg` bins are structurally unreachable.
- Misalignment traps and unaligned accesses (`cg_trap.ld_misalign`,
  `cg_trap.st_misalign`, `cg_mem.half_odd`, `cg_mem.word_off2`,
  `cg_mem.word_odd`, `cg_mem.double_off4`, `cg_mem.double_off2`,
  `cg_mem.double_odd`): Stage 5 has no hardware misalignment support;
  misaligned accesses would trap, and the random-program trap handler
  only handles ECALL/EBREAK/IRQ.  These bins require a dedicated
  misalignment handler before they can be exercised.
- FENCE (`cg_instr_class.op_fence`): `kronos_decode` has no MISC_MEM
  case; FENCE and FENCE.I are treated as illegal instructions.  This
  bin is unreachable until FENCE decode support is added.

See `docs/superpowers/specs/2026-04-26-crv-harness-design.md` for the
full design.

### Instruction cache (Stage 5e)

A 16 KB, 4-way set-associative instruction cache between the fetch unit
and the AXI4 master.  Replaces the per-instruction fetch FSM that was in
place through Stage 5d.

**Organization:**

| Parameter        | Value                                               |
|------------------|-----------------------------------------------------|
| Total size       | 16 KB                                               |
| Associativity    | 4-way set-associative                               |
| Line size        | 64 bytes                                            |
| Sets             | 64                                                  |
| Replacement      | Tree-PLRU (3 bits/set)                              |
| Refill           | Critical-word-first via 8-beat AXI WRAP burst       |
| Hit latency      | 1 cycle (registered output)                         |
| Miss latency     | AXI ar→r latency + 1 cycle (CWF bypass)             |

**FENCE.I:** detected from raw instruction bits in `kronos_top.sv`
(`opcode == 7'b0001111 && funct3 == 3'b001`); not surfaced through the
decoder (decoder change broke the Zifencei ACT4 baseline; see commit
`87aac14`).  Asserts `flush_i` for one cycle, clearing all valid bits.

**Performance counter:** I$ miss → event ID `0x10` (the first event in
the reserved cache/MMU/OOO range from the Stage 5c spec).  Wired through
`event_bus[16]`; `event_bus` widened from 16 to 32 bits in this stage.

**AXI:** the AXI bus was widened from 32-bit to 64-bit (data + address)
as part of this work.  All AXI consumers (LSU, top, sim infrastructure)
were updated.  Single 64-bit beats serve 64-bit LD/SD; 32-bit accesses
occupy the appropriate 32-bit lane.

See `docs/superpowers/specs/2026-04-26-icache-design.md`.

### Data cache (Stage 5f)

A 16 KB, 4-way set-associative, write-back / write-allocate data cache
between `kronos_lsu` and the data AXI master.  Same organization as the
I-cache (Tree-PLRU, 8-beat AXI WRAP refill, CWF bypass) plus the write
side: per-line dirty bit, byte-strobed store path, dirty-eviction
writeback FSM (8-beat AXI INCR write burst), AMO read-modify-write
inside the cache, and a single LR/SC reservation register.

`kronos_lsu` was refactored from a full AXI master (~435 lines with
embedded AMO RMW + LR/SC) to a thin ~175-line adapter; the cache owns
the AXI master, AMO arithmetic, and reservation tracking.

| Parameter        | Value                                              |
|------------------|----------------------------------------------------|
| Total size       | 16 KB                                              |
| Associativity    | 4-way                                              |
| Line size        | 64 bytes / 8 beats × 64-bit                        |
| Sets             | 64                                                 |
| Replacement      | Tree-PLRU                                          |
| Write policy     | Write-back, write-allocate                         |
| Refill           | Critical-word-first via 8-beat AXI WRAP burst      |
| Eviction         | If victim dirty: 8-beat AXI INCR write burst       |
| Hit latency      | 1 cycle (registered)                               |

**AMO + LR/SC.** All A-extension instructions execute inside the cache.
AMO ops (AMOSWAP / ADD / AND / OR / XOR / MIN / MAX / MINU / MAXU, both
.W and .D) read the line, compute the new value, write it back, and
return the old value.  LR sets a single-pair reservation register; SC
checks the reservation and writes only on match.  The reservation is
cleared by SC (success or fail), an intervening plain store to the same
line, trap entry (via `rsrv_clear_i` from `trap_taken_pulse`), or reset.

**Performance counter.** D$ miss → event ID `0x11`, wired through
`event_bus[17]`.

**Sail diff.** AMO writes now surface in `retire_mem_wen_o` (a new
`is_amo_write` field in `mem_wb_reg_t`), resolving the Stage 5d gap that
forced AMOs to be excluded from the CRV `mem_ordering` scenario.  The
`cg_amo.*` exclusions in `tools/crv/coverage_excludes.txt` were removed
and AMOs were re-included in random testing.

See `docs/superpowers/specs/2026-04-27-dcache-design.md`.

---

## Debug — VCD signal groups

When debugging on a VCD dump in GTKWave/Surfer, the following signal groups
provide a curated view of pipeline state. All paths are relative to the
top-level `sim_top.u_top` (or `kronos_top` if dumping from a unit TB).

### fetch
- `pc_q` — current fetch PC
- `pc_next` — next-cycle PC (committed value)
- `align_instr` — aligned instruction byte stream
- `align_instr_valid` — valid alignment unit output
- `instr_fetch_stall` — alignment unit stalls fetch

### decode
- `if_id_q.instr` — fetched 32-bit instruction (post-decompression)
- `if_id_q.pc` — PC of decoded instruction
- `if_id_q.valid` — decode-stage register valid

### execute
- `id_ex_q.*` — full EX-stage register (decoded fields, rs1/rs2 data, fwd selects)
- `ex_redirect` — EX-stage taken-branch / trap / mret redirect
- `ex_pc_next` — redirect target
- `combined_stall` — pipeline freeze (any source)
- `mem_stall` — memory subsystem stall (LSU + dcache + fence.i drain)

### mem
- `ex_mem_q.*` — full MEM-stage register
- `lsu_mem_stall` — LSU bus wait
- `dcache_stall` — D-cache FSM busy

### regfile
- `u_regfile.regs[]` — 32 × 64-bit integer GPRs
- `u_regfile_fp.regs[]` — 32 × 64-bit FP GPRs
- `u_regfile.we` / `u_regfile.wd` / `u_regfile.wa` — write port
- `u_regfile_fp.we` / `u_regfile_fp.wd` / `u_regfile_fp.wa` — FP write port

### caches
- `icache_*` — full I-cache subhierarchy (FSM state, way valid, miss pulse)
- `dcache_*` — full D-cache subhierarchy
- `fence_i_active_q` — FENCE.I in-flight (D-cache flush window)

### trap
- `trap_taken_pulse` — pulses high on the cycle a trap is committed
- `trap_cause` — current cycle's trap cause (only valid when pulse is high)
- `mcause` / `mepc` — register state after trap entry

### events
- `event_bus[31:0]` — Zihpm event bus; bit positions documented in `kronos_pkg.sv` `EVT_*` constants

---

## Debug — OoO debug surface (Stage 6 reservation)

Stage 5h reserves the following hierarchical paths for the upcoming Stage 6
(BOOM-style OoO) debug surface. None of the modules listed below exist yet
in Stage 5g/5h; this is purely a forward-looking convention so sim-side
inspectors will not need RTL changes when they're introduced.

| Path             | Purpose                                                |
|------------------|--------------------------------------------------------|
| `u_top.u_rob.*`  | Reorder buffer — entries, head/tail, retire mask       |
| `u_top.u_iq.*`   | Issue queue — entries, ready bits, age                 |
| `u_top.u_lsq.*`  | Load/store queue — entries, age, completion mask       |
| `u_top.u_rat.*`  | Register alias table — logical → physical mapping      |

A stub file `sim/sim_ooo_inspect.cpp` reserves the namespace
`kronos_ooo_inspect::` for the dumper entry points that Stage 6 will define.
