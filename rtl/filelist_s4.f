# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 4: RV64IMAC (64-bit + A extension)
# Paths are relative to the kronos-riscv rtl/ directory.

[packages]
kronos_pkg.sv

[rtl]
stage0/kronos_regfile.sv
stage1/kronos_forward.sv
stage1/kronos_hazard.sv
stage3/kronos_align.sv
stage3/kronos_bpred.sv
stage4/kronos_alu.sv
stage4/kronos_decode.sv
stage4/kronos_csr.sv
stage4/kronos_lsu.sv
stage4/kronos_muldiv.sv
stage4/kronos_decompress.sv
stage4/kronos_top.sv
