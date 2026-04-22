// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_hazard.sv — pipeline stall and flush control unit
// Priority (highest first): MEM/FPU/fetch stall > load-use / JALR-fwd / FRM-hazard
//                           > EX/MEM redirect > muldiv stall > normal.
// Redirect out-ranks muldiv_stall so a wrong-path MUL can't block a flush.
// Flush overrides enable: when both asserted, the register is cleared.
module kronos_hazard
  import kronos_pkg::*;
(
  // Load-use detection inputs
  input  logic       id_ex_is_load_i,
  input  logic [4:0] id_ex_rd_i,
  input  logic       id_ex_valid_i,
  // ID-stage register addresses (for load-use check)
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs2_used_i,
  input  logic [4:0] if_id_rs2_i,
  // FP load-use detection (stage5+; tie to 0 in earlier stages)
  input  logic       id_ex_is_fp_load_i,
  input  logic       if_id_rs1_fp_i,
  input  logic       if_id_rs2_fp_i,
  input  logic       if_id_rs3_fp_i,
  input  logic [4:0] if_id_rs3_i,
  // JALR-forward stall: JALR in ID with rs1 matching MEM-stage producer
  input  logic       if_id_is_jalr_i,
  input  logic [4:0] ex_mem_rd_i,
  input  logic       ex_mem_rd_wen_i,
  input  logic       ex_mem_valid_i,
  // FRM/FCSR RAW hazard: CSR write to FRM/FCSR in EX, FP-dyn-rm instruction in ID.
  // frm_o is combinatorially from fcsr_q; the write only commits at posedge.
  // Stall 1 cycle so the FP instruction re-decodes after the write is visible.
  input  logic       id_ex_is_frm_write_i,  // EX has a CSR write to FRM or FCSR
  input  logic       if_id_fp_dyn_rm_i,     // ID has an FP instr with rm=3'b111 (DYN)
  // EX redirect (branch direction mismatch, JAL/JALR, trap, MRET)
  input  logic       ex_redirect_i,
  // MEM redirect (branch target mismatch detected one cycle later)
  input  logic       mem_redirect_i,
  // MEM/FPU/fetch stall bundle (LSU bus wait, FPU scoreboard, IF not valid).
  // These freeze the pipeline with absolute priority — they cannot be dropped
  // by a redirect (e.g. an in-flight AXI transaction must complete).
  input  logic       mem_stall_i,
  // muldiv stall — separate from mem_stall_i so redirect can flush a
  // wrong-path MUL instead of being held by priority-1 pipeline freeze.
  input  logic       muldiv_stall_i,
  // Pipeline register enables
  output logic       pc_en_o,
  output logic       if_id_en_o,
  output logic       id_ex_en_o,
  output logic       ex_mem_en_o,
  output logic       mem_wb_en_o,
  // Pipeline register flush (clear to NOP)
  output logic       if_id_flush_o,
  output logic       id_ex_flush_o
);

  logic load_use;
  logic fp_load_use;
  logic jalr_fwd_stall;
  logic frm_hazard;

  assign load_use = id_ex_valid_i && id_ex_is_load_i && (id_ex_rd_i != 5'd0) &&
                    ((if_id_rs1_used_i && if_id_rs1_i == id_ex_rd_i) ||
                     (if_id_rs2_used_i && if_id_rs2_i == id_ex_rd_i));

  // FP load-use: FP load in EX, following FP instruction reads the same FP reg.
  // Uses rs1_fp/rs2_fp/rs3_fp to distinguish FP register reads from integer reads.
  assign fp_load_use = id_ex_valid_i && id_ex_is_fp_load_i && (id_ex_rd_i != 5'd0) &&
                       ((if_id_rs1_fp_i && if_id_rs1_i == id_ex_rd_i) ||
                        (if_id_rs2_fp_i && if_id_rs2_i == id_ex_rd_i) ||
                        (if_id_rs3_fp_i && if_id_rs3_i == id_ex_rd_i));

  // JALR in ID with rs1 matching the instruction in MEM (about to enter WB).
  // Stalling 1 cycle converts MEM/WB forward into EX/MEM forward or regfile read,
  // breaking the JALR adder → mispredict comparator carry-chain path (class 2).
  assign jalr_fwd_stall = if_id_is_jalr_i &&
                           ex_mem_valid_i && ex_mem_rd_wen_i &&
                           (ex_mem_rd_i != 5'd0) &&
                           (if_id_rs1_i == ex_mem_rd_i);

  // FRM/FCSR RAW hazard: a CSR write to FRM/FCSR is in EX and the next
  // instruction in ID will use dynamic rounding mode. The decode unit reads
  // frm combinatorially from fcsr_q; the write only lands at posedge. One
  // stall cycle lets the FP instruction re-decode with the updated FRM.
  assign frm_hazard = id_ex_is_frm_write_i && if_id_fp_dyn_rm_i;

  always_comb begin
    // Default: full advance, no flush
    pc_en_o       = 1'b1;
    if_id_en_o    = 1'b1;
    id_ex_en_o    = 1'b1;
    ex_mem_en_o   = 1'b1;
    mem_wb_en_o   = 1'b1;
    if_id_flush_o = 1'b0;
    id_ex_flush_o = 1'b0;

    if (mem_stall_i) begin
      // Priority 1: MEM/FPU/fetch stall — hold all stages
      pc_en_o     = 1'b0;
      if_id_en_o  = 1'b0;
      id_ex_en_o  = 1'b0;
      ex_mem_en_o = 1'b0;
      mem_wb_en_o = 1'b0;
    end else if (load_use | fp_load_use | jalr_fwd_stall | frm_hazard) begin
      // Priority 2: load-use / FRM hazard — stall PC+IF+ID, bubble into EX
      pc_en_o       = 1'b0;
      if_id_en_o    = 1'b0;
      id_ex_en_o    = 1'b0;
      id_ex_flush_o = 1'b1;   // flush overrides en → bubble in ID/EX
    end else if (ex_redirect_i | mem_redirect_i) begin
      // Priority 3: EX/MEM redirect — squash IF and ID.  Placed above
      // muldiv_stall so a wrong-path MUL (id_ex_q.valid=1, muldiv_valid=0)
      // is flushed immediately instead of deadlocking the pipeline while the
      // muldiv FSM waits for a muldiv_req that was gated by the redirect.
      if_id_flush_o = 1'b1;
      id_ex_flush_o = 1'b1;
    end else if (muldiv_stall_i) begin
      // Priority 4: muldiv FSM busy — hold all stages while it completes.
      pc_en_o     = 1'b0;
      if_id_en_o  = 1'b0;
      id_ex_en_o  = 1'b0;
      ex_mem_en_o = 1'b0;
      mem_wb_en_o = 1'b0;
    end
  end

endmodule
