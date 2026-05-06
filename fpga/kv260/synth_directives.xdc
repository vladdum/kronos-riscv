# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Synthesis-only directives for kronos_top on KV260.
#
# Loaded with USED_IN_SYNTHESIS=true / USED_IN_IMPLEMENTATION=false and
# PROCESSING_ORDER=EARLY so these properties are applied on the elaborated
# RTL netlist before synth_design flattens the combinational cone (which is
# why the same constraint placed in a regular impl XDC fails to match).

# High fan-out pipeline-control nets: force driver replication so no single
# copy drives more than 32 loads.  ex_redirect/mem_redirect each reach the
# hazard unit, muldiv gating, pc_next mux, align flush, fetch-stale tracker
# and every id_ex/if_id flush bit (~110 sinks without replication).
# Stage 7 renamed the live ex_redirect / mem_redirect nets to registered
# `_q` outputs as part of the EX1/EX2/MEM1/MEM2 split.  Match the new
# names; the fence_i_redirect_q net was added in 7a and shares the same
# fan-out pattern (hazard unit, muldiv gating, pc_next mux, FB flush).
set_property MAX_FANOUT 32 [get_nets -hierarchical -filter {NAME =~ */ex_redirect_q}]
set_property MAX_FANOUT 32 [get_nets -hierarchical -filter {NAME =~ */mem_redirect_q}]
set_property MAX_FANOUT 32 [get_nets -hierarchical -filter {NAME =~ */fence_i_redirect_q}]

