# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# fpga/gls/synth_ooc.tcl — Out-of-context synthesis of kronos_top for
# gate-level simulation. Emits a Verilog netlist that exposes the AXI
# ports on the boundary, drivable by a SystemVerilog testbench.
#
# The source list is read from rtl/filelist_s<N>.f so this script
# tracks per-stage RTL drift automatically.
#
# Usage:
#   vivado -mode batch -source fpga/gls/synth_ooc.tcl
#     [-tclargs STAGE=s5|s6]                (default s5)
#     [-tclargs MODE=funcsim|timesim]       (default funcsim)
#     [-tclargs PULP_AXI_ROOT=/path/to/axi]
#
# Outputs (under build/gls/):
#   MODE=funcsim: kronos_top_<STAGE>_funcsim.v
#   MODE=timesim: kronos_top_<STAGE>_timesim.v + kronos_top_<STAGE>_timesim.sdf

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR ../..]]
set PART       xck26-sfvc784-2LV-c
set TOP        kronos_top

set MODE          funcsim
set STAGE         s5
set PULP_AXI_ROOT ""
foreach arg $argv {
  if {[regexp {MODE=(\w+)}         $arg -> v]} { set MODE          $v }
  if {[regexp {STAGE=(\w+)}        $arg -> v]} { set STAGE         $v }
  if {[regexp {PULP_AXI_ROOT=(.+)} $arg -> v]} { set PULP_AXI_ROOT $v }
}
if {![regexp {^s[0-9]+[a-z]?$} $STAGE]} {
  error "Invalid STAGE=$STAGE (expected s5, s6, ...)"
}

set PROJ_NAME kronos_top_ooc_$STAGE
set PROJ_DIR  [file normalize [file join $REPO_ROOT build/gls/$PROJ_NAME]]

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
puts "GLS stage     : $STAGE"

# Source list comes from rtl/filelist_s<N>.f (the same source-of-truth used
# by sim/Makefile and kronos_riscv.core), so per-stage RTL drift is picked
# up automatically. The filelist puts kronos_pkg.sv first; we keep it
# separate from the rest because Vivado processes packages before modules
# regardless of order, but the file_type still needs to be SystemVerilog.
set FILELIST [file join $REPO_ROOT rtl filelist_$STAGE.f]
if {![file exists $FILELIST]} {
  error "Filelist missing: $FILELIST"
}
set fd [open $FILELIST r]
set raw [split [read $fd] "\n"]
close $fd

set RTL_PKG   [list]
set RTL_FILES [list]
foreach line $raw {
  set line [string trim $line]
  if {$line eq "" || [string index $line 0] eq "#"} { continue }
  set abs [file normalize [file join $REPO_ROOT rtl $line]]
  if {[string match "*/kronos_pkg.sv" $abs]} {
    lappend RTL_PKG $abs
  } else {
    lappend RTL_FILES $abs
  }
}
if {[llength $RTL_PKG] == 0} {
  error "kronos_pkg.sv not found in $FILELIST"
}
puts "Source files  : [llength $RTL_PKG] pkg + [llength $RTL_FILES] modules"

set AXI_INC_DIRS  [list [file join $PULP_AXI_ROOT include]]
set AXI_PKG_FILES [glob -nocomplain [file join $PULP_AXI_ROOT src axi_pkg.sv]]

create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# Cap synth threads at 8 (Vivado's effective ceiling) to bound peak RAM on
# the 24 GB WSL VM. Without this, default parallelism + global retiming
# pushed peak past 24 GB and got OOM-killed.
set_param general.maxThreads 8

# ── Message-severity tuning ────────────────────────────────────────────
# Demote informational-but-noisy warnings so the synth log only flags what
# matters. Each entry below is benign for this design — see the comment.
#
# 8-11067: parameter-as-localparam in third-party pulp_axi/src/axi_pkg.sv.
#          Source not ours to fix.
# 8-11357: 3D-RAM/struct array implemented as registers. We *want* registers
#          for the small caches; FPGA inference is correct.
# 8-3917 : retire_pc_o[63:32] driven by constant 0. PC is 32-bit on stage5/6
#          but the retire port stays 64-bit for sim/tb compatibility — the
#          synthesizer correctly constant-folds the upper half.
# 8-3936 : trimmed-bits on a register where the high bits feed only branches
#          that get pruned later (kronos_fpu_fmul mant_rnd). Behavior is OK.
# 8-3332 : synth-pruned dead bits of s3_product in fpu_fma — synth is doing
#          its job.
# 8-6014 : synth-pruned dead local block-vars inside always_ff. SystemVerilog
#          scoped temporaries that Vivado naively models as FFs and then
#          eliminates. Adding `automatic` keyword everywhere is mechanical
#          but invasive; demote until that cleanup pass.
foreach msgid { 8-11067 8-11357 8-3917 8-3936 8-3332 8-6014 } {
  set_msg_config -id "Synth $msgid" -new_severity INFO
}

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
  set OUT_V        [file join $GLS_DIR kronos_top_${STAGE}_funcsim.v]
  set OUT_V_LEGACY [file join $GLS_DIR kronos_top_funcsim.v]
  write_verilog -mode funcsim -force $OUT_V
  # Stage5 keeps a stage-less alias for backward compatibility with run_xsim.tcl
  if {$STAGE eq "s5"} {
    file copy -force $OUT_V $OUT_V_LEGACY
  }
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

  set OUT_V          [file join $GLS_DIR kronos_top_${STAGE}_timesim.v]
  set OUT_SDF        [file join $GLS_DIR kronos_top_${STAGE}_timesim.sdf]
  set OUT_V_LEGACY   [file join $GLS_DIR kronos_top_timesim.v]
  set OUT_SDF_LEGACY [file join $GLS_DIR kronos_top_timesim.sdf]
  write_verilog -mode timesim -sdf_anno true -force $OUT_V
  write_sdf -force $OUT_SDF
  if {$STAGE eq "s5"} {
    file copy -force $OUT_V $OUT_V_LEGACY
    file copy -force $OUT_SDF $OUT_SDF_LEGACY
  }
  puts "  Timesim netlist: $OUT_V"
  puts "  SDF annotation : $OUT_SDF"
} else {
  error "Unknown MODE: $MODE (expected funcsim or timesim)."
}

puts "Done."
