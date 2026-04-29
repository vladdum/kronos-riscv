# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 7a: RV64IMAFDC + S-mode + PMP + 16-entry Reorder Buffer.
# In-order issue, out-of-order completion. ROB-keyed bypass at ID
# replaces kronos_forward.sv; remaining hazard logic folded into
# stage7/kronos_top.sv (so kronos_hazard.sv is not instantiated).
# Paths are relative to this file's directory (rtl/).

kronos_pkg.sv
common/kronos_ram.sv
stage0/kronos_regfile.sv
stage6/kronos_align.sv
stage3/kronos_bpred.sv
stage6/kronos_alu.sv
stage6/kronos_decode.sv
stage6/kronos_regfile_fp.sv
stage6/kronos_icache.sv
stage6/kronos_pmp.sv
stage6/kronos_tlb.sv
stage6/kronos_ptw.sv
stage6/kronos_trigger.sv
stage6/kronos_dcache.sv
stage6/kronos_decompress.sv
stage6/fpu/kronos_fpu_scoreboard.sv
stage6/fpu/kronos_fpu_fmisc.sv
stage6/fpu/kronos_fpu_fcvt.sv
stage6/fpu/kronos_fpu_fadd.sv
stage6/fpu/kronos_fpu_fmul.sv
stage6/fpu/kronos_fpu_fma.sv
stage6/fpu/kronos_fpu_fdiv_core.sv
stage6/fpu/kronos_fpu_fsqrt_core.sv
stage6/fpu/kronos_fpu_iter.sv

# Stage 7a — modified
stage7/kronos_lsu.sv
stage7/kronos_csr.sv
stage7/kronos_muldiv.sv
stage7/fpu/kronos_fpu_top.sv
stage7/kronos_busy.sv
stage7/kronos_rob.sv
stage7/kronos_top.sv
