# Kronos Verification Testplan

This document catalogs every test in the kronos-riscv repository: what it
verifies, how to run it, and where it lives. Every PR that adds or removes a
test must update this file. Stage-completion PRs rewrite the affected
per-stage section.

## Verification mechanisms

| Mechanism           | Location                                   | Purpose                                                                   |
|---------------------|--------------------------------------------|---------------------------------------------------------------------------|
| Unit testbench      | `tb/stage<N>/tb_<module>.sv`               | Directed SystemVerilog testbench driving one RTL module in isolation.     |
| Assembly program    | `sw/stage<N>/test_*.S`                     | Self-checking RISC-V program running end-to-end on the stage simulator.   |
| ACT4 compliance     | `riscv-arch-test/` submodule               | Official RISC-V architectural compliance suite; Sail-signed signatures.   |
| Sail diff           | `tools/trace_diff.py` + `make sim-diff-*`  | Retire-by-retire trace diff between Kronos and `sail_riscv_sim`.          |
| Line-coverage gate  | `make coverage`                            | Merged Verilator line-coverage across gated modules; threshold enforced.  |
| CRV harness         | `tools/crv/` + `tb/stage5/tb_crv_cov.sv` | Random program generator + Sail diff + functional coverage. |
| CRV assists         | `sw/stage5/crv_assists/`              | Directed tests for residual covergroup bins random can't hit.|
| I-cache TB          | `tb/stage5/tb_icache.sv`              | 4-way / PLRU / CWF / WRAP / FENCE.I unit tests. |
| D-cache TB          | `tb/stage5/tb_dcache.sv`              | Load + store + dirty-eviction + AMO + LR/SC unit tests. |

## Stage 0 — Single-cycle RV32I (OBI)

### Unit testbenches
| Module        | TB file                       | Coverage focus               | Run                |
|---------------|-------------------------------|------------------------------|--------------------|
| ALU           | `tb/stage0/tb_alu.sv`         | 32-bit RV32I integer ALU ops | `make sim-alu`     |
| Register file | `tb/stage0/tb_regfile.sv`     | 2R1W, x0 hardwired zero      | `make sim-regfile` |
| Decoder       | `tb/stage0/tb_decode.sv`      | RV32I instruction decode     | `make sim-decode`  |

### Assembly programs
| Test              | File                              | Exercises                   | Run                            |
|-------------------|-----------------------------------|-----------------------------|--------------------------------|
| `test_rtype`      | `sw/stage0/test_rtype.S`          | RV32I R-type encoding       | `make run-test_rtype`          |
| `test_itype_alu`  | `sw/stage0/test_itype_alu.S`      | RV32I I-type ALU ops        | `make run-test_itype_alu`      |
| `test_load_store` | `sw/stage0/test_load_store.S`     | Loads / stores              | `make run-test_load_store`     |
| `test_branch`     | `sw/stage0/test_branch.S`         | Conditional branches        | `make run-test_branch`         |
| `test_ujtype`     | `sw/stage0/test_ujtype.S`         | U/J-type (LUI, JAL)         | `make run-test_ujtype`         |

## Stage 1 — 5-stage pipeline RV32I (OBI)

### Unit testbenches
| Module     | TB file                   | Coverage focus                    | Run               |
|------------|---------------------------|-----------------------------------|-------------------|
| LSU (OBI)  | `tb/stage1/tb_lsu_s1.sv`  | OBI req/gnt/rvalid FSM            | `make sim-lsu-s1` |
| Forwarding | `tb/stage1/tb_forward.sv` | EX/MEM/WB→ID data forwarding      | `make sim-forward`|
| Hazard     | `tb/stage1/tb_hazard.sv`  | Load-use stall, branch flush      | `make sim-hazard` |

### Assembly programs
| Test                | File                                  | Exercises                    | Run                             |
|---------------------|---------------------------------------|------------------------------|---------------------------------|
| `test_forwarding`   | `sw/stage1/test_forwarding.S`         | Producer→consumer forwarding | `make run-s1-test_forwarding`   |
| `test_load_use`     | `sw/stage1/test_load_use.S`           | Load-use 1-cycle stall       | `make run-s1-test_load_use`     |
| `test_branch_flush` | `sw/stage1/test_branch_flush.S`       | Mispredict flush correctness | `make run-s1-test_branch_flush` |
| `test_csr_trap`     | `sw/stage1/test_csr_trap.S`           | Illegal CSR traps            | `make run-s1-test_csr_trap`     |

### ACT4 compliance
- 46 tests (rv32i subset). Run: `make sim-arch-test-s1`.

## Stage 2 — RV32IM + CSR (OBI)

### Unit testbenches
| Module  | TB file                  | Coverage focus      | Run               |
|---------|--------------------------|---------------------|-------------------|
| Muldiv  | `tb/stage2/tb_muldiv.sv` | MUL/DIV 2-cycle FSM | `make sim-muldiv` |

### Assembly programs
| Test                     | File                                      | Exercises                 | Run                               |
|--------------------------|-------------------------------------------|---------------------------|-----------------------------------|
| `test_mul`               | `sw/stage2/test_mul.S`                    | MUL/MULH/MULHSU/MULHU     | `make run-s2-test_mul`            |
| `test_div`               | `sw/stage2/test_div.S`                    | DIV/DIVU/REM/REMU         | `make run-s2-test_div`            |
| `test_muldiv_hazards`    | `sw/stage2/test_muldiv_hazards.S`         | Back-to-back muldiv       | `make run-s2-test_muldiv_hazards` |
| `test_load_muldiv_edge`  | `sw/stage2/test_load_muldiv_edge.S`       | Load→muldiv RAW edge      | `make run-s2-test_load_muldiv_edge`|
| `test_irq`               | `sw/stage2/test_irq.S`                    | Timer IRQ basic flow      | `make run-s2-test_irq`            |

### ACT4 compliance
- 54 tests (rv32im). Run: `make sim-arch-test-s2`.

## Stage 3 — RV32IMC + AXI4 + BPred

### Unit testbenches
| Module       | TB file                      | Coverage focus                   | Run                  |
|--------------|------------------------------|----------------------------------|----------------------|
| Align        | `tb/stage3/tb_align.sv`      | Fetch alignment buffer for RVC   | `make sim-align`     |
| Decompress   | `tb/stage3/tb_decompress.sv` | RVC → 32-bit expansion           | `make sim-decompress`|
| LSU (AXI4)   | `tb/stage3/tb_lsu_s3.sv`     | AXI4 single-outstanding FSM      | `make sim-lsu-s3`    |
| BPred        | `tb/stage3/tb_bpred.sv`      | Branch predictor (BHT + BTB)     | `make sim-bpred`     |

### Assembly programs
| Test                   | File                                    | Exercises                 | Run                              |
|------------------------|-----------------------------------------|---------------------------|----------------------------------|
| `test_c_basic`         | `sw/stage3/test_c_basic.S`              | RVC basics                | `make run-s3-test_c_basic`       |
| `test_c_control`       | `sw/stage3/test_c_control.S`            | RVC control flow          | `make run-s3-test_c_control`     |
| `test_bpred_loop`      | `sw/stage3/test_bpred_loop.S`           | BPred hit/miss in loop    | `make run-s3-test_bpred_loop`    |
| `test_jalr_fwd_stall`  | `sw/stage3/test_jalr_fwd_stall.S`       | JALR→use forwarding stall | `make run-s3-test_jalr_fwd_stall`|

### ACT4 compliance
- 81 tests (rv32imc). Run: `make sim-arch-test-s3`.

## Stage 4 — RV64IMAC

### Unit testbenches
| Module  | TB file                       | Coverage focus            | Run                  |
|---------|-------------------------------|---------------------------|----------------------|
| ALU     | `tb/stage4/tb_alu_s4.sv`      | 64-bit + W-suffix ops     | `make sim-alu-s4`    |
| Decode  | `tb/stage4/tb_decode_s4.sv`   | RV64IMAC integer decode   | `make sim-decode-s4` |
| LSU     | `tb/stage4/tb_lsu_s4.sv`      | 64-bit loads/stores, AMO  | `make sim-lsu-s4`    |
| Muldiv  | `tb/stage4/tb_muldiv_s4.sv`   | 64-bit MUL/DIV + W        | `make sim-muldiv-s4` |

### Assembly programs
| Test                    | File                                  | Exercises                    | Run                               |
|-------------------------|---------------------------------------|------------------------------|-----------------------------------|
| `test_rv64i_basic`      | `sw/stage4/test_rv64i_basic.S`        | RV64I fundamentals           | `make run-s4-test_rv64i_basic`    |
| `test_word_ops`         | `sw/stage4/test_word_ops.S`           | W-suffix arithmetic          | `make run-s4-test_word_ops`       |
| `test_64bit_loadstore`  | `sw/stage4/test_64bit_loadstore.S`    | LD/SD, LW/LH/LB sign-ext     | `make run-s4-test_64bit_loadstore`|
| `test_atomic`           | `sw/stage4/test_atomic.S`             | AMO + LR/SC                  | `make run-s4-test_atomic`         |

### ACT4 compliance
- 104 tests (rv64imac). Run: `make sim-arch-test-s4`.

## Stage 5 — RV64IMAFD (F/D pipelined, no FDIV/FSQRT)

### Unit testbenches
| Module / Block         | TB file                              | Coverage focus                          | Run                          |
|------------------------|--------------------------------------|-----------------------------------------|------------------------------|
| Integer ALU (stage 5)  | `tb/stage5/tb_alu_s5.sv`             | 64-bit + W-suffix ops (stage-5 RTL)     | `make sim-alu-s5`            |
| Integer decode (s5)    | `tb/stage5/tb_decode_s5.sv`          | Integer-path RV64IMAC decode            | `make sim-decode-s5`         |
| Integer LSU (stage 5)  | `tb/stage5/tb_lsu_s5.sv`             | 64-bit LD/SD/AMO with FP ports tied off | `make sim-lsu-s5`            |
| Muldiv (stage 5)       | `tb/stage5/tb_muldiv_s5.sv`          | 4-cycle MUL FSM                         | `make sim-muldiv-s5`         |
| FP decode              | `tb/stage5/tb_decode_fp.sv`          | F/D instruction decode                  | `make sim-decode-fp`         |
| FP regfile             | `tb/stage5/tb_regfile_fp.sv`         | 3R1W 32×64 FP regfile + NaN-box         | `make sim-regfile-fp`        |
| FP LSU                 | `tb/stage5/tb_lsu_fp.sv`             | FLW/FLD/FSW/FSD, NaN-box on FLW         | `make sim-lsu-fp`            |
| FP CSR                 | `tb/stage5/tb_csr_fp.sv`             | FCSR/FRM/FFLAGS behaviour               | `make sim-csr-fp`            |
| FPU scoreboard         | `tb/stage5/tb_fpu_scoreboard.sv`     | FP issue-queue scoreboard               | `make sim-fpu-scoreboard`    |
| FPU FADD               | `tb/stage5/tb_fpu_fadd.sv`           | FADD/FSUB (IEEE-754 binary32/64)        | `make sim-fpu-fadd`          |
| FPU FMUL               | `tb/stage5/tb_fpu_fmul.sv`           | FMUL                                    | `make sim-fpu-fmul`          |
| FPU FMA                | `tb/stage5/tb_fpu_fma.sv`            | FMADD/FMSUB/FNMADD/FNMSUB               | `make sim-fpu-fma`           |
| FPU FCVT               | `tb/stage5/tb_fpu_fcvt.sv`           | int↔fp / fp↔fp conversions             | `make sim-fpu-fcvt`          |
| FPU FMISC              | `tb/stage5/tb_fpu_fmisc.sv`          | FMIN/FMAX/FSGNJ/FMV/FCLASS             | `make sim-fpu-fmisc`         |
| FPU FDIV core          | `tb/stage5/tb_fpu_fdiv_core.sv`      | SRT FDIV core (stage 5b)               | `make sim-fpu-fdiv-core`     |
| FPU FSQRT core         | `tb/stage5/tb_fpu_fsqrt_core.sv`     | SRT FSQRT core (stage 5b)              | `make sim-fpu-fsqrt-core`    |
| FPU iter wrapper       | `tb/stage5/tb_fpu_iter.sv`           | Iterative-unit dispatch wrapper        | `make sim-fpu-iter-skeleton` |
| FPU top                | `tb/stage5/tb_fpu_top.sv`            | Full FPU top (no iter) vs SoftFloat    | `make sim-fpu-top`           |
| FPU top + iter         | `tb/stage5/tb_fpu_top_iter.sv`       | Full FPU with FDIV/FSQRT iter          | `make sim-fpu-top-iter`      |
| Hardfloat smoke        | `tb/stage5/tb_hardfloat_smoke.sv`    | Hardfloat library smoke                | `make sim-hf-smoke`          |
| Softfloat smoke        | `tb/stage5/tb_softfloat_smoke.sv`    | Softfloat DPI smoke                    | `make sim-sf-smoke`          |
| Core FP basic          | `tb/stage5/tb_core_fp_basic.sv`      | Top-level FP smoke                     | `make sim-core-fp-basic`     |
| Core FP forwarding     | `tb/stage5/tb_core_fp_forwarding.sv` | FP writeback→consumer forwarding       | `make sim-core-fp-forwarding`|
| CSR perf               | `tb/stage5/tb_csr_perf.sv`           | mcountinhibit / mhpmcounter / event-mux | `make sim-csr-perf-s5`      |

### Assembly programs (stage 5)
| Test                      | File                                       | Exercises                              | Run                                  |
|---------------------------|--------------------------------------------|----------------------------------------|--------------------------------------|
| `test_fp_basic`           | `sw/stage5/test_fp_basic.S`                | FADD/FMUL/FSUB smoke                   | `make run-s5-test_fp_basic`          |
| `test_fp_loadstore`       | `sw/stage5/test_fp_loadstore.S`            | FLW/FSW/FLD/FSD                        | `make run-s5-test_fp_loadstore`      |
| `test_fp_nan_box`         | `sw/stage5/test_fp_nan_box.S`              | NaN-boxing rules                       | `make run-s5-test_fp_nan_box`        |
| `test_fp_rounding`        | `sw/stage5/test_fp_rounding.S`             | RM/FRM rounding modes                  | `make run-s5-test_fp_rounding`       |
| `test_fp_csr`             | `sw/stage5/test_fp_csr.S`                  | FCSR/FRM/FFLAGS                        | `make run-s5-test_fp_csr`            |
| `test_fp_convert`         | `sw/stage5/test_fp_convert.S`              | FCVT between int/fp                    | `make run-s5-test_fp_convert`        |
| `test_fp_compare`         | `sw/stage5/test_fp_compare.S`              | FEQ/FLT/FLE/FCLASS                     | `make run-s5-test_fp_compare`        |
| `test_rvc_fp_loadstore`   | `sw/stage5/test_rvc_fp_loadstore.S`        | C.FSW/C.FLW RVC FP loads/stores        | `make run-s5-test_rvc_fp_loadstore`  |
| `test_fcvt_sd_subnormal`  | `sw/stage5/test_fcvt_sd_subnormal.S`       | Subnormal SP↔DP conversion             | `make run-s5-test_fcvt_sd_subnormal` |
| `test_mstatus_fs_dirty`   | `sw/stage5/test_mstatus_fs_dirty.S`        | mstatus.FS dirty-tracking              | `make run-s5-test_mstatus_fs_dirty`  |
| `test_muldiv_redirect`    | `sw/stage5/test_muldiv_redirect.S`         | Muldiv request under EX/MEM redirect   | `make run-s5-test_muldiv_redirect`   |
| `test_blt64`              | `sw/stage5/test_blt64.S`                   | RV64 branch edge case                  | `make run-s5-test_blt64`             |
| `test_blt_act4`           | `sw/stage5/test_blt_act4.S`                | BLT regression from ACT4               | `make run-s5-test_blt_act4`          |
| `test_mret_rvc`           | `sw/stage5/test_mret_rvc.S`                | MRET into compressed instruction       | `make run-s5-test_mret_rvc`          |
| `test_csr_warl`           | `sw/stage5/test_csr_warl.S`                | WARL/WLRL CSR field probing            | `make run-s5-test_csr_warl`          |
| `test_illegal_insn`       | `sw/stage5/test_illegal_insn.S`            | Illegal instruction trap coverage      | `make run-s5-test_illegal_insn`      |
| `test_perf_counters`      | `sw/stage5/test_perf_counters.S`           | Zicntr + Zihpm event counters          | `make run-s5-test_perf_counters`     |
| `test_icache_hit_loop`    | `sw/stage5/test_icache_hit_loop.S`         | I$ miss count bounded on tight loop    | `make run-s5-test_icache_hit_loop`   |

### ACT4 compliance
- 303 tests (rv64imafdc). Run: `make sim-arch-test-s5`.

### Constrained-random verification

| Scenario             | Make target                     |
|----------------------|----------------------------------|
| `int_hazards`        | `make sim-crv-int_hazards`       |
| `muldiv_interleave`  | `make sim-crv-muldiv_interleave` |
| `mem_ordering`       | `make sim-crv-mem_ordering`      |
| `fp_arith`           | `make sim-crv-fp_arith`          |
| `fdiv_fsqrt`         | `make sim-crv-fdiv_fsqrt`        |
| `branch_pred`        | `make sim-crv-branch_pred`       |
| `traps`              | `make sim-crv-traps`             |
| Smoke (PR path)      | `make sim-crv-smoke`             |
| Coverage gate        | `make sim-crv-coverage`          |
| Deep (nightly)       | `make sim-crv-deep`              |
| Directed assists     | `make sim-crv-assists`           |

### Instruction cache

| Test                | Make target                             |
|---------------------|------------------------------------------|
| Unit TB             | `make sim-icache`                       |
| Integration         | `make run-s5-test_icache_hit_loop`      |

### Data cache

| Test                | Make target                             |
|---------------------|------------------------------------------|
| Unit TB             | `make sim-dcache`                       |
| Integration         | `make run-s5-test_dcache_hit_loop`      |

## Stage 5b — adds FDIV/FSQRT

### Assembly programs (stage 5b)
| Test                     | File                                        | Exercises                             | Run                                  |
|--------------------------|---------------------------------------------|---------------------------------------|--------------------------------------|
| `test_fdiv_basic`        | `sw/stage5b/test_fdiv_basic.S`              | FDIV.S/FDIV.D smoke                   | `make run-s5-test_fdiv_basic`        |
| `test_fsqrt_basic`       | `sw/stage5b/test_fsqrt_basic.S`             | FSQRT.S/FSQRT.D smoke                 | `make run-s5-test_fsqrt_basic`       |
| `test_fdiv_rounding`     | `sw/stage5b/test_fdiv_rounding.S`           | FDIV rounding modes                   | `make run-s5-test_fdiv_rounding`     |
| `test_fsqrt_rounding`    | `sw/stage5b/test_fsqrt_rounding.S`          | FSQRT rounding modes                  | `make run-s5-test_fsqrt_rounding`    |
| `test_fdiv_exceptions`   | `sw/stage5b/test_fdiv_exceptions.S`         | FDIV NV/DZ/OF/UF/NX flags             | `make run-s5-test_fdiv_exceptions`   |
| `test_fsqrt_exceptions`  | `sw/stage5b/test_fsqrt_exceptions.S`        | FSQRT NV/NX flags                     | `make run-s5-test_fsqrt_exceptions`  |
| `test_fdiv_subnormal`    | `sw/stage5b/test_fdiv_subnormal.S`          | Subnormal FDIV handling               | `make run-s5-test_fdiv_subnormal`    |
| `test_fsqrt_subnormal`   | `sw/stage5b/test_fsqrt_subnormal.S`         | Subnormal FSQRT handling              | `make run-s5-test_fsqrt_subnormal`   |
| `test_fdiv_nan_box`      | `sw/stage5b/test_fdiv_nan_box.S`            | NaN-boxing on FDIV result             | `make run-s5-test_fdiv_nan_box`      |
| `test_fdiv_stall`        | `sw/stage5b/test_fdiv_stall.S`              | Pipeline stall during FDIV iteration  | `make run-s5-test_fdiv_stall`        |
| `test_fdiv_irq`          | `sw/stage5b/test_fdiv_irq.S`                | FDIV results preserved after IRQ/MRET | `make run-s5b-test_fdiv_irq`         |

## Stage 5c — Performance counters (Zicntr + partial Zihpm)

### Unit testbenches
| Module    | TB file                     | Coverage focus                          | Run                     |
|-----------|------------------------------|------------------------------------------|-------------------------|
| CSR perf  | `tb/stage5/tb_csr_perf.sv`  | mcountinhibit / mhpmcounter / event-mux | `make sim-csr-perf-s5`  |

### Assembly programs
| Test                 | File                              | Exercises                                                              | Run                              |
|-----------------------|------------------------------------|--------------------------------------------------------------------------|-----------------------------------|
| `test_perf_counters`  | `sw/stage5/test_perf_counters.S`  | mcycle/minstret SW-write; mhpmcounter3 (branches) / mhpmcounter4 (loads); mcountinhibit freeze; out-of-range event ID is inert | `make run-s5-test_perf_counters` |

Gated by `make sim-all` and `make sim-arch-test-s5`; no dedicated ACT4 suite (Zicntr/Zihpm are not ACT4-covered extensions).

## Stage 5d — Constrained-random verification harness

Landed the `tools/crv/` generator + `tb/stage5/tb_crv_cov.sv` functional-coverage TB and the `sw/stage5/crv_assists/` directed-assist programs. The scenario table, coverage gate, and assist-directory listing are documented once, under **Stage 5 → Constrained-random verification** above, rather than duplicated here — that subsection *is* Stage 5d's test surface.

## Stage 5e — Instruction cache

16 KB / 4-way / Tree-PLRU I-cache with critical-word-first AXI WRAP refill and FENCE.I full invalidate. Test surface documented under **Stage 5 → Instruction cache** above (`tb/stage5/tb_icache.sv` via `make sim-icache`; `test_icache_hit_loop` via `make run-s5-test_icache_hit_loop`).

## Stage 5f — Data cache

16 KB / 4-way / Tree-PLRU write-back/write-allocate D-cache with AMO RMW and LR/SC reservation handled in-cache; LSU shrunk to a thin adapter. Test surface documented under **Stage 5 → Data cache** above (`tb/stage5/tb_dcache.sv` via `make sim-dcache`; `test_dcache_hit_loop` via `make run-s5-test_dcache_hit_loop`).

## Stage 5g — FENCE.I → D-cache flush

Added a flush FSM to `kronos_dcache` (`flush_i` / `flush_done_o` / `dirty_pending_o`) so FENCE.I drains dirty write-back lines before the I-cache invalidate propagates. Re-enabled the `Zifencei` ACT4 suite (previously excluded — `gen-arch-tests-s5` now runs with only `--exclude Zaamo,Zalrsc`). Also deleted `tb/stage5/tb_lsu_s5.sv` and `tb/stage5/tb_lsu_fp.sv` (and their `sim-lsu-s5` / `sim-lsu-fp` Makefile targets) as part of the same PR, since the LSU became a thin adapter with no independent FSM left to unit-test — see the note on stale rows under Stage 5 above.

### Unit testbenches
| Module              | TB file                    | Coverage focus                                                   | Run                |
|---------------------|------------------------------|--------------------------------------------------------------------|---------------------|
| D-cache flush (task `test_flush_drains_dirty_lines` inside `tb_dcache`) | `tb/stage5/tb_dcache.sv` | Dirty-line writeback drain on `flush_i`; post-flush reload misses | `make sim-dcache`  |

### Assembly programs
| Test          | File                       | Exercises                                             | Run                        |
|----------------|------------------------------|----------------------------------------------------------|------------------------------|
| `test_fence_i` | `sw/stage5/test_fence_i.S`  | FENCE.I ordering against a dirty D-cache line             | `make run-s5-test_fence_i` |

## Stage 5h — Debug & trace layer

Two independent additions: (A1) a fine-grained pipeline-stall event taxonomy (12 new `mhpmevent` IDs, 0x14–0x1F) feeding the Stage 5c performance counters, and (A2) a Sdtrig hardware trigger module (`kronos_trigger`) routed through `kronos_csr` for PC and load-address breakpoints.

### Unit testbenches
| Module            | TB file                     | Coverage focus                                    | Run                |
|--------------------|--------------------------------|-------------------------------------------------------|----------------------|
| Trigger (Sdtrig)  | `tb/stage5/tb_trigger.sv`   | PC / load-address trigger match, `tdata1`/`tdata2` CSR behaviour | `make sim-trigger`  |

### Assembly programs
| Test                        | File                                     | Exercises                                                                 | Run                                    |
|-------------------------------|---------------------------------------------|-------------------------------------------------------------------------------|-------------------------------------------|
| `test_perf_event_taxonomy`  | `sw/stage5/test_perf_event_taxonomy.S`   | mhpmcounter3..10 against the 12 new fine-grained stall event IDs (0x14–0x1F) | `make run-s5-test_perf_event_taxonomy` |
| `test_sdtrig`               | `sw/stage5/test_sdtrig.S`                | PC trigger + load-address trigger, both firing with `mcause = 3` (BREAKPOINT) and resuming correctly | `make run-s5-test_sdtrig`              |

## Stage 6a — Privileged modes (M/S/U) + PMP

New `rtl/stage6/` tree: `kronos_pmp` (16-region PMP) plus M/S/U privilege state, trap delegation, and a 6-source IRQ in `kronos_csr`/`kronos_top`.

### Unit testbenches
| Module    | TB file                     | Coverage focus                                   | Run                 |
|------------|--------------------------------|-------------------------------------------------------|-----------------------|
| PMP       | `tb/stage6/tb_pmp.sv`       | 16-region match/permission logic, lock bits          | `make sim-pmp`      |
| Priv CSR  | `tb/stage6/tb_priv_csr.sv`  | mstatus/mideleg/medeleg/PMP CSR RW, WARL fields       | `make sim-priv-csr` |

### Assembly programs
| Test                | File                              | Exercises                                          | Run                          |
|----------------------|--------------------------------------|---------------------------------------------------------|---------------------------------|
| `test_priv_smode`   | `sw/stage6/test_priv_smode.S`     | M→S privilege transition via `mret`                    | `make run-s6-test_priv_smode`   |
| `test_delegation`   | `sw/stage6/test_delegation.S`     | `ecall` from U delegated to an S-mode handler           | `make run-s6-test_delegation`   |
| `test_pmp_basic`    | `sw/stage6/test_pmp_basic.S`      | PMP deny-on-locked region                                | `make run-s6-test_pmp_basic`    |
| `test_sret`         | `sw/stage6/test_sret.S`           | TSR gates `sret` in S-mode                               | `make run-s6-test_sret`         |
| `test_csr_priv`     | `sw/stage6/test_csr_priv.S`       | U-mode read of `mhpmcounter3` without `scounteren`      | `make run-s6-test_csr_priv`     |
| `test_priv_smoke`   | `sw/stage6/test_priv_smoke.S`     | End-to-end M/S/U smoke                                   | `make run-s6-test_priv_smoke`   |

### ACT4 compliance
- RV64IMAFDC + privileged (M/S/U) subset. Run: `make sim-arch-test-s6`.

## Stage 6b — Sv39/Sv48 MMU

New `kronos_tlb` (8-entry CAM iTLB/dTLB) and `kronos_ptw` (hardware page-table walker) supporting Sv39 and Sv48.

### Unit testbenches
| Module  | TB file                  | Coverage focus                          | Run             |
|----------|-----------------------------|----------------------------------------------|--------------------|
| TLB     | `tb/stage6/tb_tlb.sv`   | 8-entry CAM, hit/miss/invalidate/`sfence.vma` | `make sim-tlb`  |
| PTW     | `tb/stage6/tb_ptw.sv`   | Sv39/Sv48 walk, A/D-bit update, page faults    | `make sim-ptw`  |

### Assembly programs
| Test                      | File                                     | Exercises                                        | Run                                  |
|-----------------------------|---------------------------------------------|-------------------------------------------------------|-------------------------------------------|
| `test_sv39_basic`         | `sw/stage6b/test_sv39_basic.S`           | Sv39 basic translation                                | `make run-s6b-test_sv39_basic`         |
| `test_sv48_basic`         | `sw/stage6b/test_sv48_basic.S`           | Sv48 basic translation                                | `make run-s6b-test_sv48_basic`         |
| `test_superpage_2m`       | `sw/stage6b/test_superpage_2m.S`         | 2 MiB superpage mapping                                | `make run-s6b-test_superpage_2m`       |
| `test_superpage_1g`       | `sw/stage6b/test_superpage_1g.S`         | 1 GiB superpage mapping                                | `make run-s6b-test_superpage_1g`       |
| `test_page_fault`         | `sw/stage6b/test_page_fault.S`           | Page-fault cause/`mtval` correctness                    | `make run-s6b-test_page_fault`         |
| `test_sfence`             | `sw/stage6b/test_sfence.S`               | `sfence.vma` TLB invalidation                           | `make run-s6b-test_sfence`             |
| `test_ad_update`          | `sw/stage6b/test_ad_update.S`            | Hardware A/D-bit update on PTE                          | `make run-s6b-test_ad_update`          |
| `test_user_smode_swap`    | `sw/stage6b/test_user_smode_swap.S`      | U/S address-space swap via `satp`                       | `make run-s6b-test_user_smode_swap`    |

### ACT4 compliance
- RV64IMAFDC + privileged + Sv39/Sv48 (UDB-generated `kronos-rv64imafdc-priv` config). Run: `make sim-arch-test-s6-priv`. A fixed set of Sv canonical/all-ones/all-zeros edge-case tests are excluded because the Sail reference model can't sign them inside the harness's 60 s wrapper timeout (`S6_PRIV_SKIPPED_TESTS` in `sim/Makefile`), not because kronos fails them.

## Stage 6c — Closeout

Bundled five closing changes for the Stage 6 series: the dhrystone perf-baseline gate, a long-running integration program targeting five risks left unverified by 6b, an `mstatus` reset-value fix (FS: 01→00, matching Sail) plus a retire-trace fix (`retire_csr_wdata_o` now carries the post-write CSR value instead of the RS1 operand), and the GLS-s6 stage-transition gate (see **Stage transition gates** below — this stage is where that gate was first documented).

### Assembly programs
| Test                    | File                                    | Exercises                                                                                                          | Run                                     |
|--------------------------|--------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| `test_integration_long` | `sw/stage6b/test_integration_long.S`    | 5 previously-unverified Stage 6b risks: cross-page fetch precision, PTW × dcache deadlock, A/D atomic vs. SW reservation, `satp.MODE` WARL-reject, cross-RVC-boundary fetch fault | `make run-s6b-test_integration_long`   |

### Performance gate
| Gate                    | Workload                                   | Threshold                    | Run                          |
|--------------------------|------------------------------------------------|-----------------------------------|----------------------------------|
| `sim-perf-baseline-s6`  | `sw/perf/dhrystone/` (mcycle-marked, main-only) | ±2% vs. baked-in baseline cycle count | `make sim-perf-baseline-s6` (CI job `perf-baseline-s6`) |

## Stage 6d — `kronos_ram` SDP BRAM wrapper

Introduced the parameterised `kronos_ram.sv` SDP RAM wrapper (XPM FPGA backend / behavioural ASIC-stub backend) described in §3 of `docs/architecture.md`, plus its unit TB. This PR landed the wrapper standalone — no cache datapath used it yet; that integration lands in Stage 6f (icache) and 6g (dcache).

### Unit testbenches
| Module        | TB file                          | Coverage focus                                              | Run                  |
|-----------------|--------------------------------------|-------------------------------------------------------------------|--------------------------|
| `kronos_ram`   | `tb/common/tb_kronos_ram.sv`     | Same-cycle write/read collision (`no_change`), byte-write semantics | `make sim-kronos-ram`  |

No new assembly programs; gated by `make sim-all` and `make sim-arch-test-s6`.

## Stage 6e — PMA / MMIO non-cacheable regions

Added a PMA (physical memory attribute) layer so `kronos_dcache` bypasses the cache for non-cacheable (MMIO) regions, with AMOs on non-cacheable addresses trapping (`cause = 7`, store/AMO access fault).

### Unit testbenches
| Module         | TB file                          | Coverage focus                                    | Run                       |
|------------------|--------------------------------------|---------------------------------------------------------|-------------------------------|
| D-cache PMA     | `tb/stage6/tb_dcache_pma.sv`     | Non-cacheable single-beat read/write bypass, AMO trap    | `make sim-dcache-pma-s6`   |

### Assembly programs
| Test                    | File                                  | Exercises                              | Run                                |
|--------------------------|------------------------------------------|----------------------------------------------|----------------------------------------|
| `test_pma_mmio_load`    | `sw/stage6/test_pma_mmio_load.S`     | Single-beat non-cacheable read              | `make run-s6-test_pma_mmio_load`    |
| `test_pma_mmio_store`   | `sw/stage6/test_pma_mmio_store.S`    | Non-cacheable write + readback round-trip   | `make run-s6-test_pma_mmio_store`   |
| `test_pma_amo_trap`     | `sw/stage6/test_pma_amo_trap.S`      | AMO on a non-cacheable address traps (cause=7) | `make run-s6-test_pma_amo_trap`     |

## Stage 6f — BOOM-style frontend rewrite

Split the I-cache into an s0/s1/s2 pipeline (tag compare moved off the combinational input onto a registered `addr_s1_q`), converted its `data_q` array to 4×`kronos_ram` (BRAM), and added a standalone `kronos_fetch_buffer` (depth-4 FIFO) and `kronos_predecode` block (RVC expansion + halfword-span tracking) that together replace the old combined `kronos_align` FSM.

### Unit testbenches
| Module            | TB file                       | Coverage focus                                                | Run                    |
|--------------------|----------------------------------|----------------------------------------------------------------------|----------------------------|
| Fetch buffer      | `tb/common/tb_fetch_buffer.sv` | Depth-4 FIFO decoupling icache S2 from decode back-pressure           | `make sim-fetch-buffer`  |
| Predecode         | `tb/common/tb_predecode.sv`    | RVC expansion + halfword-span tracking                                | `make sim-predecode`     |
| IFU integration   | `tb/common/tb_ifu.sv`          | icache + fetch buffer + predecode + AXI mock, end-to-end               | `make sim-ifu`           |
| I-cache (updated) | `tb/stage5/tb_icache.sv`       | Staged S0/S1/S2 interface (also stage 5's icache — file shared)        | `make sim-icache`        |

No new directed assembly programs; gated by `make sim-all`, `make sim-arch-test-s5`, and `make sim-arch-test-s6`.

## Stage 6g — Data cache BRAM-back

Wrapped `kronos_dcache.data_q` in 4×`kronos_ram` (one per way), matching the icache's Stage 6f treatment, while preserving the same-cycle hit response the LSU depends on.

No new unit TB or assembly programs; gated by the existing `make sim-dcache` / `make sim-dcache-pma-s6`, `make sim-arch-test-s6`, CRV smoke, and a dhrystone IPC-parity check (±2% vs. the post-6f baseline).

## Stage 6h — Cache tag arrays + FP regfile in BRAM/LUTRAM

Moved the I-cache and D-cache tag/valid arrays and the FP register file into BRAM/LUTRAM, closing issue #79 (total FF count ~44.8 K → ~16.5 K on `xck26`).

No new unit TB or assembly programs; gated by `make sim-all`, `make sim-arch-test-s6`, `make sim-arch-test-s6-priv`, `make sim-crv-smoke`, and `make gls-funcsim-s6`.

## Stage 6i — Verification overhaul

Closed out Stage 6's verification debt: a scoreboard-driven `tb_dcache.sv` rewrite, a dcache stress target with a configurable seed, the cosim mutational fuzzer's smoke/deep CI jobs, and the CRV harness's stage-6 variant (`sim-crv-s6-%` targets). Added `test_dcache_raw.S` as a Stage-6-specific directed regression.

### Unit testbenches
| Module               | TB file                                                              | Coverage focus                                  | Run                            |
|-----------------------|---------------------------------------------------------------------------|-------------------------------------------------------|-------------------------------------|
| D-cache (scoreboard) | `tb/stage6/tb_dcache.sv` + `tb/stage6/dcache_scoreboard.sv`             | Reference-scoreboard-checked directed + randomized ops | `make sim-dcache-s6`               |

### Assembly programs
| Test              | File                          | Exercises                     | Run                       |
|--------------------|----------------------------------|-------------------------------------|--------------------------------|
| `test_dcache_raw` | `sw/stage6/test_dcache_raw.S` | Read-after-write dcache ordering  | `make run-s6-test_dcache_raw` |

### Stress / cosim / CRV gates
| Gate                        | What it does                                                      | Run                                |
|-------------------------------|------------------------------------------------------------------------|-----------------------------------------|
| D-cache stress (single seed)  | 10 k randomized RAW ops against the scoreboard                        | `make sim-dcache-s6-stress` (CI: `dcache-stress-s6`) |
| D-cache stress (deep, nightly) | Same, 100 seeds                                                       | `make sim-dcache-s6-stress-deep` (nightly) |
| CRV smoke (stage 6)           | 7 scenarios × seed 0 on the stage-6 (privileged) RTL                  | `make sim-crv-smoke-s6` (CI: `crv-smoke-s6`) |
| CRV deep (stage 6, nightly)   | Same scenarios, deep seed sweep                                       | `make sim-crv-deep-s6` (nightly: `crv-deep-s6`) |
| Cosim fuzzer smoke            | Source-level mutational fuzzer, 1 mutation/program, vs. `sail_riscv_sim` | `make sim-cosim-smoke` (CI: `cosim-smoke`) |
| Cosim fuzzer deep (nightly)   | Same, seeds 0–49                                                       | `make sim-cosim-deep` (nightly: `cosim-deep`) |
| `putdec_stack` regression     | Standalone reproducer for issue #82 (bypass correctness)               | `make sim-cosim-putdec`            |

### ACT4 compliance
- Run: `make sim-arch-test-s6` and `make sim-arch-test-s6-priv` (nightly: `compliance-s6-priv`).

## Stage 7a — Fault-bit EX1/EX2 split

First sub-stage of the in-order Fmax push (see `docs/superpowers/specs/2026-05-05-stage7-fmax-master-design.md`, gitignored/local). Restructures `kronos_top` to register every fault source into a `fault_t` bit one stage past its producer, and splits Execute into EX1 (ALU/AGU/muldiv dispatch/branch compare/CSR RMW/FPU dispatch) and EX2 (fault aggregation + direction-mispredict redirect). No new RTL modules — same file set as Stage 6, restructured in place (`rtl/stage7/`).

### Assembly programs
| Test                       | File                                     | Exercises                                                   | Run                                   |
|-------------------------------|----------------------------------------------|-------------------------------------------------------------------|--------------------------------------------|
| `test_fault_propagation`    | `sw/stage7a/test_fault_propagation.S`    | Registered `fault_t` propagation across the EX1/EX2 boundary       | `make run-s7a-test_fault_propagation`    |

Gated by `make ci-local` (lint + ACT4-s5/s6/s6-priv + `sim-all` + `sim-cosim-smoke`).

## Stage 7b — RR (register-read) stage + bypass network rebuild

Adds a dedicated RR stage before EX1 (integer/FP register reads and the operand-bypass mux move out of ID/EX) and rebuilds `kronos_forward` around 6 producer slots (`FWD_EX1_NOW`, `FWD_EX1`, `FWD_EXMEM`, `FWD_MEM1B`, `FWD_MEM2`, `FWD_MEMWB`). No new RTL modules.

The 6 directed `sw/stage7b/` tests the implementation plan specified (`test_rr_alu_alu`, `test_rr_load_use`, `test_rr_csr_speculative`, `test_rr_csr_raw`, `test_rr_jalr_fwd`, `test_rr_fault_propagation`) were never committed — the landing commit (`ed9c144`) touched no `sw/` or `tb/` files, and no `sw/stage7b/` directory exists in the tree. Stage 7b's correctness is covered instead by the full `sw/stage6/` + `sw/stage7a/` + `sw/stage7c/` regressions running against the rebuilt bypass network, plus `compliance-cycle-diff-s7b` (dhrystone cycle-budget gate vs. the Stage 7a baseline `ef7378e`, ≤5% marginal regression, CI job `compliance-cycle-diff-s7b`).

Gated by `make ci-local`, `make sim-cosim-deep TESTS=10000`, and `compliance-cycle-diff-s7b`.

## Stage 7c — MEM1/MEM2 split

Splits Memory access into MEM1 (dTLB lookup start + data-side PMP) and MEM2 (dcache hit/data + target-mispredict/trap redirect formation). No new RTL modules; reuses the `files_rtl_s7a` fileset name (kept from the 7a/7b merges rather than renamed).

### Assembly programs
| Test                         | File                                       | Exercises                                                | Run                                     |
|--------------------------------|-------------------------------------------------|-----------------------------------------------------------------|-----------------------------------------------|
| `test_mem_amo_split`          | `sw/stage7c/test_mem_amo_split.S`             | LR/SC + AMOADD across the MEM1/MEM2 boundary                     | `make run-s7c-test_mem_amo_split`             |
| `test_mem_csr_raw_5slot`      | `sw/stage7c/test_mem_csr_raw_5slot.S`         | Back-to-back CSR RAW hazard across 5 pipeline slots               | `make run-s7c-test_mem_csr_raw_5slot`         |
| `test_mem_jalr_load_fwd`      | `sw/stage7c/test_mem_jalr_load_fwd.S`         | JALR target forwarding from a load result                        | `make run-s7c-test_mem_jalr_load_fwd`         |
| `test_mem_load_use_5cycle`    | `sw/stage7c/test_mem_load_use_5cycle.S`       | Load-use stall latency (renamed from `..._3cycle` in Stage 7e once MEM1B pushed the load-use distance to 5 cycles) | `make run-s7c-test_mem_load_use_5cycle`       |
| `test_mem_pmp_pf`             | `sw/stage7c/test_mem_pmp_pf.S`                | PMP fault + page-fault interaction at MEM1                        | `make run-s7c-test_mem_pmp_pf`                |
| `test_mem_target_mispredict`  | `sw/stage7c/test_mem_target_mispredict.S`     | Target-mispredict redirect formed at MEM2                         | `make run-s7c-test_mem_target_mispredict`     |

Or run the whole set at once: `make sim-stage7c-asm` (parallel launch, pass/fail summary). The landing commit shipped with residual sub-test failures in 4 of these 6 (`test_mem_csr_raw_5slot`, `test_mem_amo_split`, `test_mem_target_mispredict`, `test_mem_load_use_3cycle`); all 6 pass cleanly as of this worktree's HEAD (verified directly: `make sim-stage7c-asm` → `Stage 7c asm: 6 passed, 0 failed`).

Gated by `make ci-local`, `make sim-cosim-deep TESTS=10000`, and `compliance-cycle-diff-s7c` (dhrystone cycle-budget gate, current baseline commit `a4a25f9` / Stage 7e.0, ≤22% — see **Stage transition gates** section for why the budget kept rising).

## Stage 7d — MEM1B pipeline-register split + timing retimes

No new RTL modules. Splits MEM1B out as the dTLB's internal S0/S1 encode sub-stage (its own pipeline register, `mem1_mem2_q` — see the naming quirk noted in `docs/architecture.md` §0), retimes the PMP comparator chain, suppresses `FWD_MEM2` load forwarding, and retimes `trap_vector`. Landed as two sub-PRs (`stage7d-fmax` RTL, then `stage7d-closeout-rtl`). Post-route WNS improved from −3.128 ns to −2.872 ns on KV260 (xck26-2LV, Vivado 2025.2); the Pblock floorplan step was deferred to 7e.

No new directed assembly programs (reuses `sw/stage7c/`). Gated by `make ci-local`, ACT4 s5 (307/307) and s6 (305/305) as recorded at landing, `make sim-all`, and a dhrystone completion check plus the Vivado synth+impl WNS gate.

## Stage 7e — dTLB internal S0/S1 split + stall-network retime

No new RTL modules. Splits the dTLB's internal pipeline into an S0/S1 sub-stage pair (landed), and retimes the PMP path further. Also renamed `sw/stage7c/test_mem_load_use_3cycle.S` → `test_mem_load_use_5cycle.S` once the added pipeline depth pushed the load-use stall to 5 cycles. A follow-on stall-network retime — registering `event_bus` ahead of the `mhpmcounter` clock-enable fan-in — remains open (see `docs/architecture.md` §1, Stage 7e row).

No new directed assembly programs. Gated by `make ci-local`, ACT4 s5/s6/s6-priv, `make sim-all`, `make sim-cosim-deep TESTS=10000`, `compliance-cycle-diff-s7c` (vs. the s7e.0 baseline, budget 22%), and the Vivado synth+impl WNS gate.

## Stage transition gates

A "stage transition gate" is a verification activity that **must** run clean before a stage is tagged complete and merged. Gates are not part of default CI when their cost makes per-PR execution impractical; instead they are run manually before the closing PR is opened, and the result is captured in the PR description as a one-line evidence note.

Current gates:

| Gate | When | How | Evidence |
|------|------|-----|----------|
| **GLS-s6** (xsim funcsim + SDF timing-sim on the smoke subset) | Before tagging Stage 6c, 6d, 6e, … complete | `make gls-funcsim-s6 GLS_TEST=<n>` and `make gls-sdf-s6 GLS_TEST=<n>` for at least 4 programs (1 directed + 1 CRV smoke seed + 1 ACT4 priv test + the long integration program) | "GLS-s6 ran clean as of commit <SHA>: 4/4 PASS, max sim runtime <m> min" in PR body |

Why GLS is gated rather than CI'd: GitHub-hosted runners do not have the disk space (~14 GB free) for a Vivado install (~10–15 GB minimum, ~30 GB full). Self-hosted runners with Vivado pre-installed would lift this restriction; until then, GLS is a manual checkpoint.

Stage 5 GLS infrastructure (`gls-funcsim-s5`, `gls-sdf-s5`) operates the same way and predates this section.

## Cross-cutting verification

### Sail differential trace (Phase 1 P1.1)

- Scope: every stage-5 assembly test + every ACT4 ELF.
- Mechanism: Kronos emits a normalized retire trace via `SIM_TRACE`;
  `tools/sail_trace.sh` runs `sail_riscv_sim` and normalizes to the same
  format; `tools/trace_diff.py` diffs line-by-line.
- Run single: `make sim-diff-<test>`.
- Run all: `make sim-diff-all`.
- Known skips: any test that injects timer IRQ (non-deterministic vs Sail).
  List updated by the Makefile `SIM_DIFF_SKIP` variable.

### Line-coverage gate

- Modules under gate: 5 FP units (fmisc, fcvt, fadd, fmul, fma) plus
  stage-5 integer ALU, muldiv, decode, LSU. Merged threshold: ≥90%.
- Run: `make coverage`.
- Reports: `sim/obj_dir/coverage/merged.info` (lcov-compatible).

## Interaction / scenario tests (Phase 2)

### P2.1 — Pipeline/interrupt interaction

| Test               | File                                | Exercises                                   | Run                                |
|--------------------|-------------------------------------|---------------------------------------------|------------------------------------|
| `test_fdiv_irq`    | `sw/stage5b/test_fdiv_irq.S`        | FDIV results survive IRQ/MRET cycle         | `make run-s5b-test_fdiv_irq`       |
| `test_mret_rvc`    | `sw/stage5/test_mret_rvc.S`         | MRET into 2-byte compressed instruction     | `make run-s5-test_mret_rvc`        |

### P2.2 — CSR probing

| Test              | File                               | Exercises                                              | Run                               |
|-------------------|------------------------------------|--------------------------------------------------------|-----------------------------------|
| `test_csr_warl`   | `sw/stage5/test_csr_warl.S`        | mstatus SD read-only; frm=5 → DYN trap; mepc storage  | `make run-s5-test_csr_warl`       |

### P2.3 — Illegal instruction coverage

| Test                  | File                                   | Exercises                                        | Run                                   |
|-----------------------|----------------------------------------|--------------------------------------------------|---------------------------------------|
| `test_illegal_insn`   | `sw/stage5/test_illegal_insn.S`        | 4× reserved-opcode 32-bit + 1× C.ILLEGAL 16-bit | `make run-s5-test_illegal_insn`       |

**Notes:**
- `test_fdiv_irq` uses IRQ injection (non-deterministic vs Sail) and lives in `sw/stage5b/`; not included in `sim-diff-all`.
- `test_mret_rvc`, `test_csr_warl`, `test_illegal_insn` are deterministic and covered by `sim-diff-all`.
- Misaligned load straddling 4K boundary: deferred (kronos has no misalignment exception; `misaligned.supported = false` in sail.json).

## Gap register

Known untested behaviour, and why:

| Gap                                                      | Status   | Plan              |
|----------------------------------------------------------|----------|-------------------|
| IRQ injection during active FDIV stall (hardware level)  | Partial  | `test_fdiv_irq` tests post-FDIV result preservation; stall-window injection requires sim IRQ extension |
| Misaligned load straddling 4K boundary                   | Deferred | No misalignment exception in kronos; `misaligned.supported=false` |
| Constrained-random instruction generation + cov. groups  | Deferred | Phase 3 / Stage 6 |
| Formal properties on LSU / CSR                           | Deferred | Phase 3 (if needed)|

## How to add a new test

1. Choose the stage directory (`tb/stage<N>/` for unit TB, `sw/stage<N>/`
   for assembly).
2. Follow naming: underscores in files, hyphens in make targets. Example:
   `test_mem_new_case.S` under `sw/stage7c/` → target
   `make run-s7c-test_mem_new_case`.
3. Add the test to the stage's `Makefile` `TESTS` list (assembly) **or**
   the `sim/Makefile` `.PHONY` and `SIM_UNITS` lists (unit TB).
4. If the test is deterministic and has no external IRQ injection, it will
   automatically be picked up by `make sim-diff-all`. Otherwise add it to
   `SIM_DIFF_SKIP` with a one-line justification.
5. **Update this `docs/testplan.md`** in the same PR — the test is not
   landed until it is documented here.
