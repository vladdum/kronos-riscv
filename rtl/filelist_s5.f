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
stage3/kronos_align.sv
common/kronos_bpred.sv
stage5/kronos_alu.sv
stage5/kronos_decode.sv
stage5/kronos_regfile_fp.sv
stage5/kronos_icache.sv
stage5/kronos_csr.sv
stage5/kronos_trigger.sv
stage5/kronos_lsu.sv
stage5/kronos_dcache.sv
stage5/kronos_muldiv.sv
stage5/kronos_decompress.sv
stage5/fpu/kronos_fpu_scoreboard.sv
stage5/fpu/kronos_fpu_fmisc.sv
stage5/fpu/kronos_fpu_fcvt.sv
stage5/fpu/kronos_fpu_fadd.sv
stage5/fpu/kronos_fpu_fmul.sv
stage5/fpu/kronos_fpu_fma.sv
stage5/fpu/kronos_fpu_fdiv_core.sv
stage5/fpu/kronos_fpu_fsqrt_core.sv
stage5/fpu/kronos_fpu_iter.sv
stage5/fpu/kronos_fpu_top.sv
stage5/kronos_top.sv
