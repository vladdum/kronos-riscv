# kronos-riscv Architecture Reference

**ISA:** RV64IMAFDC &nbsp;|&nbsp; **Microarchitecture:** 9-stage in-order pipeline — register-read stage and split EX/MEM boundaries for the Fmax push, see §1 &nbsp;|&nbsp; **Bus:** AXI4 &nbsp;|&nbsp; **Branch prediction:** bimodal (64-entry PHT + 16-entry BTB)

kronos-riscv is a 9-stage in-order RISC-V processor implementing the RV64IMAFDC ISA. A BOOM-style frontend — a pipelined instruction cache, a fetch buffer, and a predecode block that also owns RVC decompression — feeds Instruction Decode (ID) and Register-Read (RR); RR performs the integer and FP register-file reads and the operand-bypass mux, so Execute consumes only flop outputs. Execute is split into EX1 (ALU/AGU, muldiv dispatch, branch-direction compare, CSR read-modify-write, FPU dispatch) and EX2 (fault aggregation and direction-mispredict redirect formation). Memory access is split into MEM1 (dTLB lookup start), MEM1B (the dTLB's internal encode sub-stage, where the translated PA and perm-fail/miss/A/D-bit outputs become live), and MEM2 (data-side PMP check, dcache hit/data, target-mispredict and trap redirect formation), followed by Writeback (WB). Every fault source — illegal instruction, ECALL/EBREAK, CSR/privilege failures, PMP, page faults, trigger hits — writes exactly one bit into a `fault_t` struct that is registered one stage past its producer; the two redirect points (EX2 for direction mispredicts, MEM2 for everything else) OR-reduce only registered bits, so no fault ever reaches a consumer combinationally. A separate FPU with six pipelined units handles the F and D extensions and dispatches from EX1; a writeback-slot scoreboard, not the integer forwarding network, arbitrates its shared result port. `kronos_hazard` and `kronos_forward` sit outside the pipeline stages and manage stalls, flushes, and a six-producer-slot operand-forwarding network.

```mermaid
%% depicts: stage7e
flowchart LR
    instr_axi{{Instr AXI4}} --> IF["IF: icache s0/s1/s2 → fetch buffer → predecode"]
    IF --> if_id[if_id_q] --> ID --> id_rr[id_rr_q] --> RR --> rr_ex1[rr_ex1_q] --> EX1 --> ex1_ex2[ex1_ex2_q] --> EX2 --> ex2_mem1[ex2_mem1_q] --> MEM1 --> mem1_mem1b[mem1_mem1b_q] --> MEM1B --> mem1_mem2[mem1_mem2_q] --> MEM2 --> mem_wb[mem_wb_q] --> WB
    MEM2 --> data_axi{{Data AXI4}}
    bpred["bpred — bimodal PHT + BTB"] -. predict .-> IF
    EX1 -. update .-> bpred
    irq{{IRQ}} -. sampled .-> EX1
    EX2 -. "direction redirect" .-> IF
    MEM2 -. "target / trap redirect" .-> IF
    ctrl["Control: kronos_hazard + kronos_forward"] -.-> id_rr & rr_ex1 & ex1_ex2 & ex2_mem1 & mem1_mem1b & mem1_mem2
    EX1 -. dispatch .-> fpu["FPU — 6 units + scoreboard"]
    fpu -.-> regfile_fp["regfile_fp — 32×64b FP"]
    WB -. "FP WB (FLW/FLD)" .-> regfile_fp
```

The nine pipeline registers — `if_id_q`, `id_rr_q`, `rr_ex1_q`, `ex1_ex2_q`, `ex2_mem1_q`, `mem1_mem1b_q`, `mem1_mem2_q`, `mem_wb_q` — carry decoded instruction state across stages. Names follow a `{producer stage}_{consumer stage}` convention, with one quirk worth knowing when reading the RTL: the MEM1B→MEM2 register is `mem1_mem2_q`, not `mem1b_mem2_q` — MEM1B is the dTLB's internal S1 (encode) sub-stage rather than a distinct producer name, and its register type comment describes it as "passed through MEM1B→MEM2 with PMP/PMA bits filled in." Each register has an `en` enable and a `flush` (clear-to-NOP) control driven by `kronos_hazard`. Operand forwarding is handled by `kronos_forward`, which selects among six producer slots — `FWD_EX1_NOW`, `FWD_EX1`, `FWD_EXMEM`, `FWD_MEM1B`, `FWD_MEM2`, `FWD_MEMWB` — consumed by the bypass mux at the RR stage; see §5 for the full source map. FP operand hazards are managed by `kronos_fpu_scoreboard` rather than the integer forwarding network (§8 covers what that scoreboard actually arbitrates).

---

## 1. Design Evolution

One row per stage. AXI4 and bimodal branch prediction were established in Stage 3 and remain unchanged; the pipeline's stage count and register boundaries were restructured by the Stage 7 Fmax push (7a–7e) — see the diagram above for the current 9-stage shape.

| Stage | ISA | Key modules introduced | Key concept |
|-------|-----|----------------------|-------------|
| 0 | RV32I | `kronos_decode`, `kronos_regfile`, `kronos_alu`, `kronos_lsu` (OBI), `kronos_csr` | Single-cycle golden model |
| 1 | RV32I | `kronos_lsu` (OBI FSM), `kronos_forward`, `kronos_hazard` | 5-stage pipeline, data/control hazards |
| 2 | RV32IM | `kronos_muldiv` | Multi-cycle stall protocol |
| 3 | RV32IMC | `kronos_lsu` (AXI4), `kronos_decompress`, `kronos_align`, `kronos_bpred` | Native AXI4, C extension, branch prediction |
| 4 | RV64IMAC | `kronos_alu` (64-bit), `kronos_muldiv` (64-bit), `kronos_decompress` (RV64C), `kronos_lsu` (LR/SC + AMO), `kronos_csr` (64-bit) | 64-bit datapath widening, atomic operations |
| 5a | RV64IMAFD | `kronos_regfile_fp`, `kronos_fpu_top`, `kronos_fpu_scoreboard`, `kronos_fpu_fmisc`, `kronos_fpu_fcvt`, `kronos_fpu_fadd`, `kronos_fpu_fmul`, `kronos_fpu_fma` | Separate FP register file, multi-unit FPU dispatch, scoreboard hazard model |
| 5b | RV64IMAFDC | `kronos_fpu_iter`, `kronos_fpu_fdiv_core`, `kronos_fpu_fsqrt_core` | Iterative FDIV/FSQRT (radix-2 SRT) |
| 5c–5h | RV64IMAFDC | `kronos_icache`, `kronos_dcache`, `kronos_trigger` | Performance counters, CRV harness, I/D caches (4-way + tree-PLRU), FENCE.I, debug/trace layer |
| 6a–6c | RV64IMAFDC | `kronos_pmp`, `kronos_tlb`, `kronos_ptw` | M/S/U privileged modes + trap delegation + PMP, Sv39/Sv48 MMU + iTLB/dTLB + HW PTW + sfence.vma, closeout |
| 6d–6i | RV64IMAFDC | `kronos_ram` (SDP wrapper); `kronos_decode_int`/`_mem`/`_ctrl`/`_sys`/`_fp` (per-class decoder split, replacing the monolithic `kronos_decode`); `kronos_predecode` + `kronos_fetch_buffer` (BOOM-style frontend rewrite, replacing `kronos_align`) | RAM wrapper infrastructure, PMA non-cacheable regions, dcache `data_q` BRAM-back, per-class decoder split, BOOM-style frontend rewrite, cache tag arrays + FP regfile in BRAM/LUTRAM, verification overhaul |
| 7a–7c | RV64IMAFDC | (no new modules — restructures `kronos_top`, `kronos_forward`, `kronos_hazard`, `kronos_csr`) | In-order Fmax push: BOOM-style fault-bit propagation (`fault_t`) + EX1/EX2 split; RR (register-read) stage + bypass network rebuild; MEM1/MEM2 split (dTLB/PMP separated from dcache hit) |
| 7d | RV64IMAFDC | (no new modules) | MEM1B pipeline-register split + PMP retime + `FWD_MEM2` load suppression + `trap_vector` retime; post-route WNS −3.128 → −2.872 ns on KV260 (xck26-2LV, Vivado 2025.2). RTL portion complete; Pblock floorplan deferred. |
| 7e | RV64IMAFDC | (no new modules) | dTLB internal S0/S1 pipeline split (landed); stall-network retime — registering `event_bus` ahead of the `mhpmcounter` clock-enable fan-in — still open |

---

## 2. Module Hierarchy

Full instantiation tree for `kronos_top`. Modules under `rtl/common/` are shared verbatim across stages; modules under `rtl/stage7/` are the current stage's active copy. See §1 for a module's introduction stage.

```
kronos_top  (rtl/stage7/kronos_top.sv)
├── u_icache        kronos_icache            (rtl/stage7/kronos_icache.sv)             s0/s1/s2 pipeline, per-stage kill inputs
├── u_fb            kronos_fetch_buffer      (rtl/common/kronos_fetch_buffer.sv)       depth-4 FIFO, icache S2 → predecode
├── u_predecode     kronos_predecode         (rtl/common/kronos_predecode.sv)          replaces kronos_align
│   ├── u_decomp_lower  kronos_decompress    (rtl/common/kronos_decompress.sv)         lower-half RVC expand
│   └── u_decomp_upper  kronos_decompress    (rtl/common/kronos_decompress.sv)         upper-half RVC expand
├── u_bpred         kronos_bpred             (rtl/common/kronos_bpred.sv)              reused unmodified (see §1)
├── u_decode        kronos_decode            (rtl/stage7/kronos_decode.sv)             dispatch wrapper over 5 sub-decoders
│   ├── u_int       kronos_decode_int        (rtl/stage7/kronos_decode_int.sv)         OP / OP-IMM / OP-IMM-32 / OP-32 / LUI / AUIPC
│   ├── u_ctrl      kronos_decode_ctrl       (rtl/stage7/kronos_decode_ctrl.sv)        JAL / JALR / BRANCH
│   ├── u_mem       kronos_decode_mem        (rtl/stage7/kronos_decode_mem.sv)         LOAD / STORE / LOAD-FP / STORE-FP / AMO
│   ├── u_sys       kronos_decode_sys        (rtl/stage7/kronos_decode_sys.sv)         SYSTEM: priv/sfence cluster + CSR*
│   └── u_fp        kronos_decode_fp         (rtl/stage7/kronos_decode_fp.sv)          OP-FP + the four FMA opcodes
├── u_regfile       kronos_regfile           (rtl/stage0/kronos_regfile.sv)            reused unmodified (see §1); 2R read now issued from RR
├── u_regfile_fp    kronos_regfile_fp        (rtl/common/kronos_regfile_fp.sv)         3R read now issued from RR
├── u_forward       kronos_forward           (rtl/stage7/kronos_forward.sv)            6-slot bypass select, computed at ID
├── u_hazard        kronos_hazard            (rtl/stage7/kronos_hazard.sv)             en/flush for 8 registers, stall priority
├── u_alu           kronos_alu               (rtl/common/kronos_alu.sv)                EX1
├── u_muldiv        kronos_muldiv            (rtl/common/kronos_muldiv.sv)             EX1, multi-cycle MUL/DIV
├── u_csr           kronos_csr               (rtl/stage7/kronos_csr.sv)                RR speculative read + EX1 RMW + WB-retire commit
├── u_trigger       kronos_trigger           (rtl/common/kronos_trigger.sv)             Sdtrig hardware breakpoints
├── u_pmp_fetch     kronos_pmp               (rtl/stage7/kronos_pmp.sv)                16 regions, instruction side
├── u_pmp_data      kronos_pmp               (rtl/stage7/kronos_pmp.sv)                16 regions, data side
├── u_itlb          kronos_tlb               (rtl/stage7/kronos_tlb.sv)                8-entry CAM, instruction side
├── u_dtlb          kronos_tlb               (rtl/stage7/kronos_tlb.sv)                8-entry CAM, data side; internal S0/S1 split (see §1)
├── u_ptw           kronos_ptw               (rtl/stage7/kronos_ptw.sv)                Sv39/Sv48 hardware page-table walker
├── u_lsu           kronos_lsu               (rtl/stage7/kronos_lsu.sv)                thin MEM2 adapter to kronos_dcache
├── u_dcache        kronos_dcache            (rtl/stage7/kronos_dcache.sv)             AXI master, AMO arithmetic, LR/SC reservation
└── u_fpu           kronos_fpu_top           (rtl/common/fpu/kronos_fpu_top.sv)        dispatches from EX1
    ├── u_fmisc     kronos_fpu_fmisc         1-cycle: FSGNJ/FMIN/FMAX/FCLASS/CMP/FMV
    ├── u_fcvt      kronos_fpu_fcvt          3-cycle: FCVT
    ├── u_fadd      kronos_fpu_fadd          7-cycle: FADD/FSUB
    ├── u_fmul      kronos_fpu_fmul          9-cycle: FMUL
    ├── u_fma       kronos_fpu_fma           9-cycle: FMADD/FMSUB/FNMADD/FNMSUB
    ├── u_iter      kronos_fpu_iter          variable: FDIV/FSQRT wrapper FSM
    │   ├── u_fdiv  kronos_fpu_fdiv_core     radix-2 SRT division
    │   └── u_fsqrt kronos_fpu_fsqrt_core   radix-2 SRT square root
    └── u_scoreboard kronos_fpu_scoreboard   writeback-slot reservation (see §8.1 — not a per-register busy table)
```

---

## 3. Memory Subsystem

Cache and register-file storage that maps to BRAM/LUTRAM goes through `rtl/common/kronos_ram.sv`, a parameterised SDP RAM wrapper with two backends behind the `KRONOS_RAM_FPGA` define:

- **FPGA backend** — `xpm_memory_sdpram` (Xilinx Parameterized Macros). Vivado infers RAMB36/RAMB18 deterministically. Read latency is 1 cycle; same-cycle write+read collision returns the OLD value (`WRITE_MODE_B = "no_change"` — RAMB36/RAMB18 SDP only supports `"no_change"` / `"read_first"` on port B).
- **ASIC / Verilator default** — behavioural SDP that synthesises as flops on tools without XPM. Same 1-cycle read, same byte-write semantics. Marked as a stub for vendor SRAM-compiler replacement at tape-out.

Consumers handle same-cycle write→read forwarding externally:

| Consumer | Wrapper instances | Per-instance geometry | Bypass strategy |
|---|---|---|---|
| `kronos_icache` data | 4 (one per way) | `64 sets × 16 words × 32 b` | refill→read 1-deep prev-write bypass |
| `kronos_icache` tag  | 4 | `64 sets × 56 b` (tag zero-padded to 8 b multiple) | refill→read 1-deep prev-tag-write bypass + S1→S2 tag holdover |
| `kronos_dcache` data | 4 | `64 sets × 8 beats × 64 b` | store-hit / last-refill-beat / load 1-deep prev-write bypass |
| `kronos_dcache` tag  | 4 | `64 sets × 56 b` | refill→read 1-deep prev-tag-write bypass |

Smaller storage stays in flops or LUTRAM — iTLB/dTLB CAMs (8 entries each), branch predictor PHT/BTB (64+16 entries), integer regfile (`rtl/stage0/kronos_regfile.sv`, LUTRAM), FP regfile (`rtl/common/kronos_regfile_fp.sv`, LUTRAM). The wrapper is not used for these because their geometry (CAMs, very small register banks) does not match BRAM SDP.

---

## 4. Frontend — Instruction Cache, Fetch Buffer, Predecode, Branch Prediction

The frontend follows a BOOM-style structure: a pipelined instruction cache with per-stage kill inputs, a standalone fetch buffer that decouples the cache from decode-side back-pressure, and a predecode block that both expands compressed instructions and tracks halfword spanning. It replaced a single per-instruction fetch FSM plus a combined alignment/decompression FSM (`kronos_align`); §4.5 points at that history.

### 4.1 Instruction Cache — `kronos_icache`

16 KB, 4-way set-associative, 64-byte lines, tree-PLRU replacement (64 sets, 3 PLRU bits/set), critical-word-first refill via an 8-beat AXI4 WRAP burst. Data arrays are 4× `kronos_ram` (one per way); tag/valid/PLRU stay in flops.

The cache is structurally split into three stages, each with its own `valid` register and a combinational kill input:

| Stage | Registers | Action |
|---|---|---|
| S0 | (combinational) | `s0_addr_i` / `s0_pc_i` presented; latched into S1 on `s0_ready_o & s0_valid_i`. |
| S1 | `s1_valid_q` | BRAM read in flight. Cleared by `s1_kill_i`. |
| S2 | `s2_valid_q`, `s2_hit_q` | Combinational hit detect against the tag array; a hit pushes `(pc, data)` into the fetch buffer. Cleared by `s2_kill_i`. |

`s1_kill_i` and `s2_kill_i` are driven combinationally from `redirect_load | fence_i_pulse` — where `redirect_load = mem_redirect_q | ex_redirect_q | fence_i_redirect_q | pred_taken_q` is the same signal that reloads `s0_pc_q`. Note that `redirect_load` includes `pred_taken_q`, a *speculative* predicted-taken kill, not only the three confirmed (direction/trap/FENCE.I) redirects — a killed S2 entry with a real miss does not start a refill, so wrong-path fetches never issue AXI traffic, whether the kill was speculative or confirmed. A separate, narrower `confirmed_redirect_i` (only `ex_redirect_q | mem_redirect_q` — excludes both `pred_taken_q` and `fence_i_redirect_q`) lets an in-flight refill mark itself squashed without discarding a line that a since-corrected prediction may still want.

When the fetch buffer is full, S2 stalls (does not advance, does not kill) and back-pressure propagates to S1 and `s0_ready_o` — ordinary valid/ready flow control, not a shared stall signal with the rest of the pipeline.

![AXI4 instruction fetch waveform](diagrams/svg/wf-axi-fetch.svg)

### 4.2 Fetch Buffer — `kronos_fetch_buffer`

A depth-4 FIFO between icache S2 and predecode. Each entry carries `(pc, instr_word, valid)` — the PC travels with the data, so predecode never has to reconstruct which address a word came from. `enq_ready_o = (count < DEPTH)`, `deq_valid_o = (count > 0)`; a single `flush_i` (driven by the same redirect signals as the icache kills, OR'd with the FENCE.I pulse) clears the FIFO in one cycle so stale entries fetched ahead of a redirect or a self-modifying-code drain cannot reach decode.

### 4.3 Predecode — `kronos_predecode`

Replaces `kronos_align`. Consumes one 4-byte-aligned word at a time from the fetch-buffer head and emits at most one instruction per cycle. Decompression is internal: two combinational `kronos_decompress` instances (`u_decomp_lower`, `u_decomp_upper`) expand whichever half the classifier selects — there is no separate top-level decompress stage.

State is two registers: `prev_half_q` (the lower 16 bits of a 32-bit instruction whose halves span two fetch-buffer entries) and `word_lower_consumed_q` (set when the lower 16 bits of the current head have been emitted as RVC but the upper 16 bits are still pending in the same word). The classifier's five cases:

| Case | Condition | Emits | FB pop |
|---|---|---|---|
| Combine span | `prev_half_valid_q` set | `{word[15:0], prev_half}` as a 32-bit instr at `prev_half_pc_q` | no (re-reads the same head from its upper half next cycle) |
| RVC at lower | not spanning, reading lower half, `word[1:0] ≠ 11` | decompressed 16-bit instr | no (upper half still pending) |
| 32-bit non-spanning | not spanning, reading lower half, `word[1:0] = 11` | `word_data_i` unchanged | yes |
| RVC at upper | not spanning, reading upper half, `word[17:16] ≠ 11` | decompressed 16-bit instr at `word_pc \| 2` | yes |
| Span lower | not spanning, reading upper half, `word[17:16] = 11` | (no emit — buffers `word[31:16]` into `prev_half_q`) | yes |

Backpressure is strict valid/ready: while `instr_valid_o & ~instr_ready_i`, no internal state advances and the fetch-buffer head is not popped — the same `(instr, pc)` is re-presented until the consumer accepts it. A redirect's `flush_i` clears `prev_half_q` and `word_lower_consumed_q` in the same cycle; `flush_pc_offset_i` (the redirect target's `pc[1]`) primes `word_lower_consumed_q` so a half-aligned redirect target starts from the correct half. Cross-page fault detection (`pc[11:1] == 11'h7FF` on a 32-bit instruction's lower half) is unchanged from the pre-rewrite alignment unit, gated by `translate_fetch_i`.

`instr_fetch_stall` (consumed by `kronos_hazard`, §7) is simply `~align_instr_valid & ~pmp_fetch_fault & ~redirect_load` — decode-side stalls (`mem_stall`, `muldiv_stall`, `fpu_stall`) hold `if_id_en` low and back-pressure through predecode's `instr_ready_i`; they never reach into the icache or fetch buffer directly.

### 4.4 Branch Predictor — `kronos_bpred`

The branch predictor combines a **bimodal pattern history table (PHT)** with a **branch target buffer (BTB)**; its structure has not changed since it was introduced (see §1).

- **PHT:** 64 entries indexed by `PC[7:2]`, each holding a 2-bit saturating counter (00 = strongly not-taken, 11 = strongly taken).
- **BTB:** 16 entries indexed by `PC[5:2]`, each holding a valid bit, a tag (`PC[31:6]`), and a 64-bit target address. Direct-mapped; a hit requires `valid && tag match`.

```mermaid
%% depicts: stage7e
flowchart LR
    subgraph lookup["Lookup path (combinational)"]
        pc_in["PC input (predecode_instr_pc)"] --> idx["Index logic<br>bimodal_idx = pc[7:2]<br>btb_idx = pc[5:2]<br>tag = pc[31:6]"]
        idx --> bimodal["Bimodal table<br>64×2b sat-counters<br>pred_taken = counter[1]"]
        idx --> btb["BTB — 16 entries<br>(valid | tag | target)<br>hit = valid & tag match"]
        bimodal --> hit["Hit & prediction<br>pred_taken = btb_hit & counter[1]<br>pred_target = btb[idx].target"]
        btb --> hit
        hit --> pred_out["Prediction outputs<br>pred_taken_o / pred_target_o"]
    end
    subgraph update["Update path (registered)"]
        upd_in["EX1 update<br>upd_valid / pc / taken / target / is_jal"] --> upd_idx["Update index logic<br>update_idx = upd_pc[7:2]<br>update_btb_idx = upd_pc[5:2]"]
        upd_idx --> cupd["Counter update<br>taken → incr (max 11)<br>not-taken → decr (min 00)<br>(JAL skips counter)"]
        upd_idx --> bupd["BTB update<br>taken/JAL → write entry<br>not-taken & cnt=00 → invalidate"]
    end
    cupd -.-> bimodal
    bupd -.-> btb
```

Reset initializes every counter to `2'b01` (weakly not-taken) and clears the BTB.

**Lookup (combinational):** Every cycle, `predecode_instr_pc` (predecode's emitted PC, not a dedicated fetch-address register) indexes both structures simultaneously. If the BTB entry is valid and the PHT counter MSB is `1`, the predictor asserts `pred_taken` and drives `pred_target` from the BTB; the frontend uses `pred_target` as the redirect target instead of `PC+2/4`. The predicted-taken redirect is registered (`pred_taken_q`) before it reaches the icache kill / fetch-buffer flush network, so the branch itself is already captured into `if_id_q` by the time the redirect fires — at most one extra wrong-path bubble per predicted-taken branch.

**Update (registered):** EX1 sends the resolved direction and target back to the predictor, keyed by `rr_ex1_q.pc` (the branch's own PC, one register earlier than its EX2 fault-aggregation point). The PHT counter increments on taken, decrements on not-taken, saturating at the extremes. A taken outcome writes the BTB with the resolved target; a not-taken outcome where the counter has saturated to `00` invalidates the BTB entry.

**Misprediction detection.** A *direction* mispredict — the predicted taken/not-taken outcome disagrees with EX1's resolved outcome — is detected at EX1/EX2 and forms `ex_redirect` (§6). A *target* mispredict — both sides agree the branch was taken but the predicted target differs from the resolved target — is deferred to MEM2 (`bpred_mispredict_target`, §6), specifically so the JALR target adder and the 32-bit target comparator are removed from the direction-redirect's combinational path.

![Correct prediction waveform](diagrams/svg/wf-bpred-correct.svg)

![Misprediction flush waveform](diagrams/svg/wf-bpred-mispredict.svg)

### 4.5 History: the pre-icache fetch model

The frontend above replaced two earlier designs (see §1 for when). Fetch was originally a two-state per-instruction AXI FSM (`FETCH_IDLE`/`FETCH_WAIT_R`) issuing one AR transaction per word, and alignment/decompression was a single four-state FSM (`NORMAL`/`BUFFERED`/`NEED_UPPER`/`SKIP_LOWER`) consuming that word combinationally. A cache first replaced the per-word fetch FSM; later, two attempts at bolting a fetch buffer onto the still-combinational alignment FSM proved unsound — a buffered head sitting one cycle behind an FSM that reads combinationally cannot be flushed atomically on a redirect — which is why the full BOOM-style split into icache S0/S1/S2 + fetch buffer + predecode (this section) replaced the alignment FSM outright rather than wrapping it. See `docs/superpowers/specs/2026-04-26-icache-design.md` (the original per-word-FSM replacement) and `docs/superpowers/specs/2026-05-02-stage6f-icache-boom-frontend-v3-design.md` (the full frontend rewrite and the failure analysis of the two intermediate attempts) for the retired designs in full.

---

## 5. ID / RR — Decode and Register Read

```mermaid
%% depicts: stage7e
flowchart LR
    if_id[if_id_q] --> decode["kronos_decode<br>dispatch wrapper over 5<br>per-class sub-decoders"]
    decode --> id_rr[id_rr_q]
    fwdsel["kronos_forward<br>fwd_rs1/2_sel (6 slots)"] --> id_rr
    id_rr --> regfile["kronos_regfile<br>32×64b async read<br>(rs1, rs2)"]
    id_rr --> regfile_fp["kronos_regfile_fp<br>32×64b FP async read<br>(fs1, fs2, fs3)"]
    regfile --> intbyp["WB→RR int bypass<br>sel = wb_writing & rd==rs"]
    wb["mem_wb_q writeback mux"] -.-> intbyp
    fpmux["FP source mux<br>live FPU result | EX2/MEM1 fwd | WB fwd | regfile"] --> rrmux
    intbyp --> rrmux["RR/EX1 bypass mux<br>keyed by fwd_rs1/2_sel"]
    ex1now["EX1 combinational ex_result"] -.-> rrmux
    ex1ex2["ex1_ex2_q.alu_result / csr_rdata"] -.-> rrmux
    ex2mem1["ex2_mem1_q.alu_result / csr_rdata"] -.-> rrmux
    mem1mem1b["mem1_mem1b_q.alu_result / csr_rdata"] -.-> rrmux
    mem1mem2["mem1_mem2_q.alu_result / csr_rdata"] -.-> rrmux
    rrmux --> rr_ex1[rr_ex1_q]
    csr["kronos_csr<br>speculative read port"] -. "id_rr_q.dec.csr_addr" .-> rr_ex1
```

`kronos_decode` is a thin combinational dispatch wrapper over five per-class sub-decoders — `kronos_decode_int` (OP/OP-IMM/OP-IMM-32/OP-32/LUI/AUIPC), `kronos_decode_ctrl` (JAL/JALR/BRANCH), `kronos_decode_mem` (LOAD/STORE/LOAD-FP/STORE-FP/AMO), `kronos_decode_sys` (the SYSTEM priv/sfence cluster and CSR\*), and `kronos_decode_fp` (OP-FP and the four FMA opcodes, the only sub-decoder that reads `frm_i`). Each sub-decoder owns its class's `funct3`/`funct7` decode and per-class illegal-encoding check; the wrapper matches on `opcode[6:0]`, routes exactly one sub-decoder's `decoded_instr_t` bundle to its output, and raises `illegal_insn_o` itself only when no class matches. The external interface (`instr_i`, `frm_i`, `decoded_o`, `illegal_insn_o`) is unchanged from the pre-split monolithic decoder, so nothing downstream of ID sees a difference.

ID also generates the fault bits it owns — `ecall`, `ebreak`, `illegal`, `is_mret`, `is_sret` — directly into `id_rr_q.fault`, and computes `fwd_rs1_sel`/`fwd_rs2_sel` via `kronos_forward` (below) for capture into the same register. ID performs **no** register-file read, no bypass mux, and no CSR access — those all moved to RR so that EX1's ALU/AGU/FPU-dispatch/branch-compare/CSR-illegal logic starts from pure flop outputs (§6).

**RR — register read and bypass.** `kronos_regfile` (32×64b, async read, sync write, `x0` reads-as-zero/writes-ignored) and `kronos_regfile_fp` (32×64b, three async read ports `fs1`/`fs2`/`fs3`, one write port `fd`) are both read from `id_rr_q.dec.rs1/rs2/rs3` at RR, one cycle later than the pre-7b design read them at ID. `kronos_csr` also gets a second, RR-only combinational read port (`rr_csr_addr_i`/`rr_csr_read_en_i`/`rr_csr_rdata_o`) driven from `id_rr_q.dec.csr_addr`, separate from the CSR read-modify-write that still executes at EX1 from `rr_ex1_q` — RR's CSR read is purely speculative, captured into `rr_ex1_q.csr_rdata` and safe to discard if the consumer is later flushed.

**Integer bypass.** `int_rs1_data_rr` picks `mem_wb_q`'s writeback result over the (possibly stale) `kronos_regfile` read when `mem_wb_q` is writing the same register this cycle — this is the WB→RR analogue of the old WB→ID bypass, shifted one register later.

**FP bypass.** A four-way mux, mirroring the integer path, picks between a live-just-completed FPU result (`fp_result_avail` and a tag match against `id_rr_q.dec.rs1/rs2/rs3`), a still-draining FP-arithmetic producer sitting in `ex2_mem1_q` (`ex2_mem1_q.dec.is_fp & rd_fp & ~fp_load` — FP loads are excluded since their value isn't in `.alu_result` at that point), the FP writeback value (`fp_we`/`fp_wa` match), or a plain `kronos_regfile_fp` read. This exists specifically for the single instruction that was held in IF/ID for the duration of an `fpu_stall`: when the stall lifts, that instruction reaches RR the same cycle its producer's result becomes visible, and this mux picks it up instead of a stale regfile read. It is **not** a general multi-cycle FP forwarding network — see §8.1 for why the FPU's blocking dispatch model means at most one FP consumer can ever be waiting.

**RR/EX1 bypass mux.** The final operand values captured into `rr_ex1_q.rs1_data`/`rs2_data` are selected by `id_rr_q.fwd_rs1_sel`/`fwd_rs2_sel` — computed at the preceding ID cycle by `kronos_forward` from the instruction that will occupy RR at the *next* cycle — over six sources, freshest first:

| Select | Source | Producer's stage at select time | Notes |
|---|---|---|---|
| `FWD_EX1_NOW` | `ex_result` (combinational EX1 ALU/muldiv output) | RR (advancing to EX1 next cycle) | same-cycle bypass; no extra stall for back-to-back ALU-RAW pairs |
| `FWD_EX1` | `ex1_ex2_q.alu_result` (or `.csr_rdata` if CSR-typed) | EX1 | |
| `FWD_EXMEM` | `ex2_mem1_q.alu_result` (or `.csr_rdata`) | EX2 | legacy enum name; the source register is `ex2_mem1_q` |
| `FWD_MEM1B` | `mem1_mem1b_q.alu_result` (or `.csr_rdata`) | MEM1 | |
| `FWD_MEM2` | `mem1_mem2_q.alu_result` (or `.csr_rdata`) | MEM1B | ALU/CSR producers only — `kronos_forward` suppresses this slot for loads, so the live `lsu_rdata` path never reaches the bypass mux |
| `FWD_MEMWB` | `wb_result_64` (the WB mux output, driven from `mem_wb_q`) | MEM2 | the only path that carries a registered **load** value — every load producer in an earlier slot falls through to here |
| (default) | RR-cycle source (the FP mux above, or the integer regfile/WB-bypass mux) | — | no producer matched |

`kronos_forward` computes this per rs1/rs2 from the consumer's `if_id_rs1/rs2` addresses against all six producer slots, checked in the same freshest-first order as the table above. Five of the six slots (`id_rr_q`, `rr_ex1_q`, `ex1_ex2_q`, `ex2_mem1_q`, `mem1_mem1b_q`) have their own `valid` input port; the last, `mem1_mem2_q` (which can only resolve to `FWD_MEMWB`), does not — its valid gate is folded into `rd_wen_i` at the instantiation site instead (`.mem1_mem2_rd_wen_i (mem1_mem2_q.dec.rd_wen & mem1_mem2_q.valid)`). `rd = x0` and FP-destination producers (`rd_fp`) never match an integer consumer; loads are suppressed on every slot except the last one — `FWD_MEM2` also suppresses loads (per the note above), so `FWD_MEMWB` is the only slot that ever carries a load value.

---

## 6. EX1 / EX2 — Execute, Branch Resolution, Muldiv, Fault Aggregation

```mermaid
%% depicts: stage7e
flowchart LR
    rr_ex1[rr_ex1_q] --> alu["kronos_alu"]
    rr_ex1 --> muldiv["kronos_muldiv<br>multi-cycle MUL/DIV"]
    rr_ex1 --> fpu_disp["FPU dispatch<br>(kronos_fpu_top)"]
    rr_ex1 --> csr["kronos_csr<br>RMW / csr_illegal check"]
    alu --> resmux["ex_result mux<br>is_muldiv ? muldiv : alu"]
    muldiv --> resmux
    alu --> branch["Branch-direction compare<br>cmp_lt / eq (from ALU)"]
    resmux -. "FWD_EX1_NOW (comb)" .-> rr_bypass["RR bypass mux<br>(next cycle, §5)"]
    resmux --> ex1_ex2[ex1_ex2_q]
    branch --> ex1_ex2
    csr --> ex1_ex2
    ex1_ex2 -- "fault (EX1-owned bits +<br>bpred_dir_mispredict)" --> ex2_agg["EX2: fault OR-reduce<br>+ live pmp_fetch_fault fold-in"]
    ex2_agg --> ex_redirect["ex_redirect_d =<br>fault.bpred_dir_mispredict"]
    ex_redirect -. "direction redirect" .-> icache_top["icache kill / FB flush<br>(§4.1/§4.2)"]
    ex2_agg --> ex2_mem1[ex2_mem1_q]
```

EX1 consumes only `rr_ex1_q` flop outputs — no combinational reach into the register file, the bypass mux, or the CSR file remains in front of the ALU, the AGU, FPU dispatch, or the branch comparator, which is the entire point of moving register read into RR (§5). EX2 aggregates fault bits and forms the direction-mispredict redirect; it performs no new datapath computation.

**ALU (`kronos_alu`, unchanged since its structural decomposition was introduced — see §1).** Single-cycle, fully combinational. BOOM/Rocket-style structural decomposition: one shared 64-bit adder (drives ADD, SUB, SLT, SLTU and the comparator), one right-only barrel shifter (SLL is implemented as input bit-reverse → right-shift → output bit-reverse, sharing the same shifter as SRL/SRA), one logic block (AND, OR, XOR, PASSB), and a 5:1 op-class final mux; ADD/SUB get an explicit arm and the default arm produces zero so an invalid `alu_op` cannot leak adder output into writeback. W-suffix instructions run on the same 64-bit datapath via input pre-mask and output sign-extension — no parallel 32-bit datapath. `alu_a` selects between the forwarded RS1 value and `rr_ex1_q.pc` (AUIPC / branch offset); `alu_b` selects between the forwarded RS2 value and the sign-extended immediate. In addition to `result_o`, the ALU exposes `adder_out_o`, `cmp_lt_o` (signed-or-unsigned LT per `op_i`), and `eq_o` (`adder_out == 0`, valid whenever the adder is in subtract mode) — the branch unit consumes `cmp_lt_o`/`eq_o` directly instead of duplicating the comparator.

```mermaid
%% depicts: stage7e
flowchart LR
    a_i["a_i [63:0]"] --> premask
    b_i["b_i [63:0]"] --> premask
    op_i["op_i (alu_op_e)"] -.-> premask
    word_op_i -.-> premask
    word_op_i -.-> postext
    premask["Word-op pre-mask<br>a_pre, b_pre, shamt<br>(SRA → sign-ext low 32;<br>else zero-ext low 32)"]
    premask --> adder["Adder<br>a + (b ⊕ is_sub) + is_sub<br>(is_sub on SUB / SLT / SLTU)"]
    premask --> cmp
    premask --> shifter["Shifter<br>right-only barrel<br>SLL via bit-reverse<br>SRA: sign-fill from a_pre[63]"]
    premask --> logicb["Logic<br>AND / OR / XOR / PASSB"]
    adder == adder_out ==> cmp["Comparator (from adder)<br>LT = sign of (a−b), overflow-corrected<br>EQ = (adder_out == 0)"]
    adder --> opmux["Op-class final mux<br>is_alu_shift → shift_out<br>is_alu_slt → {0…0, cmp_lt}<br>is_alu_logic → logic_out<br>ADD / SUB → adder_out<br>default → 0"]
    cmp --> opmux
    shifter --> opmux
    logicb --> opmux
    opmux --> postext["Post-extend<br>word_op_i ?<br>sext32→64 : passthrough"]
    postext --> result_o["result_o [63:0]"]
    adder --> adder_out_o["adder_out_o [63:0]"]
    cmp --> cmp_lt_o
    cmp --> eq_o
```

**Muldiv (`kronos_muldiv`, EX1).** Implements all eight M-extension operations for 32-bit and 64-bit operands. MUL requires **2 cycles**. DIV/REM require **34 cycles** (32-bit) or **66 cycles** (64-bit) in the normal case; division by zero and `INT_MIN / -1` are detected early and resolve in **2 cycles**. `muldiv_stall` freezes the entire pipeline while asserted, but — unlike the older redirect-blind version — the hazard priority table (§7) lets a redirect flush a wrong-path MUL/DIV out from under `muldiv_stall` rather than waiting for it to finish.

![MUL stall waveform](diagrams/svg/wf-muldiv-stall.svg)

![DIV stall waveform](diagrams/svg/wf-div-stall.svg)

**Branch resolution.** EX1 evaluates every branch condition from the ALU's `cmp_lt_o`/`eq_o` — `kronos_decode` drives `alu_op` to `ALU_SLT` (BLT/BGE) or `ALU_SLTU` (BLTU/BGEU, and BEQ/BNE, where any subtract-style op makes `eq_o` valid) — and maps `funct3` to `alu_eq` / `~alu_eq` / `alu_cmp_lt` / `~alu_cmp_lt`. JAL, JALR, and taken branches compute `ex_pc_d` (the redirect target on a direction mispredict) from `rr_ex1_q.pc + imm` or the JALR adder (`fwd_rs1_data + sext(imm)`, bit 0 cleared). The branch predictor's update inputs (§4.4) are driven from this same EX1 state, keyed by `rr_ex1_q.pc`.

**Fault-bit propagation.** Every fault and privileged-transition source writes exactly one bit of the `fault_t` struct, in the pipeline register belonging to the stage that produces it, with no combinational reach across module boundaries:

| Producer stage | `fault_t` bits |
|---|---|
| ID (`id_rr_q.fault`) | `ecall`, `ebreak`, `illegal`, `is_mret`, `is_sret` |
| EX1 (folded into `ex1_ex2_q.fault`) | `csr_illegal`, `mret_priv_fail`, `sret_priv_fail`, `satp_tvm_fail`, `wfi_priv_fail`, `irq_pending`, `bpred_dir_mispredict`, `trig_hit` |
| EX2 (folded into `ex2_mem1_q.fault`) | `pmp_fetch_fault` |
| MEM1→MEM1B (folded into `mem1_mem1b_q.fault`; passes through `mem1_mem2_q.fault` unchanged — MEM1B does not fold anything new in) | `instr_page_fault`, and the PTW-invalid-PTE arm of `load_page_fault`/`store_page_fault` (the walk completing with a bad PTE) |
| MEM2 (live wires, captured directly into `mem_wb_q.fault` at the MEM2→WB edge — these bypass `mem1_mem2_q.fault` entirely rather than folding into it) | `pmp_data_fault`, `ex_amo_nc_fault`, the dTLB-perm-fail arm of `load_page_fault`/`store_page_fault` (from the registered `mem1_mem2_q.dtlb_perm_fail`), `bpred_target_mispredict`, `dcache_bus_err_fault` |

Each pipeline register's `always_ff` carries forward every earlier producer's bits verbatim and OR-folds in only its own stage's new bits — a Verilator `UNUSEDSIGNAL` lint failure catches any bit a producer forgets to drive. Redirect formation reads only registered bits (plus the live MEM2 wires above, which stay within MEM2's own narrow cone), at exactly two points:

- **`ex_redirect_d = ex1_ex2_q.fault.bpred_dir_mispredict`** — formed at EX2, the only fault class resolved that early. A direction mispredict flushes every younger register — `if_id_q`, `id_rr_q`, `rr_ex1_q`, and `ex1_ex2_q` itself (the wrong-path follower that would otherwise land in `ex1_ex2_q` the same edge) — while the mispredicting branch, already past the EX1/EX2 boundary, continues to retire normally.
- **`mem_redirect_d`** — a single OR over every other fault bit in `mem1_mem2_q.fault` plus the still-live MEM2-cycle producers (`mem2_pmp_data_fault`, `mem2_amo_nc_fault`, `mem2_load_page_fault`, `mem2_store_page_fault`, `bpred_mispredict_target`, `dcache_bus_err_fault`) — all of which stay within MEM2's own narrow cone rather than crossing a module boundary. A `mem_redirect` flushes `if_id_q` through `mem1_mem2_q`.

**Trap cause priority.** `mem_trap_cause_d` (and its EX1-cycle predictive twin `ex1_trap_cause`, which feeds `kronos_csr.trap_vector_o` so the redirect target already reflects `medeleg`/`mideleg` delegation) select the cause in fixed priority order, roughly: trigger hit > instruction/load/store page fault > instruction/data PMP fault (or AMO non-cacheable fault) > D-cache bus error > pending interrupt > illegal/CSR-illegal/priv-fail class > ECALL (M/S/U per current `priv_q`) > EBREAK (default). MEM-class (older-instruction) faults always outrank EX1-class faults in the predictive path, since a MEM-class trap's `mem_redirect` would flush the EX1 instruction anyway.

**CSR unit (`kronos_csr`).** Two access points, not one: RR issues a purely speculative combinational read (§5) into `rr_ex1_q.csr_rdata`, discarded harmlessly if the consumer is later flushed; the actual CSRRW/CSRRS/CSRRC read-modify-write (plus immediate variants) executes at EX1 from `rr_ex1_q.dec.csr_addr`/`rs1_data`, gated only by `rr_ex1_q.valid & rr_ex1_q.dec.is_csr` — no `~combined_stall` gate, which is what breaks a historical `combined_stall → csr_illegal → ex_redirect → combined_stall` combinational loop. The CSR write itself does not commit at EX1: it retires from `mem_wb_q` (`retire_i = mem_wb_q.valid & mem_wb_q.dec.is_csr & ~mem_wb_fault_any_trap & ~combined_stall`), alongside `trap_i`/`mret_i`/`sret_i`, all driven from the registered `mem_wb_q.fault` bits. MISA reports I, M, A, F, D, C (MXL = 2); FCSR/FFLAGS/FRM are readable/writable, with the FPU's accumulated exception flags folded into `fcsr` at the same retire edge (gated by `mem_wb_is_fp_arith_q` so a non-FP retire cannot OR in a stale `fflags` value); `mstatus.FS` tracks FP state (Off/Initial/Clean/Dirty).

---

## 7. Hazard, Forwarding, and Stall Control

```mermaid
%% depicts: stage7e
flowchart TB
    forward["kronos_forward<br>fwd_rs1/2_sel — 6 slots<br>(computed at ID, consumed at RR)"]
    subgraph pipe["Pipeline registers"]
        direction LR
        if_id[if_id_q] --- id_rr[id_rr_q] --- rr_ex1[rr_ex1_q] --- ex1_ex2[ex1_ex2_q] --- ex2_mem1[ex2_mem1_q] --- mem1_mem1b[mem1_mem1b_q] --- mem1_mem2[mem1_mem2_q] --- mem_wb[mem_wb_q]
    end
    id_rr -. "consumer rs1, rs2" .-> forward
    id_rr & rr_ex1 & ex1_ex2 & ex2_mem1 & mem1_mem1b -. "rd, wen, is_load (producers)" .-> forward
    forward -. "fwd_rs1_sel, fwd_rs2_sel" .-> id_rr
    hazard["kronos_hazard<br>en / flush for 8 registers"]
    if_id & id_rr & rr_ex1 & ex1_ex2 & ex2_mem1 & mem1_mem1b & mem1_mem2 -. "rd / valid / is_load / is_csr" .-> hazard
    hazard -. "en / flush" .-> pipe
    stall["combined_stall_no_muldiv =<br>mem_stall | instr_fetch_stall | fpu_stall<br>| (MEM1B dTLB-miss hold)"] --> hazard
    muldiv_stall["muldiv_stall"] --> hazard
    redirect["ex_redirect_q | fence_i_redirect_q<br>(ex_redirect_i)<br>mem_redirect_q (mem_redirect_i)"] --> hazard
```

`kronos_forward` and `kronos_hazard` both sit outside the pipeline stages. `kronos_forward`'s bypass-source computation is covered in §5 — it is a pure combinational function of the consumer's `rs1`/`rs2` against all six producer slots, with loads suppressed on every slot except the last, `FWD_MEMWB`.

`kronos_hazard` drives `en` for the PC register plus all seven pipeline registers (8 `en` outputs total), and exposes 6 `flush` output ports (no `mem_wb_flush_o` exists) — but only 3 of those 6 (`if_id_flush_o`, `id_rr_flush_o`, `rr_ex1_flush_o`) are ever asserted by the module itself; the other 3 (`ex2_mem1_flush_o`, `mem1_mem1b_flush_o`, `mem1_mem2_flush_o`) are always-zero dead ports left unconnected at the instantiation, because `kronos_top` drives those three registers' actual flush conditions via separate combinational assigns (see priority 2 below). Fixed priority order (highest first):

| Priority | Condition | Effect |
|---|---|---|
| 1 | `mem_stall_i` (= `combined_stall_no_muldiv`: `mem_stall \| instr_fetch_stall \| fpu_stall \|` a MEM1B dTLB-miss hold) | Freeze all eight registers — no enables, no flushes. |
| 2 | `ex_redirect_i` (`ex_redirect_q \| fence_i_redirect_q`) or `mem_redirect_i` (`mem_redirect_q`) | Flush `if_id_q`, `id_rr_q`, `rr_ex1_q` (the registers `kronos_hazard` owns). `ex1_ex2_q`/`ex2_mem1_q`/`mem1_mem1b_q`/`mem1_mem2_q` flush via separate combinational assigns in `kronos_top`, gated on the same redirect signals, so the module boundary doesn't force every older register's flush condition through `kronos_hazard`'s port list. |
| 3a | ID-class RAW: `load_use \| fp_load_use \| csr_raw_stall_id \| jalr_fwd_stall \| frm_hazard` | Stall `pc`/`if_id`/`id_rr`; bubble into RR (`id_rr_flush`). |
| 3b | RR-class CSR-RAW: `csr_raw_stall_rr` | Stall `pc`/`if_id`/`id_rr`/`rr_ex1`; bubble into EX1 (`rr_ex1_flush`). Closes a one-cycle window where a consumer that has advanced from ID to RR would otherwise read a CSR write that is still in flight one register ahead. |
| 4 | `muldiv_stall_i` | Freeze all eight registers. Ranked *below* redirect so a wrong-path MUL/DIV can still be flushed instead of running to completion. |
| 5 (else) | — | Normal advance: all `en = 1`, no flushes. |

**Load-use.** A load can occupy any of six slots ahead of an ID-stage consumer — `id_rr_q`, `rr_ex1_q`, `ex1_ex2_q`, `ex2_mem1_q`, `mem1_mem1b_q`, or `mem1_mem2_q` — because the only registered load value is `mem_wb_q.alu_result` (`FWD_MEMWB`, §5): `FWD_MEM2` explicitly suppresses loads to keep the live `lsu_rdata` path out of the bypass mux. A load-use hazard therefore costs a full 5-cycle ID stall in the worst case (the load advances through all six slots before the consumer's `FWD_MEMWB` bypass fires at the next RR). `is_load` for this purpose mirrors `kronos_forward`'s `wb_sel == WB_MEM` predicate, so AMO and LR/SC — which also write `rd` from `lsu_rdata` at MEM2 — stall a dependent consumer exactly like an ordinary load; without this, a `bnez`/branch reading an SC's success/fail code the cycle after would see a stale regfile value. FP load-use (`fp_load_use`) is the same shape with FP consumer keys.

**JALR-forward stall.** A JALR in ID whose `rs1` matches a load producer in `ex2_mem1_q` or `mem1_mem1b_q` stalls rather than forwards — the load value isn't available until MEM2, too late for the JALR target adder. Non-load producers in those slots are covered by ordinary `FWD_EXMEM`/`FWD_MEM1B` forwarding without a stall.

**FRM/FCSR RAW.** A CSR write to FRM/FCSR sitting in EX1 (`rr_ex1_is_frm_write_i`) stalls an FP instruction in ID that reads the dynamic rounding mode (`rm = 3'b111`) for one cycle, so decode re-reads `frm` only after the write has landed.

![Load-use hazard waveform](diagrams/svg/wf-load-use-hazard.svg)

---

## 8. FPU

The FPU handles all F and D extension instructions (`rtl/common/fpu/`, an unchanged file set since the iterative FDIV/FSQRT units were added — see §1: `kronos_fpu_top`, `kronos_fpu_scoreboard`, `kronos_fpu_fmisc`, `kronos_fpu_fcvt`, `kronos_fpu_fadd`, `kronos_fpu_fmul`, `kronos_fpu_fma`, `kronos_fpu_iter`, `kronos_fpu_fdiv_core`, `kronos_fpu_fsqrt_core`). It dispatches from EX1: `kronos_fpu_top` receives `rr_ex1_q`'s decoded FP operands whenever `is_fp` is asserted and routes them to one of six pipelined units. FP-destination results are written to `kronos_regfile_fp` through a dedicated writeback interface, bypassing the integer WB mux — but instructions with an **integer** destination that happen to dispatch through the FPU (FCVT.\*.S/D→int, FMV.X.W/D, FCLASS, FEQ, FLT, FLE) do the opposite: their result rides the ordinary integer `WB_ALU` path via `mem_wb_q.alu_result` (captured from `fpu_result` at the MEM2→WB edge), not the FP writeback interface.

### 8.1 Dispatch, Blocking Integration, and the Scoreboard

`kronos_fpu_scoreboard` is a **writeback-slot reservation shift register** (`DEPTH = 9`, the FMA/FMUL latency), not a per-FP-register busy table. Each dispatch computes which future cycle its result will complete (`dispatch_latency`, from the op's unit table below) and checks `slots_q[latency-1]` for a collision; the check is keyed by whether the result targets the FP regfile or the integer regfile (`fp_dest_i`/`int_dest_i`), which is what lets an FCVT/FMV/FCLASS/FEQ/FLT/FLE op (integer destination) share dispatch with an FP-destination op without a false collision. `busy_o` blocks a new dispatch on a real slot collision or while the iterative FDIV/FSQRT unit is already running.

That mechanism is built to let `kronos_fpu_top` accept a new dispatch every cycle whose writeback slot doesn't collide with an already-outstanding op — but `kronos_top`'s integration does not exploit this: `fp_inflight_q` is set on dispatch and only clears on `fpu_out_valid`, and `fpu_stall` (`= (fp_inflight_q | fpu_dispatching) & ~fp_result_avail`) freezes the **entire** integer pipeline for the whole duration, so only one FP operation is ever in flight from `kronos_top`'s perspective, regardless of the FPU's internal overlap capability. Because dispatch is fully serialized, at most one instruction — the one held in `if_id_q` for the length of the stall — can ever be waiting on a result; the RR-stage FP bypass mux described in §5 exists to hand that single consumer the result the same cycle the stall lifts, not to forward across a general multi-op pipeline. FP hazards (RAW and structural WB-port collisions) are therefore fully handled by blocking dispatch plus that single-slot bypass — there is no equivalent of the integer six-slot forwarding network for FP, and none is needed while dispatch stays serialized this way.

### 8.2 FPU Unit Table

| Unit | Module | Latency | Operations |
|------|--------|---------|------------|
| fmisc | `kronos_fpu_fmisc` | 1 cycle | FSGNJ, FMIN, FMAX, FCLASS, FEQ, FLT, FLE, FMV.X.W, FMV.W.X, FMV.X.D, FMV.D.X |
| fcvt | `kronos_fpu_fcvt` | 3 cycles | FCVT.W.S, FCVT.WU.S, FCVT.L.S, FCVT.LU.S, FCVT.S.W, FCVT.S.WU, FCVT.S.L, FCVT.S.LU, FCVT.S.D, FCVT.D.S, and D variants |
| fadd | `kronos_fpu_fadd` | 7 cycles | FADD.S, FSUB.S, FADD.D, FSUB.D |
| fmul | `kronos_fpu_fmul` | 9 cycles | FMUL.S, FMUL.D |
| fma | `kronos_fpu_fma` | 9 cycles | FMADD.S, FMSUB.S, FNMADD.S, FNMSUB.S, FMADD.D, FMSUB.D, FNMADD.D, FNMSUB.D |
| iter | `kronos_fpu_iter` | ≤ 29 (S) / ≤ 58 (D) cycles | FDIV.S, FDIV.D, FSQRT.S, FSQRT.D |

All units implement IEEE 754-2019 rounding and exception flag generation. The resolved rounding mode is carried from decode through the pipeline register (`rm_resolved`, resolved against `fcsr_frm` at decode time when the instruction encodes `rm = 3'b111`).

### 8.3 FDIV/FSQRT — Iterative SRT

`kronos_fpu_fdiv_core` and `kronos_fpu_fsqrt_core` implement radix-2 SRT iterative division and square root. One quotient/root bit is produced per cycle after an initial normalization step.

- Single precision (23-bit mantissa): ≤ 29 cycles
- Double precision (52-bit mantissa): ≤ 58 cycles

`kronos_fpu_iter` wraps both cores in a 3-state FSM: `IDLE → RUNNING → DONE`. While in RUNNING, `iter_busy_o` is asserted; the scoreboard's `busy_o` propagates this, freezing new dispatch (and, via `fpu_stall`, the whole integer pipeline) for the duration. Both cores handle special cases (±0, ±Inf, NaN, subnormals) combinationally before the iteration begins and short-circuit to DONE when applicable. The iterative unit reserves its writeback slot late (`late_req_i`/`late_latency_i = 1`, at ROUND time) since its total latency isn't known at dispatch.

---

## 8. MEM Stage — AXI4 Load/Store Unit

```mermaid
stateDiagram-v2
    [*] --> IDLE : rst_ni
    IDLE : IDLE — capture addr / wdata
    LOAD_ADDR : LOAD_ADDR — ar_valid = 1
    LOAD_DATA : LOAD_DATA — r_ready = 1
    LOAD_DONE : LOAD_DONE — valid_o = 1, latch rdata
    STORE_SEND : STORE_SEND — aw_valid = 1, w_valid = 1
    STORE_RESP : STORE_RESP — b_ready = 1
    STORE_DONE : STORE_DONE — valid_o = 1
    IDLE --> LOAD_ADDR : req & ~is_store
    LOAD_ADDR --> LOAD_DATA : ar_ready
    LOAD_DATA --> LOAD_DONE : r_valid
    LOAD_DONE --> IDLE : always
    IDLE --> STORE_SEND : req & is_store
    STORE_SEND --> STORE_RESP : aw_ready & w_ready
    STORE_RESP --> STORE_DONE : b_valid
    STORE_DONE --> IDLE : always
```

> **Era note:** stage ≤5e. Since stage 5f the LSU is a thin (~175-line)
> adapter and **`kronos_dcache` owns the AXI master, AMO arithmetic, and
> LR/SC reservation** (see the Data-cache section below); stage 7c further
> split MEM into MEM1/MEM2 (dTLB/PMP separated from the dcache hit path).
> Retained as stage-5 reference until the [#108](https://github.com/vladdum/kronos-riscv/issues/108) refresh.

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

## 9. WB Stage — Writeback

```mermaid
flowchart LR
    subgraph memwb["MEM/WB register"]
        alu_src["alu_result (WB_ALU)"]
        lsu_src["lsu_rdata (WB_MEM)"]
        pc_src["pc+2 | pc+4 (WB_PC4)"]
        csr_src["csr_rdata (WB_CSR)"]
    end
    alu_src & lsu_src & pc_src & csr_src --> wbmux["WB mux<br>sel = wb_sel[1:0]"]
    wbmux ==> rf["kronos_regfile write port<br>(rd ← wb_result)"]
    wbmux -.-> byp["WB → ID bypass<br>(id_stage bypass_mux)"]
    wbmux -.-> fwd["EX forwarding<br>FWD_MEMWB path"]
```

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

## 10. Hazard and Forwarding Control

```mermaid
flowchart TB
    forward["kronos_forward<br>fwd_rs1_sel / fwd_rs2_sel<br>(FWD_NONE | EXMEM | MEMWB)"]
    subgraph pipe["Pipeline registers"]
        direction LR
        PC --- if_id[IF/ID] --- id_ex[ID/EX] --- ex_mem[EX/MEM] --- mem_wb[MEM/WB]
    end
    id_ex -. "rs1, rs2" .-> forward
    ex_mem -. "rd, wen" .-> forward
    mem_wb -. "rd, wen" .-> forward
    forward -. "fwd selects" .-> id_ex
    hazard["kronos_hazard<br>stall / flush logic<br>out: pc_en, if_id/id_ex flush,<br>ex_mem/mem_wb enables"]
    if_id -. "rs1, rs2" .-> hazard
    id_ex -. "rd, is_load, valid" .-> hazard
    hazard -. "en / flush" .-> PC & if_id & id_ex & ex_mem & mem_wb
    stall_or["combined_stall =<br>mem_stall | muldiv_stall | instr_fetch_stall | fpu_stall"]
    mem_stall["mem_stall<br>(LSU busy)"] --> stall_or
    muldiv_stall["muldiv_stall<br>(MUL/DIV busy)"] --> stall_or
    fetch_stall["instr_fetch_stall<br>(align empty)"] --> stall_or
    fpu_stall["fpu_stall<br>(FPU scoreboard)"] --> stall_or
    stall_or --> hazard
```

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

## 11. Timing Table

> **Era note:** stage-5 pipeline depths. The stage 7a–7c splits (EX1/EX2,
> RR, MEM1/MEM2) re-price branch, load-use, and redirect costs; this table
> has not been re-measured since. Tracked in [#108](https://github.com/vladdum/kronos-riscv/issues/108).

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

## 12. CSR Register Map

> **Era note:** M-mode view through stage 5. Stages 6a–6b added S/U modes,
> trap delegation (`medeleg`/`mideleg`), the S-mode CSR file, PMP
> (`pmpcfg*`/`pmpaddr*`), and `satp` with Sv39/Sv48 translation — see the
> 6a/6b design specs until the [#108](https://github.com/vladdum/kronos-riscv/issues/108) refresh lands them here.

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

## 13. Performance counters (Zicntr + partial Zihpm)

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

---

## Stage transition gates

A "stage transition gate" is a verification activity that **must** run clean before a stage is tagged complete and merged. Gates are not part of default CI when their cost makes per-PR execution impractical; instead they are run manually before the closing PR is opened, and the result is captured in the PR description as a one-line evidence note.

Current gates:

| Gate | When | How | Evidence |
|------|------|-----|----------|
| **GLS-s6** (xsim funcsim + SDF timing-sim on the smoke subset) | Before tagging Stage 6c, 6d, 6e, … complete | `make gls-funcsim-s6 GLS_TEST=<n>` and `make gls-sdf-s6 GLS_TEST=<n>` for at least 4 programs (1 directed + 1 CRV smoke seed + 1 ACT4 priv test + the long integration program) | "GLS-s6 ran clean as of commit <SHA>: 4/4 PASS, max sim runtime <m> min" in PR body |

Why GLS is gated rather than CI'd: GitHub-hosted runners do not have the disk space (~14 GB free) for a Vivado install (~10–15 GB minimum, ~30 GB full). Self-hosted runners with Vivado pre-installed would lift this restriction; until then, GLS is a manual checkpoint.

Stage 5 GLS infrastructure (`gls-funcsim-s5`, `gls-sdf-s5`) operates the same way and predates this section.
