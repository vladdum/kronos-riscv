# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# fpga/gls/run_xsim.tcl — xsim batch runner for gate-level simulation.
#
# Usage:
#   vivado -mode batch -source fpga/gls/run_xsim.tcl
#     -tclargs HEX=<path> MODE=funcsim|timesim TEST=<name>
#     [-tclargs INSTR_LAT=<n>] [-tclargs DATA_LAT=<n>]
#     [-tclargs MAX_CYCLES=<n>] [-tclargs VCD=<path>]

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR ../..]]
set GLS_DIR    [file join $REPO_ROOT build/gls]

set HEX        ""
set MODE       funcsim
set TEST       unknown
set INSTR_LAT  1
set DATA_LAT   1
set MAX_CYCLES 5000000
set VCD        ""
foreach arg $argv {
  if {[regexp {HEX=(.+)}         $arg -> v]} { set HEX        $v }
  if {[regexp {MODE=(\w+)}       $arg -> v]} { set MODE       $v }
  if {[regexp {TEST=(.+)}        $arg -> v]} { set TEST       $v }
  if {[regexp {INSTR_LAT=(\d+)}  $arg -> v]} { set INSTR_LAT  $v }
  if {[regexp {DATA_LAT=(\d+)}   $arg -> v]} { set DATA_LAT   $v }
  if {[regexp {MAX_CYCLES=(\d+)} $arg -> v]} { set MAX_CYCLES $v }
  if {[regexp {VCD=(.+)}         $arg -> v]} { set VCD        $v }
}
if {$HEX eq ""} { error "HEX=<path> required" }

# Resolve HEX to absolute (HEX may be passed relative to REPO_ROOT)
if {[file pathtype $HEX] eq "relative"} {
  set HEX [file join $REPO_ROOT $HEX]
}

set NETLIST_FUNCSIM [file join $GLS_DIR kronos_top_funcsim.v]
set NETLIST_TIMESIM [file join $GLS_DIR kronos_top_timesim.v]
set SDF             [file join $GLS_DIR kronos_top_timesim.sdf]
set TB_TOP          [file join $REPO_ROOT tb/gls/tb_gls_top.sv]
set MEM_MODEL       [file join $REPO_ROOT tb/gls/axi_mem_model.sv]

set LOG_DIR [file join $GLS_DIR logs]
file mkdir $LOG_DIR
set LOG_PATH [file join $LOG_DIR ${TEST}.${MODE}.log]
set XSIM_DIR [file join $GLS_DIR xsim]
file mkdir $XSIM_DIR

# Vivado ships glbl.v with the install — locate via $env(XILINX_VIVADO).
set GLBL_V [file join $env(XILINX_VIVADO) data verilog src glbl.v]
if {![file exists $GLBL_V]} {
  error "glbl.v not found at $GLBL_V — is XILINX_VIVADO set?"
}

# ── Pick netlist for the requested mode ──────────────────────────────────
if {$MODE eq "funcsim"} {
  set NETLIST $NETLIST_FUNCSIM
} elseif {$MODE eq "timesim"} {
  set NETLIST $NETLIST_TIMESIM
} else {
  error "Unknown MODE: $MODE"
}
if {![file exists $NETLIST]} {
  error "Netlist missing: $NETLIST  (run synth_ooc.tcl with MODE=$MODE first)"
}

cd $XSIM_DIR

# ── Snapshot caching ────────────────────────────────────────────────────
# xelab on the 9.9M-line netlist takes ~15 min. Skip xvlog+xelab when the
# existing snapshot is newer than every input source — net ≥10× speedup
# across the 8-test smoke set.
set SNAP_DIR  [file join $XSIM_DIR xsim.dir tb_snap]
set SNAP_MARK [file join $SNAP_DIR xsim.dbg]
set sources   [list $NETLIST $GLBL_V $MEM_MODEL $TB_TOP]
if {$MODE eq "timesim"} { lappend sources $SDF }
set snap_fresh 0
if {[file exists $SNAP_MARK]} {
  set snap_mtime [file mtime $SNAP_MARK]
  set snap_fresh 1
  foreach s $sources {
    if {[file mtime $s] > $snap_mtime} { set snap_fresh 0; break }
  }
}

if {$snap_fresh} {
  puts "\[GLS\] reusing cached snapshot tb_snap"
} else {
  # ── xvlog: compile sources ────────────────────────────────────────────
  puts "\[GLS\] xvlog ($MODE)"
  exec xvlog -nolog $NETLIST     >&@ stdout
  exec xvlog -nolog $GLBL_V      >&@ stdout
  exec xvlog -nolog -sv $MEM_MODEL $TB_TOP >&@ stdout

  # ── xelab: elaborate ──────────────────────────────────────────────────
  puts "\[GLS\] xelab"
  set XELAB_ARGS [list -nolog -L unisims_ver -L secureip \
                       -timescale 1ns/1ps \
                       tb_gls_top glbl -s tb_snap]
  if {$MODE eq "timesim"} {
    if {![file exists $SDF]} { error "SDF missing: $SDF" }
    lappend XELAB_ARGS -sdftyp /tb_gls_top/dut=$SDF -transport_int_delays
  }
  exec {*}[concat xelab $XELAB_ARGS] >&@ stdout
}

# ── xsim: simulate ──────────────────────────────────────────────────────
puts "\[GLS\] xsim — log: $LOG_PATH"
# xsim's --testplusarg takes ONE name=value (no leading '+') per flag —
# repeat for each plusarg.
set XSIM_PLUS [list HEX=$HEX MAX_CYCLES=$MAX_CYCLES \
                    INSTR_LAT=$INSTR_LAT DATA_LAT=$DATA_LAT \
                    TEST=$TEST]
if {$VCD ne ""} { lappend XSIM_PLUS VCD=$VCD }
set XSIM_ARGS [list xsim tb_snap --runall --onerror quit -nolog]
foreach pa $XSIM_PLUS { lappend XSIM_ARGS --testplusarg $pa }
set fd [open $LOG_PATH w]
set rc [catch {exec {*}$XSIM_ARGS >&@ $fd} err]
close $fd
if {$rc != 0} {
  puts "\[GLS\] FAIL — see $LOG_PATH"
  exit 1
}
# xsim doesn't propagate $finish(1) as a non-zero exit code reliably —
# scrape the log for [GLS] FAIL / TIMEOUT / X-PROP.
set fd [open $LOG_PATH r]
set log [read $fd]; close $fd
if {[regexp {\[GLS\] (FAIL|TIMEOUT|X-PROP)} $log]} {
  puts "\[GLS\] FAIL — see $LOG_PATH"
  exit 1
}
if {![regexp {\[GLS\] PASS} $log]} {
  puts "\[GLS\] INCONCLUSIVE (no PASS line) — see $LOG_PATH"
  exit 1
}
puts "\[GLS\] PASS — $TEST ($MODE)"
exit 0
