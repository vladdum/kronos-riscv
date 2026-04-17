# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 2: RV32IM (M extension + CSR hardening)
# Paths are relative to the kronos-riscv rtl/ directory.

[packages]
kronos_pkg.sv

[rtl]
stage0/kronos_alu.sv
stage0/kronos_regfile.sv
stage0/kronos_csr.sv
stage1/kronos_lsu.sv
stage1/kronos_forward.sv
stage1/kronos_hazard.sv
stage2/kronos_decode.sv
stage2/kronos_muldiv.sv
stage2/kronos_top.sv
