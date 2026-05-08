# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 7e Pblock — compact u_core into a contiguous CLOCK_REGION subset on
# xck26.  Targets the route component on the post-7d-closeout worst path
# (ex2_mem1_q.alu_result -> u_dtlb -> u_ptw -> u_dcache -> bypass mux ->
# rr_ex1_q.D, ~5 ns route).  See:
#   docs/superpowers/specs/2026-05-06-stage7d-closeout-design.md  Section 4
#
# Impl-only (USED_IN_SYNTHESIS=false in synth.tcl).

create_pblock pblock_core
add_cells_to_pblock [get_pblocks pblock_core] [get_cells u_core]
resize_pblock [get_pblocks pblock_core] -add { CLOCKREGION_X0Y0:CLOCKREGION_X1Y2 }
set_property IS_SOFT             FALSE [get_pblocks pblock_core]
set_property EXCLUDE_PLACEMENT   TRUE  [get_pblocks pblock_core]
