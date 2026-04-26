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
   `test_irq_during_div.S` → target `make run-s5-test_irq_during_div`.
3. Add the test to the stage's `Makefile` `TESTS` list (assembly) **or**
   the `sim/Makefile` `.PHONY` and `SIM_UNITS` lists (unit TB).
4. If the test is deterministic and has no external IRQ injection, it will
   automatically be picked up by `make sim-diff-all`. Otherwise add it to
   `SIM_DIFF_SKIP` with a one-line justification.
5. **Update this `docs/testplan.md`** in the same PR — the test is not
   landed until it is documented here.
