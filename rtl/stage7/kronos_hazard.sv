// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_hazard.sv — pipeline stall and flush control unit
// Pipeline: IF -> ID -> RR -> EX1 -> EX2 -> MEM1 -> MEM2 -> WB.
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
  // Producer in MEM1 (ex2_mem1_q) — renamed from ex_mem_* in 7b.
  input  logic       ex2_mem1_is_load_i,
  input  logic       ex2_mem1_is_fp_load_i,
  input  logic       ex2_mem1_is_csr_i,
  input  logic [4:0] ex2_mem1_rd_i,
  input  logic       ex2_mem1_rd_wen_i,
  input  logic       ex2_mem1_valid_i,
  // Producer in MEM2 (mem1_mem2_q) — new slot for CSR-RAW.
  input  logic       mem1_mem2_is_csr_i,
  input  logic [4:0] mem1_mem2_rd_i,
  input  logic       mem1_mem2_valid_i,
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
  output logic       ex2_mem1_en_o,
  output logic       mem1_mem2_en_o,
  output logic       mem_wb_en_o,
  // Pipeline-register flushes (clear to NOP).
  output logic       if_id_flush_o,
  output logic       id_rr_flush_o,
  output logic       rr_ex1_flush_o,
  output logic       ex2_mem1_flush_o,
  output logic       mem1_mem2_flush_o
);

  logic load_use, fp_load_use, jalr_fwd_stall, frm_hazard;
  logic csr_raw_stall_id, csr_raw_stall_rr;
  logic ex2_mem1_unused;

  // ex2_mem1_rd_wen_i is reserved for future MEM1-class hazard checks.  Tie
  // through an unused signal so Verilator lint stays happy.
  assign ex2_mem1_unused = ex2_mem1_rd_wen_i & ex2_mem1_rd_i[0];

  // Load-use: load can be in {RR, EX1, EX2}; consumer in ID.  Total stall is
  // 2 cycles in ID — the load advances RR -> EX1 -> EX2 -> MEM1, where the
  // MEM1 result is picked up via FWD_MEM2 at the bypass mux (not a stall).
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

  // JALR-load-fwd stall: JALR in ID with rs1 matching a load in MEM1
  // (ex2_mem1_q).  The load value arrives from dcache at MEM2 — one cycle too
  // late for the bypass mux.  Only load instructions need this stall; non-load
  // producers in MEM1 are covered by FWD_MEM2 without stalling.
  assign jalr_fwd_stall = if_id_is_jalr_i &
                           ex2_mem1_valid_i & ex2_mem1_rd_wen_i &
                           ex2_mem1_is_load_i &
                           (ex2_mem1_rd_i != 5'd0) &
                           (if_id_rs1_i == ex2_mem1_rd_i);

  // FRM/FCSR RAW: a CSR write to FRM/FCSR in EX1, FP-DYN-rm consumer in ID.
  assign frm_hazard = rr_ex1_is_frm_write_i & if_id_fp_dyn_rm_i;

  // CSR-RAW (ID-stage consumer): writer in {RR, EX1, EX2, MEM1, MEM2}.
  assign csr_raw_stall_id = if_id_uses_csr_i & (
      (id_rr_valid_i     & id_rr_is_csr_i)     |
      (rr_ex1_valid_i    & rr_ex1_is_csr_i)    |
      (ex1_ex2_valid_i   & ex1_ex2_is_csr_i)   |
      (ex2_mem1_valid_i  & ex2_mem1_is_csr_i)  |
      (mem1_mem2_valid_i & mem1_mem2_is_csr_i));

  // CSR-RAW (RR-stage consumer): writer in {EX1, EX2, MEM1, MEM2}.
  assign csr_raw_stall_rr = id_rr_uses_csr_i & (
      (rr_ex1_valid_i    & rr_ex1_is_csr_i)    |
      (ex1_ex2_valid_i   & ex1_ex2_is_csr_i)   |
      (ex2_mem1_valid_i  & ex2_mem1_is_csr_i)  |
      (mem1_mem2_valid_i & mem1_mem2_is_csr_i));

  always_comb begin
    pc_en_o           = 1'b1;
    if_id_en_o        = 1'b1;
    id_rr_en_o        = 1'b1;
    rr_ex1_en_o       = 1'b1;
    ex2_mem1_en_o     = 1'b1;
    mem1_mem2_en_o    = 1'b1;
    mem_wb_en_o       = 1'b1;
    if_id_flush_o     = 1'b0;
    id_rr_flush_o     = 1'b0;
    rr_ex1_flush_o    = 1'b0;
    ex2_mem1_flush_o  = 1'b0;
    mem1_mem2_flush_o = 1'b0;

    if (mem_stall_i) begin
      // Priority 1: MEM/FPU/fetch stall — hold all stages.
      pc_en_o        = 1'b0;
      if_id_en_o     = 1'b0;
      id_rr_en_o     = 1'b0;
      rr_ex1_en_o    = 1'b0;
      ex2_mem1_en_o  = 1'b0;
      mem1_mem2_en_o = 1'b0;
      mem_wb_en_o    = 1'b0;
    end else if (ex_redirect_i | mem_redirect_i) begin
      // Priority 2: redirect — flush IF/ID/RR/EX1 wrong-path followers.
      // Older stages (EX2/MEM1/MEM2) flush via combinational gating in
      // kronos_top when the redirect carries a MEM-stage trap.
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
      pc_en_o        = 1'b0;
      if_id_en_o     = 1'b0;
      id_rr_en_o     = 1'b0;
      rr_ex1_en_o    = 1'b0;
      ex2_mem1_en_o  = 1'b0;
      mem1_mem2_en_o = 1'b0;
      mem_wb_en_o    = 1'b0;
    end
  end

endmodule
