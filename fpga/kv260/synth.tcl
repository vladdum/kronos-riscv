# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado synthesis + implementation script for kronos on KV260.
#
# Usage (CPU-only, default — no Zynq PS IP, fastest iteration):
#   vivado -mode batch -source fpga/kv260/synth.tcl \
#          -tclargs SYNTH_FREQ_MHZ=200 PULP_AXI_ROOT=/path/to/pulp/axi
#
# Usage (full KV260 wrapper with Zynq PS):
#   vivado -mode batch -source fpga/kv260/synth.tcl \
#          -tclargs SYNTH_FREQ_MHZ=200 PULP_AXI_ROOT=/path TOP=kronos_kv260_top
#
# The script is self-contained: it adds all RTL source files from the repo
# directly, so no FuseSoC setup step is required.

# ============================================================================
# Configuration — derive repo root from this script's location
# ============================================================================
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set REPO_ROOT   [file normalize [file join $SCRIPT_DIR ../..]]

set PART      xck26-sfvc784-2LV-c
# Default: CPU-only wrapper (no Zynq PS, faster iteration)
set TOP       kronos_cpu_synth_top
set PROJ_NAME kronos_kv260

# Clock frequency — override via: -tclargs SYNTH_FREQ_MHZ=180
set SYNTH_FREQ_MHZ 200
# PULP AXI root — override via: -tclargs PULP_AXI_ROOT=/path
set PULP_AXI_ROOT ""

foreach arg $argv {
  if {[regexp {SYNTH_FREQ_MHZ=(\d+)} $arg -> val]} { set SYNTH_FREQ_MHZ $val }
  if {[regexp {PULP_AXI_ROOT=(.+)}   $arg -> val]} { set PULP_AXI_ROOT $val }
  if {[regexp {TOP=(.+)}             $arg -> val]} { set TOP $val }
}

# Output directory per frequency so runs don't overwrite each other
set PROJ_DIR [file normalize [file join $REPO_ROOT build/vivado_kv260_${SYNTH_FREQ_MHZ}]]

# Locate PULP AXI if not specified
if {$PULP_AXI_ROOT eq ""} {
  set candidates [list \
    [file join $REPO_ROOT vendor/pulp-platform/axi] \
    /home/popes/opensoc/hw/ip/pulp_axi \
    /tmp/pulp_axi \
    ~/.cache/fusesoc/cores/pulp-platform/axi \
  ]
  foreach c $candidates {
    if {[file isdirectory $c]} { set PULP_AXI_ROOT $c; break }
  }
}
if {$PULP_AXI_ROOT eq "" || ![file isdirectory $PULP_AXI_ROOT]} {
  error "PULP AXI not found. Pass PULP_AXI_ROOT=/path/to/axi as a tclarg."
}
puts "Using PULP AXI: $PULP_AXI_ROOT"
puts "Top module    : $TOP"

set CLK_PERIOD [expr {1000.0 / $SYNTH_FREQ_MHZ}]

# ============================================================================
# Helper: extract WNS from timing summary
# ============================================================================
proc get_wns {} {
  set path [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
  if {$path eq ""} { return "N/A" }
  return [get_property SLACK $path]
}

# ============================================================================
# Create project
# ============================================================================
create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language Verilog [current_project]

# ============================================================================
# Zynq PS IP — only needed when TOP=kronos_kv260_top
# ============================================================================
if {$TOP eq "kronos_kv260_top"} {
  set ps_vlnv [lindex [get_ipdefs -filter "NAME == zynq_ultra_ps_e"] 0]
  if {$ps_vlnv eq ""} {
    error "zynq_ultra_ps_e IP not found — check Vivado board support package installation."
  }
  create_ip -vlnv $ps_vlnv -module_name zynq_ultra_ps_e_0
  set_property -dict {
    CONFIG.PSU__FPGA_PL0_ENABLE  {1}
    CONFIG.PSU__USE__M_AXI_GP0   {0}
    CONFIG.PSU__USE__M_AXI_GP1   {0}
    CONFIG.PSU__USE__M_AXI_GP2   {0}
    CONFIG.PSU__USE__S_AXI_GP0   {0}
    CONFIG.PSU__USE__S_AXI_GP1   {0}
    CONFIG.PSU__USE__S_AXI_GP2   {0}
    CONFIG.PSU__USE__S_AXI_GP3   {0}
  } [get_ips zynq_ultra_ps_e_0]
  set_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $SYNTH_FREQ_MHZ \
    [get_ips zynq_ultra_ps_e_0]
  generate_target {all} [get_ips zynq_ultra_ps_e_0]
  set_property SYNTH_CHECKPOINT_MODE None [get_files zynq_ultra_ps_e_0.xci]
}

# ============================================================================
# Source files — RTL from files_rtl_s5 (matches kronos_riscv.core)
# ============================================================================
set RTL_PKG [list \
  $REPO_ROOT/rtl/kronos_pkg.sv \
]

set RTL_FILES [list \
  $REPO_ROOT/rtl/stage0/kronos_regfile.sv \
  $REPO_ROOT/rtl/stage1/kronos_forward.sv \
  $REPO_ROOT/rtl/stage1/kronos_hazard.sv \
  $REPO_ROOT/rtl/stage3/kronos_align.sv \
  $REPO_ROOT/rtl/stage3/kronos_bpred.sv \
  $REPO_ROOT/rtl/stage5/kronos_alu.sv \
  $REPO_ROOT/rtl/stage5/kronos_decode.sv \
  $REPO_ROOT/rtl/stage5/kronos_regfile_fp.sv \
  $REPO_ROOT/rtl/stage5/kronos_csr.sv \
  $REPO_ROOT/rtl/stage5/kronos_lsu.sv \
  $REPO_ROOT/rtl/stage5/kronos_muldiv.sv \
  $REPO_ROOT/rtl/stage5/kronos_decompress.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_scoreboard.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fmisc.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fcvt.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fadd.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fmul.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fma.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fdiv_core.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_fsqrt_core.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_iter.sv \
  $REPO_ROOT/rtl/stage5/fpu/kronos_fpu_top.sv \
  $REPO_ROOT/rtl/stage5/kronos_top.sv \
  $REPO_ROOT/fpga/kv260/kronos_cpu_synth_top.sv \
  $REPO_ROOT/fpga/kv260/kronos_kv260_top.sv \
]

# PULP AXI include dirs and package
set AXI_INC_DIRS [list \
  [file join $PULP_AXI_ROOT include] \
]
set AXI_PKG_FILES [glob -nocomplain [file join $PULP_AXI_ROOT src axi_pkg.sv]]

# Add package (order-sensitive: pkg before RTL)
add_files -norecurse $RTL_PKG
set_property file_type SystemVerilog [get_files $RTL_PKG]

if {[llength $AXI_PKG_FILES] > 0} {
  add_files -norecurse $AXI_PKG_FILES
  set_property file_type SystemVerilog [get_files $AXI_PKG_FILES]
}

# Add RTL
add_files -norecurse $RTL_FILES
set_property file_type SystemVerilog [get_files $RTL_FILES]

# Set include directories (PULP AXI macro headers)
set_property include_dirs $AXI_INC_DIRS [current_fileset]

# ============================================================================
# Constraints
# ============================================================================
# Board-level constraints (I/O standards, config voltage) — skip for CPU-only
if {$TOP eq "kronos_kv260_top"} {
  set XDC_FILE [file join $REPO_ROOT fpga/kv260/kronos_kv260.xdc]
  add_files -fileset constrs_1 -norecurse $XDC_FILE
}

# Multicycle path constraints
set MCP_XDC [file join $REPO_ROOT rtl/stage5/kronos_kv260.xdc]
add_files -fileset constrs_1 -norecurse $MCP_XDC

# Synthesis-only directives (MAX_FANOUT on high-fan-out pipeline-control nets).
# Must be processed EARLY — before synth_design flattens the combinational cone
# — and only during synthesis, never during implementation.
set SYNTH_XDC [file join $REPO_ROOT fpga/kv260/synth_directives.xdc]
add_files -fileset constrs_1 -norecurse $SYNTH_XDC
set_property USED_IN_SYNTHESIS      true  [get_files $SYNTH_XDC]
set_property USED_IN_IMPLEMENTATION false [get_files $SYNTH_XDC]
set_property PROCESSING_ORDER       EARLY [get_files $SYNTH_XDC]

# Clock constraint — generated from SYNTH_FREQ_MHZ so no manual XDC edit needed
file mkdir $PROJ_DIR
set CLK_XDC [file join $PROJ_DIR clk.xdc]
set fd [open $CLK_XDC w]
if {$TOP eq "kronos_cpu_synth_top"} {
  # CPU-only: clock on BUFG output inside the wrapper
  puts $fd "create_clock -period $CLK_PERIOD -name clk_i \[get_pins clk_buf_i/O\]"
} else {
  puts $fd "create_clock -period $CLK_PERIOD -name clk_i \[get_pins clk_buf_i/O\]"
}
close $fd
add_files -fileset constrs_1 -norecurse $CLK_XDC

set_property top $TOP [current_fileset]

# ============================================================================
# Synthesis
# ============================================================================
puts "=========================================="
puts " Synthesising $TOP at ${SYNTH_FREQ_MHZ} MHz (${CLK_PERIOD} ns)"
puts "=========================================="
set t0 [clock seconds]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
synth_design -top $TOP -part $PART -global_retiming on
set dt [expr {[clock seconds] - $t0}]
puts [format "  Synthesis done in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]

write_checkpoint  -force $PROJ_DIR/post_synth.dcp
report_utilization   -file $PROJ_DIR/post_synth_utilization.txt
report_timing_summary -file $PROJ_DIR/post_synth_timing.txt
puts "  Post-synthesis WNS (estimated): [get_wns] ns"

# ============================================================================
# Implementation
# ============================================================================
puts "=========================================="
puts " Place & Route"
puts "=========================================="
set t0 [clock seconds]
opt_design
place_design
phys_opt_design -directive AggressiveExplore
route_design    -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
set dt [expr {[clock seconds] - $t0}]
puts [format "  Place & route done in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]

write_checkpoint  -force $PROJ_DIR/post_route.dcp
report_utilization   -file $PROJ_DIR/post_route_utilization.txt
report_timing_summary -file $PROJ_DIR/post_route_timing.txt

# ============================================================================
# Timing closure summary
# ============================================================================
set wns [get_wns]
puts ""
if {$wns ne "N/A"} {
  set fmax [format "%.1f" [expr {1000.0 / ($CLK_PERIOD - $wns)}]]
  if {$wns < 0} {
    puts "WARNING: Timing NOT met — WNS = ${wns} ns  (Fmax \u2248 ${fmax} MHz)"
  } else {
    puts "Timing met — WNS = ${wns} ns  (Fmax \u2265 ${fmax} MHz)"
  }
}
puts "Reports:"
puts "  $PROJ_DIR/post_route_utilization.txt"
puts "  $PROJ_DIR/post_route_timing.txt"
