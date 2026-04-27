# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 6: RV64IMAFDC + S-mode + PMP.
# Paths are relative to this file's directory (rtl/).

kronos_pkg.sv
stage0/kronos_regfile.sv
stage1/kronos_forward.sv
stage1/kronos_hazard.sv
stage6/kronos_align.sv
stage3/kronos_bpred.sv
stage6/kronos_alu.sv
stage6/kronos_decode.sv
stage6/kronos_regfile_fp.sv
stage6/kronos_icache.sv
stage6/kronos_csr.sv
stage6/kronos_pmp.sv
stage6/kronos_trigger.sv
stage6/kronos_lsu.sv
stage6/kronos_dcache.sv
stage6/kronos_muldiv.sv
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
stage6/fpu/kronos_fpu_top.sv
stage6/kronos_top.sv
