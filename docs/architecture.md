# kronos-riscv Architecture Reference

**Active stage:** Stage 2 (RV32IM)

Narrative documentation: [Stage 0](stage0.md) | [Stage 1](stage1.md) | [Stage 2](stage2.md)

---

## Module Hierarchy

### Stage 0 — Single-Cycle

```
kronos_top  (rtl/stage0/kronos_top.sv)
├── u_decode    kronos_decode   (rtl/stage0/kronos_decode.sv)    combinational
├── u_regfile   kronos_regfile  (rtl/stage0/kronos_regfile.sv)   sequential
├── u_alu       kronos_alu      (rtl/stage0/kronos_alu.sv)       combinational
├── u_lsu       kronos_lsu      (rtl/stage0/kronos_lsu.sv)       sequential
└── u_csr       kronos_csr      (rtl/stage0/kronos_csr.sv)       sequential
```

### Stage 1 — 5-Stage Pipeline

```
kronos_top  (rtl/stage1/kronos_top.sv)
├── u_decode    kronos_decode   (rtl/stage0/kronos_decode.sv)    reused
├── u_regfile   kronos_regfile  (rtl/stage0/kronos_regfile.sv)   reused
├── u_alu       kronos_alu      (rtl/stage0/kronos_alu.sv)       reused
├── u_csr       kronos_csr      (rtl/stage0/kronos_csr.sv)       reused
├── u_lsu       kronos_lsu      (rtl/stage1/kronos_lsu.sv)       updated: mem_stall_o
├── u_forward   kronos_forward  (rtl/stage1/kronos_forward.sv)   new
└── u_hazard    kronos_hazard   (rtl/stage1/kronos_hazard.sv)    new
```

### Stage 2 — RV32IM

```
kronos_top  (rtl/stage2/kronos_top.sv)
├── u_decode    kronos_decode   (rtl/stage2/kronos_decode.sv)    updated: M-ext
├── u_regfile   kronos_regfile  (rtl/stage0/kronos_regfile.sv)   reused
├── u_alu       kronos_alu      (rtl/stage0/kronos_alu.sv)       reused
├── u_csr       kronos_csr      (rtl/stage0/kronos_csr.sv)       reused (MISA_EXT=I+M)
├── u_lsu       kronos_lsu      (rtl/stage1/kronos_lsu.sv)       reused
├── u_forward   kronos_forward  (rtl/stage1/kronos_forward.sv)   reused
├── u_hazard    kronos_hazard   (rtl/stage1/kronos_hazard.sv)    reused
└── u_muldiv    kronos_muldiv   (rtl/stage2/kronos_muldiv.sv)    new
```

---

## `kronos_top` Interface (All Stages)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk_i` | in | 1 | Rising-edge clock |
| `rst_ni` | in | 1 | Async active-low reset |
| `instr_req_o` | out | 1 | OBI instruction fetch request |
| `instr_gnt_i` | in | 1 | OBI instruction fetch grant |
| `instr_rvalid_i` | in | 1 | OBI instruction fetch response valid |
| `instr_addr_o` | out | 32 | Instruction fetch address (= PC) |
| `instr_rdata_i` | in | 32 | Fetched instruction word |
| `instr_err_i` | in | 1 | Fetch error (unused in stages 0–2) |
| `data_req_o` | out | 1 | OBI data request |
| `data_gnt_i` | in | 1 | OBI data grant |
| `data_rvalid_i` | in | 1 | OBI data response valid |
| `data_we_o` | out | 1 | Write enable (1 = store) |
| `data_be_o` | out | 4 | Byte enable mask |
| `data_addr_o` | out | 32 | Data address |
| `data_wdata_o` | out | 32 | Write data |
| `data_rdata_i` | in | 32 | Read data |
| `data_err_i` | in | 1 | Data error (unused in stages 0–2) |
| `irq_timer_i` | in | 1 | M-mode timer interrupt |
| `irq_fast_i` | in | 15 | Fast interrupts |
| `boot_addr_i` | in | 32 | Reset value for PC |

---

## `kronos_decode` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `instr_i` | in | 32 | Raw instruction word |
| `dec_o` | out | `decoded_instr_t` | Decoded instruction struct |

Stage 0 (`rtl/stage0/kronos_decode.sv`): RV32I only.
Stage 2 (`rtl/stage2/kronos_decode.sv`): RV32I + M. M instructions use opcode
`OP` (7'b0110011) with `funct7 = 7'b0000001`.

---

## `kronos_regfile` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk_i` | in | 1 | Clock |
| `rs1_addr_i` | in | 5 | RS1 read address |
| `rs2_addr_i` | in | 5 | RS2 read address |
| `rs1_rdata_o` | out | 64 | RS1 read data (asynchronous) |
| `rs2_rdata_o` | out | 64 | RS2 read data (asynchronous) |
| `rd_addr_i` | in | 5 | Write address |
| `rd_wen_i` | in | 1 | Write enable |
| `rd_wdata_i` | in | 64 | Write data |

Reads are asynchronous. Writes are synchronous (rising edge). x0 reads return 0;
writes to x0 are ignored.

---

## `kronos_alu` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `op_i` | in | `alu_op_e` (4-bit) | Operation select |
| `a_i` | in | 32 | Operand A |
| `b_i` | in | 32 | Operand B |
| `result_o` | out | 32 | Result |

`alu_op_e` values: `ALU_ADD=0`, `ALU_SUB=1`, `ALU_SLL=2`, `ALU_SLT=3`,
`ALU_SLTU=4`, `ALU_XOR=5`, `ALU_SRL=6`, `ALU_SRA=7`, `ALU_OR=8`, `ALU_AND=9`,
`ALU_PASSB=10`.

---

## `kronos_lsu` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk_i` | in | 1 | Clock |
| `rst_ni` | in | 1 | Reset |
| `req_i` | in | 1 | Start a load or store |
| `we_i` | in | 1 | Write enable (1 = store) |
| `addr_i` | in | 32 | Memory address |
| `wdata_i` | in | 32 | Store write data |
| `funct3_i` | in | 3 | Width + sign encoding |
| `rdata_o` | out | 32 | Load data (sign/zero extended) |
| `valid_o` | out | 1 | Transaction complete this cycle |
| `mem_stall_o` | out | 1 | **Stage 1+ only.** Pipeline must stall |
| `data_req_o` | out | 1 | OBI data request |
| `data_gnt_i` | in | 1 | OBI data grant |
| `data_rvalid_i` | in | 1 | OBI data response valid |
| `data_we_o` | out | 1 | OBI write enable |
| `data_be_o` | out | 4 | OBI byte enable |
| `data_addr_o` | out | 32 | OBI address |
| `data_wdata_o` | out | 32 | OBI write data |
| `data_rdata_i` | in | 32 | OBI read data |
| `data_err_i` | in | 1 | OBI error (unused) |

---

## `kronos_csr` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk_i` | in | 1 | Clock |
| `rst_ni` | in | 1 | Reset |
| `req_i` | in | 1 | CSR access request |
| `addr_i` | in | 12 | CSR address |
| `funct3_i` | in | 3 | Operation (CSRRW/CSRRS/CSRRC + immediate variants) |
| `use_imm_i` | in | 1 | Use `rs1_addr_i` as zimm (CSRRWI/CSRRSI/CSRRCI) |
| `rs1_data_i` | in | 32 | RS1 value |
| `rs1_addr_i` | in | 5 | RS1 address (zimm source for immediate variants) |
| `rdata_o` | out | 32 | CSR read value |
| `valid_o` | out | 1 | Access complete |
| `trap_i` | in | 1 | Trap entry request |
| `trap_pc_i` | in | 32 | PC of trapping instruction (→ MEPC) |
| `trap_cause_i` | in | 32 | Trap cause code (→ MCAUSE) |
| `mret_i` | in | 1 | MRET instruction |
| `trap_vector_o` | out | 32 | Trap handler address (from MTVEC) |
| `mepc_o` | out | 32 | Exception return address |
| `irq_timer_i` | in | 1 | Timer interrupt input |
| `irq_fast_i` | in | 15 | Fast interrupt inputs |
| `irq_pending_o` | out | 1 | Interrupt pending and enabled |
| `MISA_EXT` | param | 26 | ISA extension bits in MISA (default: I only) |

---

## `kronos_forward` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `id_ex_rs1_i` | in | 5 | RS1 address of instruction in EX |
| `id_ex_rs1_used_i` | in | 1 | EX instruction reads RS1 |
| `id_ex_rs2_i` | in | 5 | RS2 address of instruction in EX |
| `id_ex_rs2_used_i` | in | 1 | EX instruction reads RS2 |
| `ex_mem_rd_i` | in | 5 | RD of instruction in MEM |
| `ex_mem_rd_wen_i` | in | 1 | MEM instruction writes RD |
| `ex_mem_is_load_i` | in | 1 | MEM instruction is a load |
| `mem_wb_rd_i` | in | 5 | RD of instruction in WB |
| `mem_wb_rd_wen_i` | in | 1 | WB instruction writes RD |
| `fwd_rs1_sel_o` | out | `fwd_sel_e` | Forward select for RS1 |
| `fwd_rs2_sel_o` | out | `fwd_sel_e` | Forward select for RS2 |

`FWD_EXMEM` is suppressed when `ex_mem_is_load_i=1`. All forwarding suppressed
when `rd=5'd0`.

---

## `kronos_hazard` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `id_ex_is_load_i` | in | 1 | Instruction in EX is a load |
| `id_ex_rd_i` | in | 5 | RD of instruction in EX |
| `id_ex_valid_i` | in | 1 | EX stage contains a valid instruction |
| `if_id_rs1_used_i` | in | 1 | ID instruction reads RS1 |
| `if_id_rs1_i` | in | 5 | RS1 of instruction in ID |
| `if_id_rs2_used_i` | in | 1 | ID instruction reads RS2 |
| `if_id_rs2_i` | in | 5 | RS2 of instruction in ID |
| `ex_redirect_i` | in | 1 | EX resolved a redirect |
| `mem_stall_i` | in | 1 | MEM (or muldiv in stage 2) is stalling |
| `pc_en_o` | out | 1 | Enable PC update |
| `if_id_en_o` | out | 1 | Enable IF/ID update |
| `id_ex_en_o` | out | 1 | Enable ID/EX update |
| `ex_mem_en_o` | out | 1 | Enable EX/MEM update |
| `mem_wb_en_o` | out | 1 | Enable MEM/WB update |
| `if_id_flush_o` | out | 1 | Clear IF/ID to NOP |
| `id_ex_flush_o` | out | 1 | Clear ID/EX to NOP |

In Stage 2, `mem_stall_i` receives `mem_stall | muldiv_stall`.

---

## `kronos_muldiv` Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk_i` | in | 1 | Clock |
| `rst_ni` | in | 1 | Reset |
| `req_i` | in | 1 | Start operation (pulse once; only valid when `idle_o=1`) |
| `op_i` | in | `muldiv_op_e` (3-bit) | Operation |
| `a_i` | in | 32 | Operand A |
| `b_i` | in | 32 | Operand B |
| `result_o` | out | 32 | Result |
| `busy_o` | out | 1 | Computing |
| `valid_o` | out | 1 | Result ready this cycle |
| `idle_o` | out | 1 | Ready to accept new operation |

`muldiv_op_e`: `MULDIV_MUL=0`, `MULDIV_MULH=1`, `MULDIV_MULHSU=2`,
`MULDIV_MULHU=3`, `MULDIV_DIV=4`, `MULDIV_DIVU=5`, `MULDIV_REM=6`,
`MULDIV_REMU=7`.

---

## Pipeline Register Definitions (`rtl/kronos_pkg.sv`)

### `if_id_reg_t`

| Field | Type | Description |
|-------|------|-------------|
| `pc` | `logic [31:0]` | PC of the fetched instruction |
| `instr` | `logic [31:0]` | Raw instruction word |
| `valid` | `logic` | Stage contains a valid instruction |

### `id_ex_reg_t`

| Field | Type | Description |
|-------|------|-------------|
| `pc` | `logic [31:0]` | PC |
| `dec` | `decoded_instr_t` | Decoded instruction |
| `rs1_data` | `logic [31:0]` | RS1 value (WB→ID bypass applied) |
| `rs2_data` | `logic [31:0]` | RS2 value |
| `valid` | `logic` | Valid instruction |

### `ex_mem_reg_t`

| Field | Type | Description |
|-------|------|-------------|
| `pc` | `logic [31:0]` | PC |
| `dec` | `decoded_instr_t` | Decoded instruction |
| `alu_result` | `logic [31:0]` | ALU/muldiv result; also load/store address |
| `rs2_data` | `logic [31:0]` | Store write data |
| `pc_next` | `logic [31:0]` | Resolved redirect target |
| `csr_rdata` | `logic [31:0]` | CSR read value |
| `redirect` | `logic` | EX is redirecting the PC |
| `valid` | `logic` | Valid instruction |

### `mem_wb_reg_t`

| Field | Type | Description |
|-------|------|-------------|
| `dec` | `decoded_instr_t` | Decoded instruction |
| `alu_result` | `logic [31:0]` | ALU/muldiv result |
| `lsu_rdata` | `logic [31:0]` | Load data (sign/zero extended) |
| `csr_rdata` | `logic [31:0]` | CSR read value |
| `pc4` | `logic [31:0]` | PC+4 for JAL/JALR link address |
| `valid` | `logic` | Valid instruction |

---

## `decoded_instr_t` Field Reference

| Field | Type | Description |
|-------|------|-------------|
| `rs1` | `logic [4:0]` | RS1 register address |
| `rs2` | `logic [4:0]` | RS2 register address |
| `rd` | `logic [4:0]` | Destination register address |
| `rs1_used` | `logic` | RS1 is a valid read source |
| `rs2_used` | `logic` | RS2 is a valid read source |
| `rd_wen` | `logic` | Write result to rd |
| `alu_op` | `alu_op_e` | ALU operation |
| `imm` | `logic [31:0]` | Sign-extended immediate |
| `use_imm` | `logic` | Use `imm` as ALU B-operand (else RS2) |
| `use_pc` | `logic` | Use PC as ALU A-operand (AUIPC) |
| `is_load` | `logic` | Load instruction |
| `is_store` | `logic` | Store instruction |
| `mem_funct3` | `logic [2:0]` | Load/store width and sign |
| `is_branch` | `logic` | Branch instruction |
| `branch_funct3` | `logic [2:0]` | Branch condition |
| `is_jal` | `logic` | JAL |
| `is_jalr` | `logic` | JALR |
| `is_csr` | `logic` | CSR access |
| `csr_addr` | `logic [11:0]` | CSR address |
| `csr_funct3` | `logic [2:0]` | CSR operation |
| `csr_use_imm` | `logic` | CSRRWI/CSRRSI/CSRRCI zimm mode |
| `is_ecall` | `logic` | ECALL |
| `is_ebreak` | `logic` | EBREAK |
| `is_mret` | `logic` | MRET |
| `is_muldiv` | `logic` | M-extension instruction (stages 0/1 always 0) |
| `muldiv_op` | `muldiv_op_e` | Multiply/divide operation |
| `wb_sel` | `wb_sel_e` | Writeback source: `WB_ALU`, `WB_MEM`, `WB_PC4`, `WB_CSR` |
| `illegal` | `logic` | Unrecognised instruction |

---

## Hazard Priority Table

| Priority | Condition | `pc_en` | `if_id_en` | `id_ex_en` | `ex_mem_en` | `mem_wb_en` | `if_id_flush` | `id_ex_flush` |
|----------|-----------|:-------:|:----------:|:----------:|:-----------:|:-----------:|:-------------:|:-------------:|
| 1 (highest) | `mem_stall_i=1` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 2 | Load-use¹ | 0 | 0 | 0 | 1 | 1 | 0 | 1 |
| 3 | `ex_redirect_i=1` | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| 4 (lowest) | None | 1 | 1 | 1 | 1 | 1 | 0 | 0 |

¹ Load-use condition: `id_ex_valid & id_ex_is_load & id_ex_rd≠0` and `id_ex_rd`
matches `if_id_rs1` (when `rs1_used`) or `if_id_rs2` (when `rs2_used`).

In Stage 2 `mem_stall_i = mem_stall | muldiv_stall`.

---

## Timing Table

| Instruction class | Stage 0 | Stage 1 | Stage 2 |
|-------------------|:-------:|:-------:|:-------:|
| ALU / logic / not-taken branch | 1 | 1 | 1 |
| Taken branch / JAL / JALR | 1 | 3 | 3 |
| Load-use (load then dependent) | n/a | 3 | 3 |
| Load/store (gnt+rvalid same cycle) | 1 | 1 | 1 |
| Load/store (rvalid one cycle after gnt) | 2 | 2 | 2 |
| ECALL / EBREAK / illegal / MRET / interrupt | 1 | 3 | 3 |
| MUL / MULH / MULHSU / MULHU | — | — | 2 |
| DIV / REM (normal case, 32 iterations) | — | — | 34 |
| DIV / REM (edge case: ÷0 or INT_MIN÷−1) | — | — | 2 |

Cycles measured from instruction entering EX to result available in WB.

---

## Stage Cross-Reference

| File | Introduced | Reused by |
|------|-----------|-----------|
| `rtl/kronos_pkg.sv` | Stage 0 | Stages 1, 2 |
| `rtl/stage0/kronos_top.sv` | Stage 0 | — |
| `rtl/stage0/kronos_decode.sv` | Stage 0 | Stage 1 |
| `rtl/stage0/kronos_regfile.sv` | Stage 0 | Stages 1, 2 |
| `rtl/stage0/kronos_alu.sv` | Stage 0 | Stages 1, 2 |
| `rtl/stage0/kronos_lsu.sv` | Stage 0 | — |
| `rtl/stage0/kronos_csr.sv` | Stage 0 | Stages 1, 2 |
| `rtl/stage1/kronos_top.sv` | Stage 1 | — |
| `rtl/stage1/kronos_lsu.sv` | Stage 1 | Stage 2 |
| `rtl/stage1/kronos_forward.sv` | Stage 1 | Stage 2 |
| `rtl/stage1/kronos_hazard.sv` | Stage 1 | Stage 2 |
| `rtl/stage2/kronos_top.sv` | Stage 2 | — |
| `rtl/stage2/kronos_decode.sv` | Stage 2 | — |
| `rtl/stage2/kronos_muldiv.sv` | Stage 2 | — |

---

## OBI Protocol Summary

### Single-cycle response (gnt and rvalid same cycle)

```wavedrom
{ "signal": [
  { "name": "clk",    "wave": "P..." },
  { "name": "req",    "wave": "0100" },
  { "name": "gnt",    "wave": "0100" },
  { "name": "rvalid", "wave": "0100" },
  { "name": "rdata",  "wave": "x=xx", "data": ["D"] }
]}
```

### Two-cycle response (rvalid one cycle after gnt)

```wavedrom
{ "signal": [
  { "name": "clk",      "wave": "P...." },
  { "name": "req",      "wave": "01000" },
  { "name": "gnt",      "wave": "01000" },
  { "name": "rvalid",   "wave": "00100" },
  { "name": "rdata",    "wave": "xx=xx", "data": ["D"] },
  { "name": "mem_stall","wave": "01000" }
]}
```

The core holds `req` high until `gnt`. A two-cycle response triggers one cycle
of `mem_stall`. OBI always has a response phase — the LSU waits for `rvalid`
on stores as well as loads.

---

## CSR Register Map

| Address | Name | Description |
|---------|------|-------------|
| `0x300` | MSTATUS | MIE (bit 3): global interrupt enable. MPIE (bit 7): saved MIE. |
| `0x301` | MISA | ISA. Bits [25:0] = `MISA_EXT` parameter. |
| `0x304` | MIE | Interrupt enable mask. MTIE (bit 7). |
| `0x305` | MTVEC | Trap vector base. Direct mode (`[1:0]=0`). |
| `0x340` | MSCRATCH | Scratch for M-mode software. |
| `0x341` | MEPC | PC saved on trap entry; restored by MRET. |
| `0x342` | MCAUSE | Trap cause. Bit 31=1 for interrupts. |
| `0x344` | MIP | Interrupt pending (read-only). MTIP (bit 7). |

### MCAUSE codes

| Code | Cause |
|------|-------|
| `0x00000002` | Illegal instruction |
| `0x00000003` | EBREAK |
| `0x0000000B` | ECALL from M-mode |
| `0x80000007` | Machine timer interrupt |

---

## Roadmap — Stages 3–6

### Stage 3 — C Extension + Branch Predictor (RV32IMC)

Adds 16-bit compressed instructions and a bimodal branch predictor. The IF stage
must pre-decode instruction width (`inst[1:0]`) to advance the PC by 2 or 4 bytes.
All 16-bit encodings expand to their 32-bit equivalents before reaching `kronos_decode`.
The predictor speculatively redirects fetch; a misprediction still costs 2 cycles.

### Stage 4 — RV64I + A Extension (RV64IMAC)

Widens the ISA to 64 bits. The register file is already 64-bit; Stage 4 activates
the upper half with W-suffix instructions (ADDW, SUBW, etc.) and 64-bit
loads/stores (LD, SD) via two consecutive 32-bit OBI transactions.
Atomics (LR/SC and AMOs) are implemented in the LSU using a reservation register.

### Stage 5 — F/D Extensions (RV64IMAFDС)

Adds IEEE 754 single and double precision. A separate 32×64-bit FP register file
and four multi-cycle execution units (adder, multiplier, divider, converter).
Hazard logic is extended for FP→FP and FP→integer forwarding paths. FCSR, FFLAGS,
and FRM CSRs are added.

### Stage 6 — Out-of-Order Execution (RV64IMAFDС, AXI4)

Replaces the in-order backend with a BOOM-class engine: register rename with a
free list and map table, a reorder buffer for in-order commit, per-unit issue
queues with wakeup/select, and a load/store queue with store-to-load forwarding.
The bus interface changes from OBI to native AXI4 to support multiple outstanding
memory requests. This is the culmination of the learning progression.
