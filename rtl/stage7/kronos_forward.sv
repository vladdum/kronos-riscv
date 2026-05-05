// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_forward.sv — pre-registered data-hazard forward select (Stage 7a)
//
// The pipeline is IF -> ID -> EX1 -> EX2 -> MEM -> WB.  At ID-time T the
// consumer is being captured into id_ex1_q; the forward select decided here
// is consumed at T+1 when the consumer is in EX1 and reads its rs1/rs2.
//
// Three forward sources, freshest first:
//   * id_ex1_q  (producer in EX1 at T) -> in EX2 at T+1.  Result is in
//     ex1_ex2_q.alu_result one cycle later.  Bypass key: FWD_EX1.
//   * ex1_ex2_q (producer in EX2 at T) -> in MEM at T+1.  Result is in
//     ex2_mem_q.alu_result one cycle later.  Bypass key: FWD_EXMEM.
//   * ex2_mem_q (producer in MEM at T) -> in WB at T+1.  Writeback value is
//     in wb_result_64 (driven by mem_wb_q).  Bypass key: FWD_MEMWB.
//
// Loads write their data into the MEM-cycle of *their* MEM stage, which
// lands in mem_wb_q.alu_result at the next clock edge.  So:
//   * a load in id_ex1_q at T cannot be forwarded via FWD_EX1 — its data is
//     not yet in ex1_ex2_q.alu_result at T+1 (still travelling through EX2).
//   * a load in ex1_ex2_q at T cannot be forwarded via FWD_EXMEM — its data
//     is not yet in ex2_mem_q.alu_result at T+1 (still in MEM).
//   * a load in ex2_mem_q at T can be forwarded via FWD_MEMWB — by T+1 its
//     data has been registered into mem_wb_q.alu_result and surfaces through
//     the writeback mux.  No suppression here.
//
// EX1 path has priority over EX2, which has priority over MEM.  x0 is never
// forwarded.  rd_fp suppresses bypass so a shared rd index between FP and
// integer regfiles (e.g. FLW ft11 = f31 vs ADDI t6 = x31) does not poison
// the integer consumer.
module kronos_forward
  import kronos_pkg::*;
(
  // Consumer: instruction being captured into id_ex1_q (currently in ID).
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs2_i,
  input  logic       if_id_rs2_used_i,
  // Producer in EX1 (id_ex1_q) — freshest source.  Loads suppressed.
  input  logic [4:0] id_ex1_rd_i,
  input  logic       id_ex1_rd_wen_i,
  input  logic       id_ex1_rd_fp_i,
  input  logic       id_ex1_is_load_i,
  input  logic       id_ex1_valid_i,
  // Producer in EX2 (ex1_ex2_q) — middle source.  Loads suppressed.
  input  logic [4:0] ex1_ex2_rd_i,
  input  logic       ex1_ex2_rd_wen_i,
  input  logic       ex1_ex2_rd_fp_i,
  input  logic       ex1_ex2_is_load_i,
  input  logic       ex1_ex2_valid_i,
  // Producer in MEM (ex2_mem_q) — oldest source.  Loads OK via WB mux.
  input  logic [4:0] ex2_mem_rd_i,
  input  logic       ex2_mem_rd_wen_i,
  input  logic       ex2_mem_rd_fp_i,
  // Outputs: stored into id_ex1_q.fwd_rs1_sel / id_ex1_q.fwd_rs2_sel.
  output fwd_sel_e   fwd_rs1_sel_o,
  output fwd_sel_e   fwd_rs2_sel_o
);

  // Per-source bypass-allowed predicates.  rd_fp blocks integer poisoning
  // from a shared rd index; is_load blocks bypass when the producer's data
  // has not yet reached the consumer's EX1 cycle.
  logic ex1_can_fwd;
  logic ex2_can_fwd;
  logic mem_can_fwd;

  assign ex1_can_fwd = id_ex1_valid_i  && id_ex1_rd_wen_i  && !id_ex1_rd_fp_i  &&
                       !id_ex1_is_load_i  && (id_ex1_rd_i  != 5'd0);
  assign ex2_can_fwd = ex1_ex2_valid_i && ex1_ex2_rd_wen_i && !ex1_ex2_rd_fp_i &&
                       !ex1_ex2_is_load_i && (ex1_ex2_rd_i != 5'd0);
  assign mem_can_fwd = ex2_mem_rd_wen_i && !ex2_mem_rd_fp_i && (ex2_mem_rd_i != 5'd0);

  always_comb begin
    fwd_rs1_sel_o = FWD_NONE;
    fwd_rs2_sel_o = FWD_NONE;

    // EX1 (freshest) — highest priority.
    if (ex1_can_fwd) begin
      if (if_id_rs1_used_i && if_id_rs1_i == id_ex1_rd_i) fwd_rs1_sel_o = FWD_EX1;
      if (if_id_rs2_used_i && if_id_rs2_i == id_ex1_rd_i) fwd_rs2_sel_o = FWD_EX1;
    end

    // EX2 — only if EX1 did not already forward this operand.
    if (ex2_can_fwd) begin
      if (if_id_rs1_used_i && if_id_rs1_i == ex1_ex2_rd_i && fwd_rs1_sel_o == FWD_NONE) begin
        fwd_rs1_sel_o = FWD_EXMEM;
      end
      if (if_id_rs2_used_i && if_id_rs2_i == ex1_ex2_rd_i && fwd_rs2_sel_o == FWD_NONE) begin
        fwd_rs2_sel_o = FWD_EXMEM;
      end
    end

    // MEM (oldest) — only if neither EX1 nor EX2 already forwarded.
    if (mem_can_fwd) begin
      if (if_id_rs1_used_i && if_id_rs1_i == ex2_mem_rd_i && fwd_rs1_sel_o == FWD_NONE) begin
        fwd_rs1_sel_o = FWD_MEMWB;
      end
      if (if_id_rs2_used_i && if_id_rs2_i == ex2_mem_rd_i && fwd_rs2_sel_o == FWD_NONE) begin
        fwd_rs2_sel_o = FWD_MEMWB;
      end
    end
  end

endmodule
