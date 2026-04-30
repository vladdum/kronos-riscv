// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_lsu.sv — thin adapter between the EX-stage pipeline
// interface and kronos_dcache.  All AXI master logic, AMO RMW arithmetic,
// and LR/SC reservation tracking have moved into kronos_dcache.
//
// Responsibilities:
//   1. Translate the EX-stage request into the cache's interface signals.
//   2. Decode funct3 → dcache size encoding (LB=0, LH=1, LW/LWU=2, LD=3).
//   3. Sign-extend cache load data based on funct3 (dcache returns
//      zero-extended data for all sub-doubleword loads).
//   4. Route FP load results with NaN-boxing.
//   5. Drive pipeline stall/valid from cache outputs.
//
// Note: funct3_i and fp_dest_req_i are taken combinatorially.  The pipeline
// ensures they are stable for the entire duration of a memory transaction
// because the pipeline is stalled (mem_stall_o=1) until dcache signals
// data_valid_o.  Using registered copies would introduce a one-cycle lag
// that breaks cache-hit sign extension.
module kronos_lsu
  import kronos_pkg::*;
(
  input  logic             clk_i,
  input  logic             rst_ni,

  // Pipeline interface (64-bit data)
  input  logic             req_i,
  input  logic             we_i,
  input  logic [31:0]      addr_i,
  input  logic [63:0]      wdata_i,
  input  logic [2:0]       funct3_i,
  output logic [63:0]      rdata_o,
  output logic             valid_o,
  output logic             mem_stall_o,

  // FP load/store extensions
  input  logic             fp_dest_req_i,    // this is a FP load/store
  input  logic [63:0]      fp_store_data_i,  // FP register data for FSW/FSD
  output logic             fp_dest_rsp_o,    // load response targets FP regfile
  output logic [63:0]      fp_rdata_o,       // NaN-boxed FP load data

  // A-extension
  input  logic             is_lr_i,
  input  logic             is_sc_i,
  input  logic             is_amo_i,
  input  logic [4:0]       amo_funct5_i,
  input  logic [63:0]      amo_src_i,
  output logic             sc_success_o,

  // D-cache interface (replaces direct AXI master)
  output logic             dcache_req_o,
  output logic [63:0]      dcache_addr_o,
  output logic [2:0]       dcache_size_o,
  output logic             dcache_we_o,
  output logic [63:0]      dcache_wdata_o,
  output logic             dcache_amo_req_o,
  output logic [4:0]       dcache_amo_op_o,
  input  logic             dcache_data_valid_i,
  input  logic [63:0]      dcache_rdata_i,
  input  logic             dcache_sc_success_i,
  input  logic             dcache_stall_i
);

  // -------------------------------------------------------------------------
  // 4. Combinational signals
  // -------------------------------------------------------------------------
  // Suppress unused-input warning for ports consumed by dcache directly.
  logic _unused;

  // -------------------------------------------------------------------------
  // funct3 → dcache size encoding: 0=byte, 1=halfword, 2=word, 3=double.
  // Unsigned variants (LBU/LHU/LWU) use the same size as their signed
  // counterparts; the difference is applied in the sign-extension mux below.
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (funct3_i)
      3'b000: dcache_size_o = 3'd0;     // LB  / SB
      3'b001: dcache_size_o = 3'd1;     // LH  / SH
      3'b010: dcache_size_o = 3'd2;     // LW  / SW
      3'b011: dcache_size_o = 3'd3;     // LD  / SD
      3'b100: dcache_size_o = 3'd0;     // LBU
      3'b101: dcache_size_o = 3'd1;     // LHU
      3'b110: dcache_size_o = 3'd2;     // LWU
      default: dcache_size_o = 3'd3;
    endcase
  end

  // -------------------------------------------------------------------------
  // Cache-side request translation.
  // For FP stores the write data comes from the FP register file path.
  // amo_req_o covers LR, SC, and all AMO instructions.
  // -------------------------------------------------------------------------
  assign dcache_req_o     = req_i;
  assign dcache_addr_o    = {32'b0, addr_i};
  assign dcache_we_o      = we_i;
  assign dcache_wdata_o   = fp_dest_req_i ? fp_store_data_i : wdata_i;
  assign dcache_amo_req_o = is_lr_i | is_sc_i | is_amo_i;
  assign dcache_amo_op_o  = amo_funct5_i;

  // -------------------------------------------------------------------------
  // Sign-extension on load result.
  // dcache returns zero-extended data for byte/halfword/word accesses.
  // The LSU applies the signed/unsigned selection based on funct3_i.
  //
  // SC is a special case: the destination register receives 0 on success,
  // 1 on failure.  dcache signals success via sc_success_o; there is no
  // meaningful load data for SC.
  // -------------------------------------------------------------------------
  always_comb begin
    if (is_sc_i) begin
      // SC result: 0 = success, 1 = failure
      rdata_o = {63'b0, ~dcache_sc_success_i};
    end else begin
      unique case (funct3_i)
        3'b000: rdata_o = {{56{dcache_rdata_i[7]}},  dcache_rdata_i[7:0]};   // LB
        3'b001: rdata_o = {{48{dcache_rdata_i[15]}}, dcache_rdata_i[15:0]};  // LH
        3'b010: rdata_o = {{32{dcache_rdata_i[31]}}, dcache_rdata_i[31:0]};  // LW
        3'b011: rdata_o = dcache_rdata_i;                                    // LD
        3'b100: rdata_o = {56'b0, dcache_rdata_i[7:0]};                      // LBU
        3'b101: rdata_o = {48'b0, dcache_rdata_i[15:0]};                     // LHU
        3'b110: rdata_o = {32'b0, dcache_rdata_i[31:0]};                     // LWU
        default: rdata_o = dcache_rdata_i;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // FP load routing.
  // fp_rdata_o carries NaN-boxed data for FLW (funct3=010) or the full
  // 64-bit word for FLD (funct3=011).
  // fp_dest_rsp_o fires alongside valid_o for FP loads; the top-level
  // pipeline routes the result to the FP register file.
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (funct3_i)
      3'b010: fp_rdata_o = {kronos_pkg::FP_NANBOX_UPPER, dcache_rdata_i[31:0]};  // FLW: NaN-box
      3'b011: fp_rdata_o = dcache_rdata_i;                           // FLD: full 64-bit
      default: fp_rdata_o = {64{1'b0}};
    endcase
  end

  // Only FP loads produce an FP writeback; FP stores have no FP destination.
  assign fp_dest_rsp_o = dcache_data_valid_i & ~dcache_stall_i & fp_dest_req_i & ~we_i;

  // -------------------------------------------------------------------------
  // Pipeline stall and valid
  //
  // The dcache can signal data_valid_o=1 via the critical-word-first bypass
  // after the very first refill beat, while state_q is still DC_REFILL_R
  // (dcache_stall_i=1) and the remaining 7 beats are still in flight.
  //
  // If the pipeline were to advance on that early data_valid pulse, the next
  // memory instruction would issue req_i=1 to the dcache while state != IDLE.
  // Store hits in particular would silently be discarded because the
  // always_ff store-write path is guarded by `state_q == DC_IDLE`.
  //
  // Fix: gate valid_o with ~dcache_stall_i so that mem_done_q in kronos_top
  // is only set once the dcache is truly idle (state_q = DC_IDLE) and all
  // data has been committed to the cache arrays.  This sacrifices the CWF
  // latency benefit but is necessary for correctness in an in-order pipeline
  // that has no load-queue to protect in-flight refills from subsequent stores.
  //
  // mem_stall_o: kept as req_i & ~dcache_data_valid_i for the first-cycle
  // miss detection (state is still IDLE on the cycle the miss is first seen,
  // so dcache_stall_i=0 on that cycle; ~dcache_data_valid_i handles it).
  // valid_o drops to 0 when dcache_stall_i=1, which causes mem_done_q to
  // remain cleared, req_i to stay asserted, and mem_stall_o to re-assert
  // if data_valid drops — the pipeline stays frozen until state returns to IDLE.
  // -------------------------------------------------------------------------
  assign mem_stall_o  = req_i & (~dcache_data_valid_i | dcache_stall_i);
  assign valid_o      = dcache_data_valid_i & ~dcache_stall_i;
  assign sc_success_o = dcache_sc_success_i;

  // Suppress unused-input warnings for ports consumed by dcache directly.
  assign _unused = ^{clk_i, rst_ni, amo_src_i};

endmodule
