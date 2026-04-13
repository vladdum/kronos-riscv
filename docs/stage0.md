# Stage 0: The Single-Cycle Core

**ISA:** RV32I | **Status:** Complete | **Source:** `rtl/stage0/`

---

## What We're Building

A CPU must do one thing repeatedly: fetch the next instruction from memory,
figure out what it means, act on it, and move to the next instruction. Every
CPU ever built is a variation on this loop.

Stage 0 implements that loop in its most direct form — every instruction
completes in a single clock cycle. Fetch, decode, execute, and write the result
all happen between two clock edges. There is no overlap, no speculation, no
queueing.

This simplicity serves an important purpose. Stage 0 is the **golden model**: a
reference implementation whose output is known to be correct. Every later stage
must produce the same register state as Stage 0 at every instruction boundary.

---

## Module Tour

The five modules that make up Stage 0 each own one slice of the execution loop.

### `kronos_decode` — Instruction Decode

`kronos_decode` takes a 32-bit instruction word and produces a `decoded_instr_t`
struct. It is purely combinational — no state, no clock.

RV32I uses six instruction formats (R, I, S, B, U, J) that place the opcode,
register addresses, and immediate in slightly different bit positions.
`kronos_decode` normalises all of this: it extracts `rs1`, `rs2`, `rd`,
sign-extends the immediate to 32 bits, selects the ALU operation, and sets a
flag for every property the rest of the core cares about — `is_load`,
`is_store`, `is_branch`, `rd_wen`, and so on.

The `decoded_instr_t` struct is defined in `rtl/kronos_pkg.sv` and used by all
stages.

### `kronos_regfile` — Register File

Holds the 32 general-purpose integer registers (x0–x31). Two asynchronous read
ports and one synchronous write port operate simultaneously. x0 is hardwired to
zero — writes to it are silently ignored, reads always return 0.

The register file is **64 bits wide** even in Stage 0, which only implements
RV32I. This is a deliberate choice: widening the register file at Stage 4 (when
RV64I is added) would require touching every stage's datapath. Allocating 64-bit
entries now means Stage 4 is a matter of using the upper bits rather than
reshaping the whole design.

### `kronos_alu` — Arithmetic Logic Unit

Computes one of eleven operations selected by `alu_op_e`: ADD, SUB, SLL, SLT,
SLTU, XOR, SRL, SRA, OR, AND, and PASSB. PASSB passes the B operand unchanged —
used by LUI, which loads a 20-bit immediate into the upper bits of a register
without any arithmetic.

Signed operations (SLT, SRA) use `$signed()` casts to treat the 32-bit vectors
as two's-complement values.

### `kronos_lsu` — Load/Store Unit

Handles all memory accesses by translating requests into OBI bus transactions.
`funct3` encodes both the access width and whether to sign-extend the result:

| `funct3` | Operation | Extension |
|----------|-----------|-----------|
| `000` | LB / SB | Signed |
| `001` | LH / SH | Signed |
| `010` | LW / SW | Signed |
| `100` | LBU | Zero |
| `101` | LHU | Zero |

The Stage 0 LSU handles the OBI handshake. The core is inherently stalled during
a memory transaction because it never commits an instruction until the response
arrives. Stage 1 adds an explicit `mem_stall_o` signal to allow the pipeline to
make progress in other stages while MEM waits.

### `kronos_csr` — Control and Status Registers

Implements the M-mode CSRs required by the RISC-V privileged specification:

| CSR | Address | Purpose |
|-----|---------|---------|
| MSTATUS | `0x300` | Machine status (MIE, MPIE bits) |
| MISA | `0x301` | ISA and extensions supported |
| MIE | `0x304` | Interrupt enable mask |
| MTVEC | `0x305` | Trap handler base address |
| MSCRATCH | `0x340` | Scratch register for M-mode |
| MEPC | `0x341` | Exception program counter |
| MCAUSE | `0x342` | Trap cause code |
| MIP | `0x344` | Interrupt pending bits (read-only) |

On a trap, the CSR saves the faulting PC into MEPC, writes MCAUSE, and outputs
the trap vector address. MRET reads MEPC and outputs it as the return address.

`kronos_csr` also tracks `irq_pending_o` (MIE + MIP logic for timer and fast
interrupts), but Stage 0's top-level does not act on it — there is no
interrupt-driven PC redirect in the single-cycle model. Interrupt handling is
wired up from Stage 1 onward.

The `MISA_EXT` parameter controls which extension bits appear in MISA. Stage 0
uses the default (I only). Stage 2 passes `26'h1100` to advertise I+M.

---

## Datapath Walkthrough

### `ADD x3, x1, x2`

1. `instr_req_o` is high. The instruction address (PC) is on `instr_addr_o`.
2. `instr_rvalid_i` fires with the instruction word.
3. `kronos_decode` produces: `alu_op=ALU_ADD`, `rs1=1`, `rs2=2`, `rd=3`,
   `use_imm=0`, `use_pc=0`, `rd_wen=1`, `wb_sel=WB_ALU`.
4. `kronos_regfile` reads x1 and x2 asynchronously.
5. ALU receives `a=rs1_data[31:0]`, `b=rs2_data[31:0]`, `op=ALU_ADD`. Outputs `a+b`.
6. Writeback mux selects `WB_ALU`. Result is sign-extended to 64 bits
   (`{{32{result[31]}}, result}`) and written to x3.
7. PC advances to `PC + 4`.

### `LW x4, 8(x1)`

1. Decode produces: `alu_op=ALU_ADD`, `rs1=1`, `imm=8`, `use_imm=1`,
   `is_load=1`, `mem_funct3=3'b010`, `rd=4`, `wb_sel=WB_MEM`.
2. ALU computes `rs1_data[31:0] + 8` — the effective address.
3. LSU issues an OBI read: `data_req_o=1`, `data_addr_o=effective_address`.
4. On `data_rvalid_i`, `data_rdata_i` holds the 32-bit word. The LSU returns
   it as-is; the writeback mux sign-extends it to 64 bits
   (`{{32{lsu_rdata[31]}}, lsu_rdata}`) before writing to x4.
5. Writeback selects `WB_MEM`. x4 is written.

### `BEQ x1, x2, label`

1. Decode produces: `is_branch=1`, `branch_funct3=3'b000`, `rs1=1`, `rs2=2`,
   `imm=offset`, `rd_wen=0`.
2. Branch comparator evaluates `rs1_data[31:0] == rs2_data[31:0]`.
3. If equal: `pc_next = PC + imm`. If not: `pc_next = PC + 4`.
4. No register write.

---

## Control Flow and the PC

`pc_next` is selected by a priority chain:

| Priority | Condition | `pc_next` |
|----------|-----------|-----------|
| 1 (highest) | Trap (ECALL, EBREAK, illegal) | `trap_vector` (MTVEC) |
| 2 | MRET | `mepc` |
| 3 | JAL | `PC + imm` |
| 4 | JALR | `(rs1 + imm) & ~32'd1` |
| 5 | Branch taken | `PC + imm` |
| 6 (lowest) | Default | `PC + 4` |

MCAUSE codes written on trap:

| Code | Cause |
|------|-------|
| `0x00000002` | Illegal instruction |
| `0x00000003` | EBREAK |
| `0x0000000B` | ECALL from M-mode |

The PC register updates only when `instr_rvalid_i` is high. If the memory bus
holds off the response, the PC stays frozen.

---

## The OBI Bus

OBI (Open Bus Interface) uses a three-signal handshake on each port:

```
Requester              Memory
    |--- req, addr --->|
    |<-- gnt ----------|   (address captured; may be same cycle as req)
    |<-- rvalid, data -|   (response data ready)
```

The core holds `req` high until `gnt`. OBI mandates a response phase for every
transaction including writes — the LSU waits for `rvalid` on stores as well as
loads.

The simulation model in `sim/sim_main.cpp` asserts `gnt` and `rvalid` on the
same cycle as `req`. Real SoC memory may take additional cycles.

---

## Where This Breaks Down

The single-cycle clock must cover the longest combinational path: fetch address →
memory → decode → register read → ALU → memory access → writeback. Every
instruction shares the same worst-case clock, even if it doesn't use every stage.

More fundamentally, the core is idle for most of each cycle: the decoder does
nothing while the ALU is running; the ALU does nothing during a load. A pipeline
overlaps these idle periods, putting multiple instructions in flight at once.

That is what Stage 1 builds.
