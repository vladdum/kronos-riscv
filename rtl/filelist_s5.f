# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 5: RV64IMAFD (F/D extensions + FPU)
# Paths are relative to this file's directory (rtl/).

kronos_pkg.sv
common/kronos_ram.sv
stage0/kronos_regfile.sv
stage1/kronos_forward.sv
stage1/kronos_hazard.sv
common/kronos_predecode.sv
common/kronos_fetch_buffer.sv
common/kronos_bpred.sv
common/kronos_alu.sv
stage5/kronos_decode.sv
common/kronos_regfile_fp.sv
stage5/kronos_icache.sv
stage5/kronos_csr.sv
common/kronos_trigger.sv
stage5/kronos_lsu.sv
stage5/kronos_dcache.sv
common/kronos_muldiv.sv
common/kronos_decompress.sv
common/fpu/kronos_fpu_scoreboard.sv
common/fpu/kronos_fpu_fmisc.sv
common/fpu/kronos_fpu_fcvt.sv
common/fpu/kronos_fpu_fadd.sv
common/fpu/kronos_fpu_fmul.sv
common/fpu/kronos_fpu_fma.sv
common/fpu/kronos_fpu_fdiv_core.sv
common/fpu/kronos_fpu_fsqrt_core.sv
common/fpu/kronos_fpu_iter.sv
common/fpu/kronos_fpu_top.sv
stage5/kronos_top.sv
