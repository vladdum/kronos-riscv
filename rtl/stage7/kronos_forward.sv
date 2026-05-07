// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_forward.sv — pre-registered data-hazard forward select
//
// Pipeline: IF -> ID -> RR -> EX1 -> EX2 -> MEM1 -> MEM1B -> MEM2 -> WB.  At
// ID-time T the consumer is captured into id_rr_q.  The forward select decided
// here is consumed at T+1 when the consumer is in RR and reads its rs1/rs2 via
// the bypass mux at the RR/EX1 flop boundary.
//
// Six forward sources, freshest first.  Match at ID-time T against the
// register holding the producer NOW; bypass mux at RR-time T+1 reads the
// register holding the producer AFTER it advances one stage.
//   * id_rr_q    (producer in RR at T)    -> in EX1 at T+1.  Bypass mux reads
//     the combinational alu_result_d.  Bypass key: FWD_EX1_NOW.
//   * rr_ex1_q   (producer in EX1 at T)   -> in EX2 at T+1.  Bypass mux reads
//     ex1_ex2_q.alu_result.  Bypass key: FWD_EX1.
//   * ex1_ex2_q  (producer in EX2 at T)   -> in MEM1 at T+1.  Bypass mux reads
//     ex2_mem1_q.alu_result.  Bypass key: FWD_EXMEM.
//   * ex2_mem1_q (producer in MEM1 at T)  -> in MEM1B at T+1.  Bypass mux
//     reads mem1_mem1b_q.alu_result.  Bypass key: FWD_MEM1B.
//   * mem1_mem1b_q (producer in MEM1B at T) -> in MEM2 at T+1.  Bypass mux
//     reads mem1_mem2_q.alu_result.  Stage 7d-closeout: loads SUPPRESSED on
//     this slot to break the post-MEM2 back-edge to rr_ex1_q.D — the live
//     mem2_dcache_val (lsu_rdata) path no longer routes into the bypass mux.
//     Load consumers fall through to FWD_MEMWB which reads mem_wb_q.alu_result
//     (registered).  Bypass key: FWD_MEM2.
//   * mem1_mem2_q (producer in MEM2 at T) -> in WB at T+1.  Writeback value is
//     in wb_result (driven by mem_wb_q).  Bypass key: FWD_MEMWB.
//
// Freshest wins.  x0 is never forwarded.  rd_fp suppresses bypass so a shared
// rd index between FP and integer regfiles does not poison an integer
// consumer.  Loads in {RR, EX1, EX2, MEM1, MEM1B} suppress their bypass slot
// — the load value isn't ready until mem_wb_q.alu_result at WB.  Stage 7d-
// closeout extended the suppression list to include MEM1B (the FWD_MEM2
// lsu_rdata combinational path is the back-edge being severed).  FWD_MEMWB
// is the only slot that supplies a load value (registered, via the
// mem_wb_q.alu_result writeback result mux).
module kronos_forward
  import kronos_pkg::*;
(
  // Consumer: instruction being captured into id_rr_q (currently in ID).
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs2_i,
  input  logic       if_id_rs2_used_i,
  // Producer in RR (id_rr_q) — freshest source.  Loads suppressed.
  input  logic [4:0] id_rr_rd_i,
  input  logic       id_rr_rd_wen_i,
  input  logic       id_rr_rd_fp_i,
  input  logic       id_rr_is_load_i,
  input  logic       id_rr_valid_i,
  // Producer in EX1 (rr_ex1_q).  Loads suppressed.
  input  logic [4:0] rr_ex1_rd_i,
  input  logic       rr_ex1_rd_wen_i,
  input  logic       rr_ex1_rd_fp_i,
  input  logic       rr_ex1_is_load_i,
  input  logic       rr_ex1_valid_i,
  // Producer in EX2 (ex1_ex2_q).  Loads suppressed.
  input  logic [4:0] ex1_ex2_rd_i,
  input  logic       ex1_ex2_rd_wen_i,
  input  logic       ex1_ex2_rd_fp_i,
  input  logic       ex1_ex2_is_load_i,
  input  logic       ex1_ex2_valid_i,
  // Producer in MEM1 (ex2_mem1_q).  Loads SUPPRESSED — at T+1 the producer is
  // in MEM1B and only its alu_result (AGU output for loads) is available; the
  // load value lands one stage later in MEM2 (FWD_MEM2 picks it up).
  input  logic [4:0] ex2_mem1_rd_i,
  input  logic       ex2_mem1_rd_wen_i,
  input  logic       ex2_mem1_rd_fp_i,
  input  logic       ex2_mem1_is_load_i,
  input  logic       ex2_mem1_valid_i,
  // Producer in MEM1B (mem1_mem1b_q) — Stage 7d-closeout: loads SUPPRESSED.
  // 7d-MEM1B originally permitted loads on this slot (FWD_MEM2 read lsu_rdata
  // combinationally at MEM2).  7d-closeout severs the post-MEM2 back-edge to
  // rr_ex1_q.D by suppressing loads here so consumers fall through to FWD_MEMWB
  // (mem_wb_q.alu_result, registered).
  input  logic [4:0] mem1_mem1b_rd_i,
  input  logic       mem1_mem1b_rd_wen_i,
  input  logic       mem1_mem1b_rd_fp_i,
  input  logic       mem1_mem1b_is_load_i,
  input  logic       mem1_mem1b_valid_i,
  // Producer in MEM2 (mem1_mem2_q).  Loads permitted via writeback mux.
  input  logic [4:0] mem1_mem2_rd_i,
  input  logic       mem1_mem2_rd_wen_i,
  input  logic       mem1_mem2_rd_fp_i,
  // Outputs: stored into id_rr_q.fwd_rs1_sel / id_rr_q.fwd_rs2_sel.
  output fwd_sel_e   fwd_rs1_sel_o,
  output fwd_sel_e   fwd_rs2_sel_o
);

  always_comb begin
    fwd_rs1_sel_o = FWD_NONE;
    if (if_id_rs1_used_i & (if_id_rs1_i != 5'd0)) begin
      if      (id_rr_valid_i      & id_rr_rd_wen_i      & ~id_rr_rd_fp_i      &
               ~id_rr_is_load_i    & (id_rr_rd_i      == if_id_rs1_i)) fwd_rs1_sel_o = FWD_EX1_NOW;
      else if (rr_ex1_valid_i     & rr_ex1_rd_wen_i     & ~rr_ex1_rd_fp_i     &
               ~rr_ex1_is_load_i   & (rr_ex1_rd_i     == if_id_rs1_i)) fwd_rs1_sel_o = FWD_EX1;
      else if (ex1_ex2_valid_i    & ex1_ex2_rd_wen_i    & ~ex1_ex2_rd_fp_i    &
               ~ex1_ex2_is_load_i  & (ex1_ex2_rd_i    == if_id_rs1_i)) fwd_rs1_sel_o = FWD_EXMEM;
      else if (ex2_mem1_valid_i   & ex2_mem1_rd_wen_i   & ~ex2_mem1_rd_fp_i   &
               ~ex2_mem1_is_load_i & (ex2_mem1_rd_i   == if_id_rs1_i)) fwd_rs1_sel_o = FWD_MEM1B;
      else if (mem1_mem1b_valid_i & mem1_mem1b_rd_wen_i & ~mem1_mem1b_rd_fp_i &
               ~mem1_mem1b_is_load_i &                                  // 7d-closeout: loads suppressed
               (mem1_mem1b_rd_i  == if_id_rs1_i))                      fwd_rs1_sel_o = FWD_MEM2;
      else if (                     mem1_mem2_rd_wen_i  & ~mem1_mem2_rd_fp_i  &
               (mem1_mem2_rd_i   == if_id_rs1_i))                      fwd_rs1_sel_o = FWD_MEMWB;
    end

    fwd_rs2_sel_o = FWD_NONE;
    if (if_id_rs2_used_i & (if_id_rs2_i != 5'd0)) begin
      if      (id_rr_valid_i      & id_rr_rd_wen_i      & ~id_rr_rd_fp_i      &
               ~id_rr_is_load_i    & (id_rr_rd_i      == if_id_rs2_i)) fwd_rs2_sel_o = FWD_EX1_NOW;
      else if (rr_ex1_valid_i     & rr_ex1_rd_wen_i     & ~rr_ex1_rd_fp_i     &
               ~rr_ex1_is_load_i   & (rr_ex1_rd_i     == if_id_rs2_i)) fwd_rs2_sel_o = FWD_EX1;
      else if (ex1_ex2_valid_i    & ex1_ex2_rd_wen_i    & ~ex1_ex2_rd_fp_i    &
               ~ex1_ex2_is_load_i  & (ex1_ex2_rd_i    == if_id_rs2_i)) fwd_rs2_sel_o = FWD_EXMEM;
      else if (ex2_mem1_valid_i   & ex2_mem1_rd_wen_i   & ~ex2_mem1_rd_fp_i   &
               ~ex2_mem1_is_load_i & (ex2_mem1_rd_i   == if_id_rs2_i)) fwd_rs2_sel_o = FWD_MEM1B;
      else if (mem1_mem1b_valid_i & mem1_mem1b_rd_wen_i & ~mem1_mem1b_rd_fp_i &
               ~mem1_mem1b_is_load_i &                                  // 7d-closeout: loads suppressed
               (mem1_mem1b_rd_i  == if_id_rs2_i))                      fwd_rs2_sel_o = FWD_MEM2;
      else if (                     mem1_mem2_rd_wen_i  & ~mem1_mem2_rd_fp_i  &
               (mem1_mem2_rd_i   == if_id_rs2_i))                      fwd_rs2_sel_o = FWD_MEMWB;
    end
  end

endmodule
