# tools/crv — Constrained-Random Verification harness

Generates random RV64IMAFDC assembly programs, runs them on Kronos and on the
Sail ISA reference model, and diffs the retire traces instruction-by-instruction.

## Scenarios

| Scenario | Focus |
|---|---|
| `int_hazards` | RAW/WAW/WAR hazards across integer ALU ops |
| `muldiv_interleave` | MUL/DIV interleaved with integer ALU |
| `mem_ordering` | Back-to-back and interleaved loads/stores to DATA + ATOMIC regions |
| `fp_arith` | Single- and double-precision FP arithmetic |
| `fdiv_fsqrt` | FDIV/FSQRT with stall hazards |
| `branch_pred` | Branch-heavy programs stressing the predictor |
| `traps` | Illegal instructions and environment calls |
| `raw_stress` | Back-to-back same-address store→load for all four widths (issue #82 class) |

## Quick start

```bash
# Single scenario, one seed
cd sim
make sim-crv-s6-mem_ordering CRV_SEED=0

# All 8 scenarios, seed 0 (smoke)
make sim-crv-smoke-s6

# All 8 scenarios × 50 seeds (deep regression)
make sim-crv-deep-s6
```

Stage 5 equivalents: `sim-crv-<scenario>`, `sim-crv-smoke`, `sim-crv-deep`.

## Reproducing a failing seed on Stage 6

When `sim-crv-deep-s6` reports a failing seed, reproduce locally with:

```bash
# Replace SCENARIO and SEED with the values from the failure log.
cd sim
make sim-crv-s6-<SCENARIO> CRV_SEED=<SEED> CRV_LENGTH=200
```

For a side-by-side trace diff:

```bash
# 1. Run the runner directly (from the repo root).
PYTHONPATH=. python3 -m tools.crv.runner \
  --scenario <SCENARIO> --seed <SEED> --length 200 \
  --build-dir sim/obj_dir/crv \
  --kronos-bin sim/obj_dir/s6/Vsim_top \
  --link-script sw/stage0/link.ld \
  --common-s   sw/stage0/common.S \
  --sail-trace-script tools/sail_trace.sh \
  --diff-script tools/trace_diff.py

# 2. The runner saves artefacts on divergence. Inspect:
ls sim/obj_dir/crv/<SCENARIO>_<SEED>/
cat sim/obj_dir/crv/<SCENARIO>_<SEED>/diff.txt
```

The diff prints the first divergence — PC, expected vs observed register
write or memory write. From there, narrow with `SIM_DEBUG=1
SIM_PC_RANGE=<lo>-<hi>` to capture cycle-by-cycle trace:

```bash
SIM_DEBUG=1 SIM_PC_RANGE=<lo_hex>-<hi_hex> \
  sim/obj_dir/s6/Vsim_top sim/obj_dir/crv/<SCENARIO>_<SEED>/prog.hex
```
