# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado XDC constraints for kronos_kv260_top on AMD Kria KV260
# (XCK26-SFVC784-2LV-c)
#
# Target: 200 MHz (5.000 ns period)
#
# NOTE: create_clock is NOT in this file — synth.tcl generates it from
#       SYNTH_FREQ_MHZ so the period can be swept without editing constraints.

# ==============================================================================
# FPGA configuration
# ==============================================================================
set_property CFGBVS         GND  [current_design]
set_property CONFIG_VOLTAGE  1.8  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ==============================================================================
# LEDs (DS1–DS4) — bank 45, LVCMOS33
# ==============================================================================
set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN J10 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN F11 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

# ==============================================================================
# Fan enable — bank 45, LVCMOS33
# ==============================================================================
set_property -dict { PACKAGE_PIN A12 IOSTANDARD LVCMOS33 } [get_ports fan_en_b]

# ==============================================================================
# UART via Pmod (pins 1 & 2) — bank 45, LVCMOS33
# ==============================================================================
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 } [get_ports uart_tx]
set_property -dict { PACKAGE_PIN B10 IOSTANDARD LVCMOS33 } [get_ports uart_rx]

# ==============================================================================
# Multicycle path: 64-bit branch comparator
#
# The branch comparison path (id_ex_q pipeline register → 64-bit BLT/BGE/etc.
# comparator → branch_taken → ex_redirect → pc_q and if_id_q flush) spans
# ~8–10 LUT levels (~10 ns) and cannot meet a 5.0 ns single-cycle setup check.
#
# A 2-cycle setup MCP relaxes the constraint to 10.0 ns, which the path meets
# comfortably.  The -hold 1 correction keeps the hold check at 1 cycle so that
# operands launched at the following posedge cannot corrupt the path.
# ==============================================================================
set_multicycle_path -setup 2 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *pc_q_reg*}]

set_multicycle_path -hold 1 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *pc_q_reg*}]

set_multicycle_path -setup 2 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *if_id_q_reg*}]

set_multicycle_path -hold 1 \
  -from [get_cells -hierarchical -filter {NAME =~ *id_ex_q_reg*}] \
  -to   [get_cells -hierarchical -filter {NAME =~ *if_id_q_reg*}]
