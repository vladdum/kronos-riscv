// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_hazard.sv — pipeline stall and flush control unit
// Pipeline: IF -> ID -> RR -> EX1 -> EX2 -> MEM -> WB.
// Priority (highest first): MEM/FPU/fetch stall > load-use / JALR-fwd /
//                           FRM / CSR-RAW > EX/MEM redirect > muldiv stall
//                           > normal advance.
// Redirect out-ranks muldiv_stall so a wrong-path MUL can't block a flush.
// Flush overrides enable: when both asserted, the register is cleared.
module kronos_hazard
  import kronos_pkg::*;
(
  // Producer in RR (id_rr_q).
  input  logic       id_rr_is_load_i,
  input  logic       id_rr_is_fp_load_i,
  input  logic       id_rr_is_csr_i,
  input  logic [4:0] id_rr_rd_i,
  input  logic       id_rr_valid_i,
  // Producer in EX1 (rr_ex1_q).
  input  logic       rr_ex1_is_load_i,
  input  logic       rr_ex1_is_fp_load_i,
  input  logic       rr_ex1_is_csr_i,
  input  logic       rr_ex1_is_frm_write_i,
  input  logic [4:0] rr_ex1_rd_i,
  input  logic       rr_ex1_valid_i,
  // Producer in EX2 (ex1_ex2_q).
  input  logic       ex1_ex2_is_load_i,
  input  logic       ex1_ex2_is_fp_load_i,
  input  logic       ex1_ex2_is_csr_i,
  input  logic [4:0] ex1_ex2_rd_i,
  input  logic       ex1_ex2_rd_wen_i,
  input  logic       ex1_ex2_valid_i,
  // Producer in MEM (ex2_mem_q) — for JALR-fwd and CSR-RAW.
  input  logic [4:0] ex_mem_rd_i,
  input  logic       ex_mem_rd_wen_i,
  input  logic       ex_mem_valid_i,
  input  logic       ex_mem_is_csr_i,
  // ID-stage register addresses.
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs2_used_i,
  input  logic [4:0] if_id_rs2_i,
  input  logic       if_id_rs1_fp_i,
  input  logic       if_id_rs2_fp_i,
  input  logic       if_id_rs3_fp_i,
  input  logic [4:0] if_id_rs3_i,
  input  logic       if_id_is_jalr_i,
  input  logic       if_id_fp_dyn_rm_i,
  input  logic       if_id_uses_csr_i,
  // RR-stage CSR consumer.
  input  logic       id_rr_uses_csr_i,
  // EX redirect (branch direction mismatch) and MEM redirect (target / trap).
  input  logic       ex_redirect_i,
  input  logic       mem_redirect_i,
  // MEM/FPU/fetch stall, muldiv stall.
  input  logic       mem_stall_i,
  input  logic       muldiv_stall_i,
  // Pipeline-register enables.
  output logic       pc_en_o,
  output logic       if_id_en_o,
  output logic       id_rr_en_o,
  output logic       rr_ex1_en_o,
  output logic       ex_mem_en_o,
  output logic       mem_wb_en_o,
  // Pipeline-register flushes (clear to NOP).
  output logic       if_id_flush_o,
  output logic       id_rr_flush_o,
  output logic       rr_ex1_flush_o
);

  logic load_use, fp_load_use, jalr_fwd_stall, frm_hazard;
  logic csr_raw_stall_id, csr_raw_stall_rr;
  logic ex_mem_unused;

  // ex_mem_rd_wen_i is reserved for future MEM-class hazard checks.  Tie it
  // through an unused signal so verilator's lint stays happy.
  assign ex_mem_unused = ex_mem_rd_wen_i & ex_mem_rd_i[0];

  // Load-use: load can be in {RR, EX1, EX2}; consumer in ID.  Total stall is
  // 2 cycles in ID — the load advances RR -> EX1 -> EX2 -> MEM, where the
  // MEM result bypasses into the consumer's RR stage on the same edge.
  assign load_use =
    (id_rr_valid_i   & id_rr_is_load_i   & (id_rr_rd_i   != 5'd0) &
     ((if_id_rs1_used_i & (if_id_rs1_i == id_rr_rd_i)) |
      (if_id_rs2_used_i & (if_id_rs2_i == id_rr_rd_i)))) |
    (rr_ex1_valid_i  & rr_ex1_is_load_i  & (rr_ex1_rd_i  != 5'd0) &
     ((if_id_rs1_used_i & (if_id_rs1_i == rr_ex1_rd_i)) |
      (if_id_rs2_used_i & (if_id_rs2_i == rr_ex1_rd_i)))) |
    (ex1_ex2_valid_i & ex1_ex2_is_load_i & (ex1_ex2_rd_i != 5'd0) &
     ((if_id_rs1_used_i & (if_id_rs1_i == ex1_ex2_rd_i)) |
      (if_id_rs2_used_i & (if_id_rs2_i == ex1_ex2_rd_i))));

  // FP load-use: same shape, FP consumer keys.
  assign fp_load_use =
    (id_rr_valid_i   & id_rr_is_fp_load_i   & (id_rr_rd_i   != 5'd0) &
     ((if_id_rs1_fp_i & (if_id_rs1_i == id_rr_rd_i)) |
      (if_id_rs2_fp_i & (if_id_rs2_i == id_rr_rd_i)) |
      (if_id_rs3_fp_i & (if_id_rs3_i == id_rr_rd_i)))) |
    (rr_ex1_valid_i  & rr_ex1_is_fp_load_i  & (rr_ex1_rd_i  != 5'd0) &
     ((if_id_rs1_fp_i & (if_id_rs1_i == rr_ex1_rd_i)) |
      (if_id_rs2_fp_i & (if_id_rs2_i == rr_ex1_rd_i)) |
      (if_id_rs3_fp_i & (if_id_rs3_i == rr_ex1_rd_i)))) |
    (ex1_ex2_valid_i & ex1_ex2_is_fp_load_i & (ex1_ex2_rd_i != 5'd0) &
     ((if_id_rs1_fp_i & (if_id_rs1_i == ex1_ex2_rd_i)) |
      (if_id_rs2_fp_i & (if_id_rs2_i == ex1_ex2_rd_i)) |
      (if_id_rs3_fp_i & (if_id_rs3_i == ex1_ex2_rd_i))));

  // JALR-fwd stall: JALR in ID with rs1 matching the producer in ex1_ex2_q
  // (one stage shifted vs 7a's ex_mem_q check, to keep the stall budget the
  // same as the deeper pipe).  Gate on rd_wen so stores don't trigger a
  // wasted stall (stores have rd_wen = 0 and never produce a value into rd).
  assign jalr_fwd_stall = if_id_is_jalr_i &
                           ex1_ex2_valid_i & ex1_ex2_rd_wen_i &
                           (ex1_ex2_rd_i != 5'd0) &
                           (if_id_rs1_i == ex1_ex2_rd_i);

  // FRM/FCSR RAW: a CSR write to FRM/FCSR in EX1, FP-DYN-rm consumer in ID.
  assign frm_hazard = rr_ex1_is_frm_write_i & if_id_fp_dyn_rm_i;

  // CSR-RAW (ID-stage consumer): writer in {RR, EX1, EX2, MEM}.
  assign csr_raw_stall_id = if_id_uses_csr_i &
                            ((id_rr_valid_i   & id_rr_is_csr_i)   |
                             (rr_ex1_valid_i  & rr_ex1_is_csr_i)  |
                             (ex1_ex2_valid_i & ex1_ex2_is_csr_i) |
                             (ex_mem_valid_i  & ex_mem_is_csr_i));

  // CSR-RAW (RR-stage consumer): writer in {EX1, EX2, MEM}.  Closes a
  // one-cycle gap when an ID-stage stall releases the consumer the same cycle
  // a new writer enters EX1 from id_rr_q.
  assign csr_raw_stall_rr = id_rr_uses_csr_i &
                            ((rr_ex1_valid_i  & rr_ex1_is_csr_i)  |
                             (ex1_ex2_valid_i & ex1_ex2_is_csr_i) |
                             (ex_mem_valid_i  & ex_mem_is_csr_i));

  always_comb begin
    pc_en_o        = 1'b1;
    if_id_en_o     = 1'b1;
    id_rr_en_o     = 1'b1;
    rr_ex1_en_o    = 1'b1;
    ex_mem_en_o    = 1'b1;
    mem_wb_en_o    = 1'b1;
    if_id_flush_o  = 1'b0;
    id_rr_flush_o  = 1'b0;
    rr_ex1_flush_o = 1'b0;

    if (mem_stall_i) begin
      // Priority 1: MEM/FPU/fetch stall — hold all stages.
      pc_en_o     = 1'b0;
      if_id_en_o  = 1'b0;
      id_rr_en_o  = 1'b0;
      rr_ex1_en_o = 1'b0;
      ex_mem_en_o = 1'b0;
      mem_wb_en_o = 1'b0;
    end else if (ex_redirect_i | mem_redirect_i) begin
      // Priority 2: redirect — flush IF/ID/RR/EX1 wrong-path followers.
      // Older stages (EX2/MEM) flush via combinational gating in kronos_top
      // when the redirect carries a MEM-stage trap.
      if_id_flush_o  = 1'b1;
      id_rr_flush_o  = 1'b1;
      rr_ex1_flush_o = 1'b1;
    end else if (load_use | fp_load_use | csr_raw_stall_id | jalr_fwd_stall | frm_hazard) begin
      // Priority 3a: ID-class RAW — stall PC+IF+ID, bubble into RR.
      pc_en_o       = 1'b0;
      if_id_en_o    = 1'b0;
      id_rr_en_o    = 1'b0;
      id_rr_flush_o = 1'b1;
    end else if (csr_raw_stall_rr) begin
      // Priority 3b: RR-class CSR-RAW — stall PC+IF+ID+RR, bubble into EX1.
      pc_en_o        = 1'b0;
      if_id_en_o     = 1'b0;
      id_rr_en_o     = 1'b0;
      rr_ex1_en_o    = 1'b0;
      rr_ex1_flush_o = 1'b1;
    end else if (muldiv_stall_i) begin
      // Priority 4: muldiv FSM busy — hold all stages.
      pc_en_o     = 1'b0;
      if_id_en_o  = 1'b0;
      id_rr_en_o  = 1'b0;
      rr_ex1_en_o = 1'b0;
      ex_mem_en_o = 1'b0;
      mem_wb_en_o = 1'b0;
    end
  end

endmodule
