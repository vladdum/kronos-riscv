# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# fpga/gls/synth_ooc.tcl — Out-of-context synthesis of kronos_top for
# gate-level simulation. Emits a Verilog netlist that exposes the AXI
# ports on the boundary, drivable by a SystemVerilog testbench.
#
# Usage:
#   vivado -mode batch -source fpga/gls/synth_ooc.tcl
#     [-tclargs MODE=funcsim|timesim]
#     [-tclargs PULP_AXI_ROOT=/path/to/axi]
#
# Outputs (under build/gls/):
#   MODE=funcsim (default): kronos_top_funcsim.v
#   MODE=timesim          : kronos_top_timesim.v + kronos_top_timesim.sdf

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR ../..]]
set PART       xck26-sfvc784-2LV-c
set TOP        kronos_top
set PROJ_NAME  kronos_top_ooc
set PROJ_DIR   [file normalize [file join $REPO_ROOT build/gls/$PROJ_NAME]]

set MODE          funcsim
set PULP_AXI_ROOT ""
foreach arg $argv {
  if {[regexp {MODE=(\w+)}         $arg -> v]} { set MODE          $v }
  if {[regexp {PULP_AXI_ROOT=(.+)} $arg -> v]} { set PULP_AXI_ROOT $v }
}

# Locate PULP AXI (fallback list)
if {$PULP_AXI_ROOT eq ""} {
  set candidates [list \
    [file join $REPO_ROOT vendor/pulp-platform/axi] \
    [file join $REPO_ROOT fusesoc_libraries/axi] \
    /home/popes/opensoc/hw/ip/pulp_axi \
    /tmp/pulp_axi \
    [file join $env(HOME) .cache/fusesoc/cores/pulp-platform/axi] \
  ]
  foreach c $candidates {
    if {[file isdirectory $c]} { set PULP_AXI_ROOT $c; break }
  }
}
if {$PULP_AXI_ROOT eq "" || ![file isdirectory $PULP_AXI_ROOT]} {
  error "PULP AXI not found. Pass PULP_AXI_ROOT=/path/to/axi as a tclarg."
}
puts "Using PULP AXI: $PULP_AXI_ROOT"
puts "GLS mode      : $MODE"

# Source list — matches files_rtl_s5 in kronos_riscv.core, minus the KV260 wrappers
set RTL_PKG [list $REPO_ROOT/rtl/kronos_pkg.sv]
set RTL_FILES [list \
  $REPO_ROOT/rtl/stage0/kronos_regfile.sv \
  $REPO_ROOT/rtl/stage1/kronos_forward.sv \
  $REPO_ROOT/rtl/stage1/kronos_hazard.sv \
  $REPO_ROOT/rtl/stage3/kronos_align.sv \
  $REPO_ROOT/rtl/stage3/kronos_bpred.sv \
  $REPO_ROOT/rtl/stage5/kronos_alu.sv \
  $REPO_ROOT/rtl/stage5/kronos_decode.sv \
  $REPO_ROOT/rtl/stage5/kronos_regfile_fp.sv \
  $REPO_ROOT/rtl/stage5/kronos_icache.sv \
  $REPO_ROOT/rtl/stage5/kronos_csr.sv \
  $REPO_ROOT/rtl/stage5/kronos_lsu.sv \
  $REPO_ROOT/rtl/stage5/kronos_dcache.sv \
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
]
set AXI_INC_DIRS  [list [file join $PULP_AXI_ROOT include]]
set AXI_PKG_FILES [glob -nocomplain [file join $PULP_AXI_ROOT src axi_pkg.sv]]

create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# Cap synth threads at 8 (Vivado's effective ceiling) to bound peak RAM on
# the 24 GB WSL VM. Without this, default parallelism + global retiming
# pushed peak past 24 GB and got OOM-killed.
set_param general.maxThreads 8

add_files -norecurse $RTL_PKG
set_property file_type SystemVerilog [get_files $RTL_PKG]
if {[llength $AXI_PKG_FILES] > 0} {
  add_files -norecurse $AXI_PKG_FILES
  set_property file_type SystemVerilog [get_files $AXI_PKG_FILES]
}
add_files -norecurse $RTL_FILES
set_property file_type SystemVerilog [get_files $RTL_FILES]
set_property include_dirs $AXI_INC_DIRS [current_fileset]
set_property top $TOP [current_fileset]

puts "=========================================="
puts " Synthesising $TOP (out_of_context, MODE=$MODE)"
puts "=========================================="
set t0 [clock seconds]
synth_design -top $TOP -part $PART -mode out_of_context -directive RuntimeOptimized
set dt [expr {[clock seconds] - $t0}]
puts [format "  Synthesis done in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]

write_checkpoint -force $PROJ_DIR/post_synth.dcp

set GLS_DIR [file join $REPO_ROOT build/gls]
file mkdir $GLS_DIR

if {$MODE eq "funcsim"} {
  set OUT_V [file join $GLS_DIR kronos_top_funcsim.v]
  write_verilog -mode funcsim -force $OUT_V
  puts "  Funcsim netlist: $OUT_V"
} elseif {$MODE eq "timesim"} {
  puts "=========================================="
  puts " Place & Route (for SDF generation)"
  puts "=========================================="
  set t0 [clock seconds]
  opt_design
  place_design
  route_design
  set dt [expr {[clock seconds] - $t0}]
  puts [format "  P&R done in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]
  write_checkpoint -force $PROJ_DIR/post_route.dcp

  set OUT_V   [file join $GLS_DIR kronos_top_timesim.v]
  set OUT_SDF [file join $GLS_DIR kronos_top_timesim.sdf]
  write_verilog -mode timesim -sdf_anno true -force $OUT_V
  write_sdf -force $OUT_SDF
  puts "  Timesim netlist: $OUT_V"
  puts "  SDF annotation : $OUT_SDF"
} else {
  error "Unknown MODE: $MODE (expected funcsim or timesim)."
}

puts "Done."
