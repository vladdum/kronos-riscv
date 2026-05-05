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
  // Load-use detection inputs — EX1 producer (id_ex1_q in Stage 7a).
  input  logic       id_ex_is_load_i,
  input  logic [4:0] id_ex_rd_i,
  input  logic       id_ex_valid_i,
  // Stage 7a — second load-use source: a load in EX2 (ex1_ex2_q) is still
  // one cycle away from having data available at the consumer's EX1 read.
  // Adding this widens the load-use stall to two cycles total.
  input  logic       ex1_ex2_is_load_i,
  input  logic       ex1_ex2_is_fp_load_i,
  input  logic [4:0] ex1_ex2_rd_i,
  input  logic       ex1_ex2_valid_i,
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
  // Stage 7a — generic CSR RAW hazard.  T10 moved architectural CSR write
  // commit from EX1 to retire (mem_wb_q), so a CSR-using consumer in EX1 sees
  // a stale CSR value if a CSR-writer is still in EX1/EX2/MEM.  Stall the
  // consumer in ID until every in-flight CSR-writer has retired.  Producer
  // bits are id_ex1_q.dec.is_csr / ex1_ex2_q.dec.is_csr / ex2_mem_q.dec.is_csr
  // (gated by valid).  Consumer bit is any CSR-state read in ID: is_csr,
  // is_mret, is_sret, is_wfi, is_ecall, is_ebreak (the trap path reads
  // mtvec/stvec).  All consumer cases either read CSR registers directly or
  // depend on CSR state via the trap_vector mux.
  input  logic       id_ex_is_csr_i,        // EX1 has a CSR-writing instruction
  input  logic       ex1_ex2_is_csr_i,      // EX2 has a CSR-writing instruction
  input  logic       ex_mem_is_csr_i,       // MEM has a CSR-writing instruction
  input  logic       if_id_uses_csr_i,      // ID consumes CSR state (csr/mret/sret/wfi/ecall/ebreak)
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

  // Combinational signals
  logic load_use;
  logic fp_load_use;
  logic jalr_fwd_stall;
  logic frm_hazard;
  logic csr_raw_stall;

  // Stage 7a — load-use stalls 2 cycles total.  A load passes through EX1
  // (id_ex_*) and EX2 (ex1_ex2_*) before its data lands in mem_wb_q via the
  // dcache return at end of MEM, so a consumer in ID with rs matching the
  // load's rd at either of those positions must stall.
  assign load_use = (id_ex_valid_i && id_ex_is_load_i && (id_ex_rd_i != 5'd0) &&
                     ((if_id_rs1_used_i && if_id_rs1_i == id_ex_rd_i) ||
                      (if_id_rs2_used_i && if_id_rs2_i == id_ex_rd_i))) ||
                    (ex1_ex2_valid_i && ex1_ex2_is_load_i && (ex1_ex2_rd_i != 5'd0) &&
                     ((if_id_rs1_used_i && if_id_rs1_i == ex1_ex2_rd_i) ||
                      (if_id_rs2_used_i && if_id_rs2_i == ex1_ex2_rd_i)));

  // FP load-use: FP load in EX1 or EX2, following FP instruction reads the same FP reg.
  // Uses rs1_fp/rs2_fp/rs3_fp to distinguish FP register reads from integer reads.
  assign fp_load_use = (id_ex_valid_i && id_ex_is_fp_load_i && (id_ex_rd_i != 5'd0) &&
                        ((if_id_rs1_fp_i && if_id_rs1_i == id_ex_rd_i) ||
                         (if_id_rs2_fp_i && if_id_rs2_i == id_ex_rd_i) ||
                         (if_id_rs3_fp_i && if_id_rs3_i == id_ex_rd_i))) ||
                       (ex1_ex2_valid_i && ex1_ex2_is_fp_load_i && (ex1_ex2_rd_i != 5'd0) &&
                        ((if_id_rs1_fp_i && if_id_rs1_i == ex1_ex2_rd_i) ||
                         (if_id_rs2_fp_i && if_id_rs2_i == ex1_ex2_rd_i) ||
                         (if_id_rs3_fp_i && if_id_rs3_i == ex1_ex2_rd_i)));

  // JALR in ID with rs1 matching the instruction in MEM (about to enter WB).
  // Stalling 1 cycle converts MEM/WB forward into EX/MEM forward or regfile read,
  // breaking the JALR adder -> mispredict comparator carry-chain path (class 2).
  assign jalr_fwd_stall = if_id_is_jalr_i &&
                           ex_mem_valid_i && ex_mem_rd_wen_i &&
                           (ex_mem_rd_i != 5'd0) &&
                           (if_id_rs1_i == ex_mem_rd_i);

  // FRM/FCSR RAW hazard: a CSR write to FRM/FCSR is in EX and the next
  // instruction in ID will use dynamic rounding mode. The decode unit reads
  // frm combinatorially from fcsr_q; the write only lands at posedge. One
  // stall cycle lets the FP instruction re-decode with the updated FRM.
  assign frm_hazard = id_ex_is_frm_write_i && if_id_fp_dyn_rm_i;

  // Stage 7a — CSR RAW stall.  In stage 7a the architectural CSR write
  // commits at retire (mem_wb_q), four pipe stages downstream of EX1.  A CSR
  // consumer following a CSR writer at any distance < 4 instructions reads
  // stale state and goes to the wrong target / wrong mode.  This stall is
  // conservative: any in-flight CSR-write keeps the consumer in ID until
  // the writer reaches WB (where retire_i pulses and the architectural
  // register updates at the same edge that releases the consumer into EX1).
  assign csr_raw_stall = if_id_uses_csr_i &
                         ((id_ex_valid_i    & id_ex_is_csr_i)    |
                          (ex1_ex2_valid_i  & ex1_ex2_is_csr_i)  |
                          (ex_mem_valid_i   & ex_mem_is_csr_i));

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
    end else if (ex_redirect_i | mem_redirect_i) begin
      // Priority 2: EX/MEM redirect — squash IF and ID.  Must outrank the
      // RAW-class stalls (load-use, CSR-RAW, frm_hazard, jalr_fwd_stall) so a
      // redirect always flushes the speculative wrong-path follower in
      // if_id_q.  If the wrong-path follower happens to be a CSR/load
      // consumer of an in-flight producer, leaving it in if_id_q (priority 3
      // below holds, doesn't flush) and then advancing it onto the new
      // (post-redirect) path commits it with stale state — visible as e.g.
      // test_sret reaching sret with sepc=0 because the wrong-path sret
      // survived an mret redirect.  Placed above muldiv_stall so a wrong-
      // path MUL is flushed instead of deadlocking the muldiv FSM.
      if_id_flush_o = 1'b1;
      id_ex_flush_o = 1'b1;
    end else if (load_use | fp_load_use | jalr_fwd_stall | frm_hazard | csr_raw_stall) begin
      // Priority 3: load-use / FRM / CSR-RAW hazard — stall PC+IF+ID,
      // bubble into EX
      pc_en_o       = 1'b0;
      if_id_en_o    = 1'b0;
      id_ex_en_o    = 1'b0;
      id_ex_flush_o = 1'b1;   // flush overrides en -> bubble in ID/EX
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
