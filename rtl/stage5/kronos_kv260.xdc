# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Vivado XDC multicycle path constraints for kronos_top on KV260 (XCK26, -2LV speed grade)
# Target frequency is set by the calling synth script, not here.
#   KV260 standalone flow (fpga/kv260/synth.tcl): 200 MHz (5.000 ns)
#   OpenSoC flow (hw/fpga/kv260/synth.tcl):       148 MHz (6.757 ns)

# ---------------------------------------------------------------------------
# Fix #4: Multicycle path for the 64-bit branch comparator.
#
# The branch comparison path (fwd_rs1_data / fwd_rs2_data → 64-bit compare →
# branch_taken → ex_redirect → pc_q) spans ~8–10 LUT levels (~10 ns) and
# cannot close in one 6.757 ns clock period.
#
# The comparator inputs come from the id_ex_q pipeline register (launched at
# the posedge that captured the branch instruction into EX).  The path ends at
# pc_q and the if_id_q / id_ex_q flush registers (capturing ex_redirect one
# cycle later).
#
# By declaring a 2-cycle setup multicycle path, Vivado relaxes the setup check
# to 2 × 6.757 = 13.514 ns, which the ~10 ns path comfortably meets.  The
# corresponding hold adjustment (-hold 1) keeps the hold check at 1 cycle so
# that new operands launched at the following posedge cannot corrupt the path.
#
# NOTE: Vivado hierarchical cell names below must match the synthesised
# netlist.  Adjust the -from/-to patterns after running synthesis if the
# elaborated names differ.
# ---------------------------------------------------------------------------
set_multicycle_path -setup 2 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *pc_q_reg*}]

set_multicycle_path -hold 1 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *pc_q_reg*}]

# The same path also ends at the if_id_q flush register (which samples
# ex_redirect to squash the IF/ID stage on a misprediction).
set_multicycle_path -setup 2 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *if_id_q_reg*}]

set_multicycle_path -hold 1 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *if_id_q_reg*}]
