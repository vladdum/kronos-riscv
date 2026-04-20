// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage5) — 5-stage in-order pipeline with RV64IMAFD support.
// Extends stage4 (RV64IMAC) with:
//   * kronos_regfile_fp  — 3R1W 32×64-bit FP register file
//   * kronos_fpu_top     — FPU dispatch wrapper (FMISC/FCVT/FADD/FMUL/FMA)
//   * FP load/store wiring through kronos_lsu
//   * fflags/frm wiring through kronos_csr
//   * FP stall: entire pipeline stalls while FPU computes
module kronos_top
  import kronos_pkg::*;
(
  input  logic             clk_i,
  input  logic             rst_ni,

  // Instruction fetch port (AXI4 read-only master)
  output kronos_axi_req_t  instr_axi_req_o,
  input  kronos_axi_resp_t instr_axi_rsp_i,

  // Data port (AXI4 read/write master)
  output kronos_axi_req_t  data_axi_req_o,
  input  kronos_axi_resp_t data_axi_rsp_i,

  input  logic             irq_timer_i,
  input  logic [14:0]      irq_fast_i,
  input  logic [31:0]      boot_addr_i
);

  // -------------------------------------------------------------------------
  // Pipeline registers
  // -------------------------------------------------------------------------
  if_id_reg_t  if_id_q;
  id_ex_reg_t  id_ex_q;
  ex_mem_reg_t ex_mem_q;
  mem_wb_reg_t mem_wb_q;
  logic [31:0] pc_q;

  // -------------------------------------------------------------------------
  // Hazard / forwarding control
  // -------------------------------------------------------------------------
  logic      pc_en, if_id_en, id_ex_en, ex_mem_en, mem_wb_en;
  logic      if_id_flush, id_ex_flush;
  fwd_sel_e  fwd_rs1_sel, fwd_rs2_sel;

  // -------------------------------------------------------------------------
  // ID-stage wires
  // -------------------------------------------------------------------------
  decoded_instr_t id_dec;
  logic [63:0]    rs1_rdata_64, rs2_rdata_64;
  logic [63:0]    rs1_data_id, rs2_data_id, rs3_data_id;
  logic           wb_writing;

  // Stage 5a: FP regfile read ports
  logic [63:0]    fp_rd1, fp_rd2, fp_rd3;

  // Stage 5a: CSR frm output
  logic [2:0]     frm;

  // Fix #2: ID-stage forwarding helper signals.
  // FP paths: 2-bit one-hot selector + data mux (4-way, replaces 4-level chain).
  // Integer path: plain WB-bypass-or-regfile (EX/MEM forwarding via fwd_rs1_sel).
  logic [1:0]     fp_rs1_sel, fp_rs2_sel, fp_rs3_sel;
  logic [63:0]    fp_rs1_data_id, fp_rs2_data_id, fp_rs3_data_id;
  logic [63:0]    int_rs1_data_id, int_rs2_data_id;

  // -------------------------------------------------------------------------
  // EX-stage wires (64-bit datapath)
  // -------------------------------------------------------------------------
  logic [63:0] fwd_rs1_data, fwd_rs2_data;
  logic [63:0] alu_a, alu_b, alu_result;
  logic [63:0] ex_result;
  logic [31:0] ex_pc_next;
  logic        ex_redirect;
  logic        branch_taken;
  logic        irq_pending;
  logic [63:0] csr_rdata;
  logic [63:0] trap_vector, mepc;
  logic [31:0] trap_cause;
  logic [63:0] jalr_target_64;

  // STAGE2: muldiv signals (64-bit)
  logic [63:0] muldiv_result;
  logic        muldiv_valid, muldiv_idle;
  logic        muldiv_stall;

  // Fix #3: pre-registered CSR-select flag for EX forwarding mux.
  // Registered at the EX→MEM boundary; eliminates the 3-bit wb_sel compare
  // from the FWD_EXMEM combinational path.
  logic        ex_mem_csr_q;

  // STAGE3: fetch FSM
  typedef enum logic { FETCH_IDLE = 1'b0, FETCH_WAIT_R = 1'b1 } fetch_state_e;
  fetch_state_e fetch_state_q;
  logic         fetch_stale_q;
  logic         fetch_flush;
  logic         instr_fetch_stall;
  logic         combined_stall;

  // STAGE3: C extension — alignment unit signals
  logic [31:0] align_instr;
  logic        align_instr_valid;
  logic        align_is_16b;
  logic        align_stall;
  logic        align_need_upper;
  logic        align_needs_fetch;

  // STAGE3: branch predictor
  logic        pred_taken;
  logic [31:0] pred_target;
  logic        bpred_update_en;
  logic        actual_taken;
  logic        bpred_mispredict;
  logic        bpred_mispredict_target; // MEM-stage: predicted target ≠ actual target
  logic        mem_redirect;
  logic        is_branch_or_jump;

  // STAGE5a: FRM/FCSR RAW hazard detection signals for u_hazard
  logic        id_ex_is_frm_write;
  logic        if_id_fp_dyn_rm;

  // -------------------------------------------------------------------------
  // MEM-stage wires (64-bit lsu data)
  // -------------------------------------------------------------------------
  logic [63:0]      lsu_rdata;
  logic             lsu_valid;
  logic             mem_stall;
  // mem_done_q: set when LSU signals valid_o; cleared when MEM/WB register
  // advances.  Gates req_i so LSU does not re-issue while the pipeline is
  // frozen by instr_fetch_stall.
  logic             mem_done_q;
  logic [63:0]      lsu_rdata_latch;  // holds rdata across the stall gap
  kronos_axi_req_t  data_req;
  kronos_axi_resp_t data_rsp;

  // Stage 5a: LSU FP response
  logic             lsu_fp_dest;
  logic [63:0]      lsu_fp_rdata;

  // -------------------------------------------------------------------------
  // WB-stage wires (64-bit)
  // -------------------------------------------------------------------------
  logic [63:0] wb_result_64;

  // -------------------------------------------------------------------------
  // Stage 5a: FPU wires
  // -------------------------------------------------------------------------
  // Dispatch control: one-shot dispatch guard
  logic       fp_inflight_q;       // FPU is computing
  logic       fpu_dispatched_q;    // dispatch has fired for current EX instr
  logic       fpu_out_valid;
  logic [63:0] fpu_result;
  logic [4:0]  fpu_fflags;
  fpu_tag_t    fpu_tag_out;
  logic        fpu_busy;
  fpu_tag_t    fpu_tag_in;

  // FP stall
  logic        fpu_stall;
  logic        fpu_dispatching;  // combinational: dispatch will fire this cycle

  // FPU result latch: captures fpu_result when fpu_out_valid fires so the
  // result survives instr_fetch_stall cycles that may hold combined_stall=1
  // even after fpu_stall drops to 0.
  logic        fp_result_valid_q;
  logic [63:0] fp_result_q;
  fpu_tag_t    fp_tag_q;

  // Combinatorial: current FPU result (just-fired or latched)
  logic        fp_result_avail;
  logic [63:0] fp_result_cur;
  fpu_tag_t    fp_tag_cur;

  // FPU operand muxes: EX forwarding for integer-source FP instructions.
  // FMV.W.X / FMV.D.X read integer rs1/rs2; use fwd_rs1/2_data so that
  // MEM-WB bypassing applies (id_ex_q.rs1_data may be stale when the
  // producer was still in MEM when the FP instruction was in ID).
  logic [63:0] fpu_a_i, fpu_b_i;

  // FP regfile write port signals
  logic        fp_we;
  logic [4:0]  fp_wa;
  logic [63:0] fp_wd;

  // -------------------------------------------------------------------------
  // PC next (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] pc_next;

  // =========================================================================
  // Submodule instantiations
  // =========================================================================

  kronos_decode u_decode (
    .instr_i        (if_id_q.instr),
    .frm_i          (frm),
    .decoded_o      (id_dec),
    .illegal_insn_o ()               // mirrored into id_dec.illegal; unused here
  );

  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (id_dec.rs1),
    .rs2_addr_i  (id_dec.rs2),
    .rs1_rdata_o (rs1_rdata_64),
    .rs2_rdata_o (rs2_rdata_64),
    .rd_addr_i   (mem_wb_q.dec.rd),
    .rd_wen_i    (mem_wb_q.valid & mem_wb_q.dec.rd_wen & ~mem_wb_q.dec.rd_fp),
    .rd_wdata_i  (wb_result_64)
  );

  // Stage 5a: FP register file
  kronos_regfile_fp u_regfile_fp (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .ra1_i   (id_dec.rs1),
    .rd1_o   (fp_rd1),
    .ra2_i   (id_dec.rs2),
    .rd2_o   (fp_rd2),
    .ra3_i   (id_dec.rs3),
    .rd3_o   (fp_rd3),
    .wa_i    (fp_wa),
    .wd_i    (fp_wd),
    .we_i    (fp_we)
  );

  kronos_forward u_forward (
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs2_i      (id_dec.rs2),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_rd_wen_i   (id_ex_q.dec.rd_wen & id_ex_q.valid),
    .id_ex_rd_fp_i    (id_ex_q.dec.rd_fp),
    .id_ex_is_load_i  (id_ex_q.dec.wb_sel == WB_MEM),
    .ex_mem_rd_i      (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i  (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .ex_mem_rd_fp_i   (ex_mem_q.dec.rd_fp),
    .fwd_rs1_sel_o    (fwd_rs1_sel),
    .fwd_rs2_sel_o    (fwd_rs2_sel)
  );

  // STAGE3: combined_stall — mem_stall | muldiv_stall | instr_fetch_stall | fpu_stall
  assign muldiv_stall      = id_ex_q.valid & id_ex_q.dec.is_muldiv & ~muldiv_valid
                             & ~ex_redirect & ~mem_redirect;
  assign instr_fetch_stall = ~align_instr_valid;
  // fpu_dispatching: the FPU dispatch will fire this cycle.  Stall immediately
  // so the following instruction stays in IF/ID and can receive the FP result
  // via the ID forwarding mux when the stall releases.
  assign fpu_dispatching   = id_ex_q.valid & id_ex_q.dec.is_fp &
                             ~id_ex_q.dec.fp_load & ~id_ex_q.dec.fp_store &
                             ~fpu_dispatched_q;
  // fp_result_avail: FPU result is available (just fired this cycle or latched
  // from a previous cycle where fpu_out_valid fired but the pipeline was still
  // stalled by instr_fetch_stall or mem_stall).
  assign fp_result_avail   = fpu_out_valid | fp_result_valid_q;
  assign fp_result_cur     = fpu_out_valid ? fpu_result  : fp_result_q;
  assign fp_tag_cur        = fpu_out_valid ? fpu_tag_out : fp_tag_q;
  // Release stall once the result is available; keep stalled until then.
  assign fpu_stall         = (fp_inflight_q | fpu_dispatching) & ~fp_result_avail;
  assign combined_stall    = mem_stall | muldiv_stall | instr_fetch_stall | fpu_stall;

  // FRM/FCSR RAW hazard: a CSR write to FRM/FCSR in EX will update fcsr_q at
  // the posedge, but decode reads frm combinatorially from fcsr_q. Stall 1
  // cycle so the FP instruction in ID re-decodes after the new FRM is visible.
  assign id_ex_is_frm_write = id_ex_q.valid & id_ex_q.dec.is_csr &
                               (id_ex_q.dec.csr_addr == 12'h002 |  // FRM
                                id_ex_q.dec.csr_addr == 12'h003);  // FCSR
  // Detect FP instruction in ID that uses dynamic rounding mode (rm=3'b111).
  // Covers OP-FP (0x53) and FMA variants (0x43/0x47/0x4B/0x4F).
  assign if_id_fp_dyn_rm    = if_id_q.valid &
                               (if_id_q.instr[14:12] == 3'b111) &
                               (if_id_q.instr[6:0] == 7'b1010011 |  // OP-FP
                                if_id_q.instr[6:0] == 7'b1000011 |  // FMADD
                                if_id_q.instr[6:0] == 7'b1000111 |  // FMSUB
                                if_id_q.instr[6:0] == 7'b1001011 |  // FNMSUB
                                if_id_q.instr[6:0] == 7'b1001111);  // FNMADD

  kronos_hazard u_hazard (
    .id_ex_is_load_i      (id_ex_q.dec.is_load),
    .id_ex_rd_i           (id_ex_q.dec.rd),
    .id_ex_valid_i        (id_ex_q.valid),
    .if_id_rs1_used_i     (id_dec.rs1_used),
    .if_id_rs1_i          (id_dec.rs1),
    .if_id_rs2_used_i     (id_dec.rs2_used),
    .if_id_rs2_i          (id_dec.rs2),
    // FP load-use hazard
    .id_ex_is_fp_load_i   (id_ex_q.dec.fp_load),
    .if_id_rs1_fp_i       (id_dec.rs1_fp),
    .if_id_rs2_fp_i       (id_dec.rs2_fp),
    .if_id_rs3_fp_i       (id_dec.rs3_fp),
    .if_id_rs3_i          (id_dec.rs3),
    .if_id_is_jalr_i      (id_dec.is_jalr),
    .ex_mem_rd_i          (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i      (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .ex_mem_valid_i       (ex_mem_q.valid),
    // FRM/FCSR RAW hazard
    .id_ex_is_frm_write_i (id_ex_is_frm_write),
    .if_id_fp_dyn_rm_i    (if_id_fp_dyn_rm),
    .ex_redirect_i        (ex_redirect),
    .mem_redirect_i       (mem_redirect),
    .mem_stall_i          (combined_stall),
    .pc_en_o          (pc_en),
    .if_id_en_o       (if_id_en),
    .id_ex_en_o       (id_ex_en),
    .ex_mem_en_o      (ex_mem_en),
    .mem_wb_en_o      (mem_wb_en),
    .if_id_flush_o    (if_id_flush),
    .id_ex_flush_o    (id_ex_flush)
  );

  kronos_alu u_alu (
    .op_i      (id_ex_q.dec.alu_op),
    .a_i       (alu_a),
    .b_i       (alu_b),
    .word_op_i (id_ex_q.dec.is_word_op),
    .result_o  (alu_result)
  );

  kronos_muldiv u_muldiv (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .req_i     (id_ex_q.valid & id_ex_q.dec.is_muldiv & muldiv_idle & ~mem_stall
               & ~ex_redirect & ~mem_redirect),
    .op_i      (id_ex_q.dec.muldiv_op),
    .a_i       (fwd_rs1_data),
    .b_i       (fwd_rs2_data),
    .word_op_i (id_ex_q.dec.is_word_op),
    .result_o  (muldiv_result),
    .busy_o    (),
    .valid_o   (muldiv_valid),
    .idle_o    (muldiv_idle)
  );

  assign ex_result = id_ex_q.dec.is_muldiv ? muldiv_result : alu_result;

  // MISA_EXT = I + M + A + C + F + D extension bits (bits 8,12,0,2,5,3) = 26'h112D
  kronos_csr #(.MISA_EXT(26'h112D)) u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (id_ex_q.valid & id_ex_q.dec.is_csr & ~combined_stall),
    .addr_i        (id_ex_q.dec.csr_addr),
    .funct3_i      (id_ex_q.dec.csr_funct3),
    .use_imm_i     (id_ex_q.dec.csr_use_imm),
    .rs1_data_i    (fwd_rs1_data),
    .rs1_addr_i    (id_ex_q.dec.rs1),
    .rdata_o       (csr_rdata),
    .valid_o       (),
    // Gate trap_i and mret_i with ~combined_stall: CSR must only update state
    // when the pipeline is actually advancing (see stage3 comment for details).
    .trap_i        (id_ex_q.valid & ~combined_stall &
                    (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                     id_ex_q.dec.illegal  | irq_pending)),
    .trap_pc_i     (id_ex_q.pc),
    .trap_cause_i  (trap_cause),
    .mret_i        (id_ex_q.valid & ~combined_stall & id_ex_q.dec.is_mret),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .irq_timer_i   (irq_timer_i),
    .irq_fast_i    (irq_fast_i),
    .irq_pending_o (irq_pending),
    // Stage 5a: FP CSR interface
    .fflags_delta_i (fpu_out_valid ? fpu_fflags : 5'b0),
    .fflags_we_i    (fpu_out_valid),
    .fp_rd_we_i     (fp_we),                // drives mstatus.FS=11 on FP writeback
    .frm_o          (frm),
    // Zicntr: pulse once per retired instruction.  Count at the EX→MEM
    // transition so the count is visible to a csrrc-instret two instructions
    // later (matches the SAIL reference-model semantics used by ACT4).
    .instret_retire_i (ex_mem_en & id_ex_q.valid & ~combined_stall)
  );

  // STAGE4: 64-bit LSU with AXI4 interface and A-extension stubs.
  kronos_lsu u_lsu (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .req_i           (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store
                      | ex_mem_q.dec.is_amo) & ~mem_done_q),
    .we_i            (ex_mem_q.dec.is_store | ex_mem_q.dec.fp_store),
    .addr_i          (ex_mem_q.alu_result[31:0]),
    .wdata_i         (ex_mem_q.rs2_data),
    .funct3_i        (ex_mem_q.dec.mem_funct3),
    .rdata_o         (lsu_rdata),
    .valid_o         (lsu_valid),
    .mem_stall_o     (mem_stall),
    // Stage 5a: FP load/store ports
    .fp_dest_req_i   (ex_mem_q.valid &
                      (ex_mem_q.dec.fp_load | ex_mem_q.dec.fp_store) & ~mem_done_q),
    .fp_store_data_i (ex_mem_q.rs2_data),
    .fp_dest_rsp_o   (lsu_fp_dest),
    .fp_rdata_o      (lsu_fp_rdata),
    // A-extension stubs
    .is_lr_i         (ex_mem_q.dec.is_lr),
    .is_sc_i         (ex_mem_q.dec.is_sc),
    .is_amo_i        (ex_mem_q.dec.is_amo),
    .amo_funct5_i    (ex_mem_q.dec.amo_funct5),
    .amo_src_i       (ex_mem_q.rs2_data),
    .sc_success_o    (),
    .axi_req_o       (data_req),
    .axi_rsp_i       (data_rsp)
  );

  assign data_axi_req_o = data_req;
  assign data_rsp       = data_axi_rsp_i;

  // Stage 5a: FPU top
  assign fpu_tag_in = '{rd: id_ex_q.dec.rd, fp_dest: id_ex_q.dec.rd_fp};

  kronos_fpu_top u_fpu (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (1'b0),
    .in_valid_i (id_ex_q.valid & id_ex_q.dec.is_fp &
                 ~id_ex_q.dec.fp_load & ~id_ex_q.dec.fp_store &
                 ~fpu_dispatched_q),
    .op_i       (id_ex_q.dec.fp_op),
    .fmt_d_i    (id_ex_q.dec.fmt_d),
    .rm_i       (id_ex_q.dec.rm_resolved),
    .a_i        (fpu_a_i),
    .b_i        (fpu_b_i),
    .c_i        (id_ex_q.rs3_data),
    .tag_i      (fpu_tag_in),
    .busy_o     (fpu_busy),
    .out_valid_o(fpu_out_valid),
    .result_o   (fpu_result),
    .fflags_o   (fpu_fflags),
    .tag_o      (fpu_tag_out)
  );

  // FPU dispatch / inflight tracking
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fp_inflight_q    <= 1'b0;
      fpu_dispatched_q <= 1'b0;
    end else begin
      // Dispatch: fire once per FP arithmetic instruction in EX
      if (id_ex_q.valid & id_ex_q.dec.is_fp &
          ~id_ex_q.dec.fp_load & ~id_ex_q.dec.fp_store &
          ~fpu_dispatched_q & ~fpu_busy) begin
        fp_inflight_q    <= 1'b1;
        fpu_dispatched_q <= 1'b1;
      end

      // Clear dispatch guard when EX advances (instruction leaves EX)
      if (ex_mem_en & ~combined_stall) begin
        fpu_dispatched_q <= 1'b0;
      end

      // Clear inflight when FPU result arrives; the result is forwarded
      // into mem_wb_q.alu_result at the same posedge (see mem_wb_q block).
      if (fpu_out_valid) begin
        fp_inflight_q <= 1'b0;
      end
    end
  end

  // FPU result latch: captures fpu_result when fpu_out_valid fires.
  // Cleared when the FP instruction actually leaves EX (pipeline advances).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fp_result_valid_q <= 1'b0;
      fp_result_q       <= '0;
      fp_tag_q          <= '0;
    end else begin
      if (fpu_out_valid & combined_stall) begin
        // Latch only when pipeline is stalled: result would otherwise be lost.
        fp_result_valid_q <= 1'b1;
        fp_result_q       <= fpu_result;
        fp_tag_q          <= fpu_tag_out;
      end else if (fp_result_valid_q & ~combined_stall) begin
        // Pipeline is advancing: FP instruction leaves EX, result consumed.
        fp_result_valid_q <= 1'b0;
      end
    end
  end

  // FP regfile write-port mux
  // Priority: FP load (MEM stage) > FP arithmetic WB
  always_comb begin
    fp_we = 1'b0;
    fp_wa = '0;
    fp_wd = '0;

    if (lsu_valid & ex_mem_q.valid & ex_mem_q.dec.fp_load) begin
      // FP load: write NaN-boxed data directly
      fp_we = 1'b1;
      fp_wa = ex_mem_q.dec.rd;
      fp_wd = lsu_fp_rdata;
    end else if (mem_wb_q.valid & mem_wb_q.dec.is_fp &
                 mem_wb_q.dec.rd_fp & ~mem_wb_q.dec.fp_load) begin
      // FP arithmetic result: captured in alu_result at the MEM/WB boundary.
      fp_we = 1'b1;
      fp_wa = mem_wb_q.dec.rd;
      fp_wd = mem_wb_q.alu_result;
    end
  end

  kronos_align u_align (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .rdata_i             (instr_axi_rsp_i.r.data),
    .rvalid_i            ((fetch_state_q == FETCH_WAIT_R) & instr_axi_rsp_i.r_valid
                        & ~fetch_stale_q),
    .stall_i             (align_instr_valid & ~if_id_en),
    .flush_i             (fetch_flush),
    .pc_offset_i         (mem_redirect ? ex_mem_q.pc_next[1]
                        : ex_redirect  ? ex_pc_next[1]
                        : pred_taken   ? pred_target[1]
                        :                pc_q[1]),
    .instr_o             (align_instr),
    .instr_valid_o       (align_instr_valid),
    .is_16b_o            (align_is_16b),
    .align_stall_o       (align_stall),
    .align_need_upper_o  (align_need_upper),
    .align_needs_fetch_o (align_needs_fetch)
  );

  kronos_bpred u_bpred (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .pc_i            (pc_q),
    .pred_taken_o    (pred_taken),
    .pred_target_o   (pred_target),
    .upd_valid_i     (bpred_update_en),
    .upd_pc_i        (id_ex_q.pc),
    .upd_taken_i     (actual_taken),
    .upd_target_i    (ex_pc_next),
    .upd_is_jal_i    (id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr)
  );

  // =========================================================================
  // PC register
  // =========================================================================
  // Priority: mem_redirect before ex_redirect so that when both fire simultaneously
  // (MEM-stage target mismatch + speculative instr in EX also generates a redirect),
  // the pipeline returns to the architecturally correct target from the MEM branch.
  assign pc_next = mem_redirect  ? ex_mem_q.pc_next
                 : ex_redirect   ? ex_pc_next
                 : pred_taken    ? pred_target
                 : align_is_16b  ? pc_q + 32'd2
                 :                 pc_q + 32'd4;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pc_q <= boot_addr_i;
    else if (pc_en) pc_q <= pc_next;
  end

  // =========================================================================
  // IF stage — 2-state fetch FSM (identical to stage3)
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_state_q <= FETCH_IDLE;
    end else begin
      unique case (fetch_state_q)
        FETCH_IDLE: begin
          if (instr_axi_req_o.ar_valid & instr_axi_rsp_i.ar_ready)
            fetch_state_q <= FETCH_WAIT_R;
        end
        FETCH_WAIT_R:
          if (instr_axi_rsp_i.r_valid) fetch_state_q <= FETCH_IDLE;
        default: fetch_state_q <= FETCH_IDLE;
      endcase
    end
  end

  always_comb begin
    instr_axi_req_o            = '0;
    unique case (fetch_state_q)
      FETCH_IDLE: begin
        instr_axi_req_o.ar_valid  = rst_ni & align_needs_fetch;
        instr_axi_req_o.ar.addr   = align_need_upper
          ? {pc_q[31:2] + 30'd1, 2'b00}
          : {pc_q[31:2], 2'b00};
        instr_axi_req_o.ar.size   = 3'b010;
        instr_axi_req_o.ar.burst  = axi_pkg::BURST_INCR;
      end
      FETCH_WAIT_R: begin
        instr_axi_req_o.r_ready   = 1'b1;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if_id_q <= '0;
    end else if (if_id_flush) begin
      if_id_q <= '0;
    end else if (if_id_en) begin
      if_id_q.pc          <= pc_q;
      if_id_q.instr       <= align_instr;
      if_id_q.valid       <= align_instr_valid;
      if_id_q.is_16b      <= align_is_16b;
      if_id_q.pred_taken  <= pred_taken & ~ex_redirect;
      if_id_q.pred_target <= pred_target;
    end
  end

  // =========================================================================
  // ID stage
  // =========================================================================

  // Fix #2: two-level ID forwarding structure.
  //
  // FP path: compute a 2-bit one-hot selector independently of data, then use
  // a balanced 4-way unique-case mux.  Separating condition evaluation from
  // data selection reduces the path from ~10–12 LUT levels to ~4–5 LUT levels.
  //
  // Integer path: drop the 0-gap EX bypass and 1-gap MEM bypass from ID.
  // Those cases are already handled by fwd_rs1_sel = FWD_EXMEM / FWD_MEMWB
  // in the EX-stage forwarding mux (correct because the producer is in
  // ex_mem_q / mem_wb_q when the consumer reaches EX).  Only the 3-gap WB
  // bypass is kept here (the producer has retired by the time the consumer
  // reaches EX, so no EX mux can help).

  // FP selector encoding: 2'd0 = FPU result, 2'd1 = EX/MEM FP, 2'd2 = WB FP,
  //                       2'd3 = FP regfile.
  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_dec.rs1))
      fp_rs1_sel = 2'd0;
    else if (ex_mem_q.valid & ex_mem_q.dec.is_fp & ex_mem_q.dec.rd_fp &
             ~ex_mem_q.dec.fp_load & (ex_mem_q.dec.rd == id_dec.rs1))
      fp_rs1_sel = 2'd1;
    else if (fp_we & (fp_wa == id_dec.rs1))
      fp_rs1_sel = 2'd2;
    else
      fp_rs1_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs1_sel)
      2'd0:    fp_rs1_data_id = fp_result_cur;
      2'd1:    fp_rs1_data_id = ex_mem_q.alu_result;
      2'd2:    fp_rs1_data_id = fp_wd;
      default: fp_rs1_data_id = fp_rd1;
    endcase
  end

  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_dec.rs2))
      fp_rs2_sel = 2'd0;
    else if (ex_mem_q.valid & ex_mem_q.dec.is_fp & ex_mem_q.dec.rd_fp &
             ~ex_mem_q.dec.fp_load & (ex_mem_q.dec.rd == id_dec.rs2))
      fp_rs2_sel = 2'd1;
    else if (fp_we & (fp_wa == id_dec.rs2))
      fp_rs2_sel = 2'd2;
    else
      fp_rs2_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs2_sel)
      2'd0:    fp_rs2_data_id = fp_result_cur;
      2'd1:    fp_rs2_data_id = ex_mem_q.alu_result;
      2'd2:    fp_rs2_data_id = fp_wd;
      default: fp_rs2_data_id = fp_rd2;
    endcase
  end

  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_dec.rs3))
      fp_rs3_sel = 2'd0;
    else if (ex_mem_q.valid & ex_mem_q.dec.is_fp & ex_mem_q.dec.rd_fp &
             ~ex_mem_q.dec.fp_load & (ex_mem_q.dec.rd == id_dec.rs3))
      fp_rs3_sel = 2'd1;
    else if (fp_we & (fp_wa == id_dec.rs3))
      fp_rs3_sel = 2'd2;
    else
      fp_rs3_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs3_sel)
      2'd0:    fp_rs3_data_id = fp_result_cur;
      2'd1:    fp_rs3_data_id = ex_mem_q.alu_result;
      2'd2:    fp_rs3_data_id = fp_wd;
      default: fp_rs3_data_id = fp_rd3;
    endcase
  end

  // Integer path: WB bypass (3-gap) or register file.
  // rd_wen guards against B/S-type encodings where instr[11:7] is an
  // immediate, not a real destination register.
  assign int_rs1_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs1)
                           ? wb_result_64 : rs1_rdata_64;
  assign int_rs2_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs2)
                           ? wb_result_64 : rs2_rdata_64;

  // Final operand mux: FP or integer.  FP and integer paths are mutually
  // exclusive on rs1_fp / rs2_fp — one more LUT level added here.
  assign rs1_data_id = id_dec.rs1_fp ? fp_rs1_data_id : int_rs1_data_id;
  assign rs2_data_id = id_dec.rs2_fp ? fp_rs2_data_id : int_rs2_data_id;
  assign rs3_data_id = fp_rs3_data_id;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_ex_q <= '0;
    end else if (id_ex_flush) begin
      id_ex_q <= '0;
    end else if (id_ex_en) begin
      id_ex_q.pc          <= if_id_q.pc;
      id_ex_q.dec         <= id_dec;
      id_ex_q.rs1_data    <= rs1_data_id;
      id_ex_q.rs2_data    <= rs2_data_id;
      id_ex_q.rs3_data    <= rs3_data_id;
      id_ex_q.valid       <= if_id_q.valid;
      id_ex_q.is_16b      <= if_id_q.is_16b;
      id_ex_q.pred_taken  <= if_id_q.pred_taken;
      id_ex_q.pred_target <= if_id_q.pred_target;
      id_ex_q.fwd_rs1_sel <= fwd_rs1_sel;
      id_ex_q.fwd_rs2_sel <= fwd_rs2_sel;
    end
  end

  // =========================================================================
  // EX stage — 64-bit forwarding mux
  // =========================================================================

  // Fix #3: use pre-registered ex_mem_csr_q instead of the 3-bit wb_sel
  // comparison inline.  Removes one combinational level from the FWD_EXMEM
  // data path (critical for every instruction that uses a forwarded operand).
  always_comb begin
    unique case (id_ex_q.fwd_rs1_sel)
      FWD_NONE:  fwd_rs1_data = id_ex_q.rs1_data;
      FWD_EXMEM: fwd_rs1_data = ex_mem_csr_q ? ex_mem_q.csr_rdata : ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs1_data = wb_result_64;
      default:   fwd_rs1_data = id_ex_q.rs1_data;
    endcase
    unique case (id_ex_q.fwd_rs2_sel)
      FWD_NONE:  fwd_rs2_data = id_ex_q.rs2_data;
      FWD_EXMEM: fwd_rs2_data = ex_mem_csr_q ? ex_mem_q.csr_rdata : ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs2_data = wb_result_64;
      default:   fwd_rs2_data = id_ex_q.rs2_data;
    endcase
  end

  // ALU operand formation — PC zero-extends to 64, imm sign-extends to 64.
  assign alu_a = id_ex_q.dec.use_pc  ? {32'b0, id_ex_q.pc}
                                     : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? {{32{id_ex_q.dec.imm[31]}}, id_ex_q.dec.imm}
                                     : fwd_rs2_data;

  // FPU operand forwarding: for FP instructions with integer-source operands
  // (FMV.W.X, FMV.D.X), apply EX integer forwarding so a producer one or two
  // stages ahead is bypassed correctly.  FP-source operands were already
  // forwarded via the fpu_out_valid bypass in the ID-stage rs1/2_data_id mux.
  assign fpu_a_i = id_ex_q.dec.rs1_fp ? id_ex_q.rs1_data : fwd_rs1_data;
  assign fpu_b_i = id_ex_q.dec.rs2_fp ? id_ex_q.rs2_data : fwd_rs2_data;

  // 64-bit branch comparison
  always_comb begin
    branch_taken = 1'b0;
    if (id_ex_q.valid & id_ex_q.dec.is_branch) begin
      unique case (id_ex_q.dec.branch_funct3)
        3'b000:  branch_taken = (fwd_rs1_data == fwd_rs2_data);
        3'b001:  branch_taken = (fwd_rs1_data != fwd_rs2_data);
        3'b100:  branch_taken = ($signed(fwd_rs1_data) <  $signed(fwd_rs2_data));
        3'b101:  branch_taken = ($signed(fwd_rs1_data) >= $signed(fwd_rs2_data));
        3'b110:  branch_taken = (fwd_rs1_data <  fwd_rs2_data);
        3'b111:  branch_taken = (fwd_rs1_data >= fwd_rs2_data);
        default: branch_taken = 1'b0;
      endcase
    end
  end

  always_comb begin
    if      (irq_pending)          trap_cause = 32'h8000_0007;
    else if (id_ex_q.dec.illegal)  trap_cause = 32'd2;
    else if (id_ex_q.dec.is_ecall) trap_cause = 32'd11;
    else                           trap_cause = 32'd3;
  end

  // JALR target: 64-bit add, truncate to 32-bit PC (physical PC is 32-bit).
  assign jalr_target_64 = (fwd_rs1_data + {{32{id_ex_q.dec.imm[31]}}, id_ex_q.dec.imm})
                           & ~64'd1;

  always_comb begin
    if      (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                               id_ex_q.dec.illegal  | irq_pending))
      ex_pc_next = trap_vector[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_mret)
      ex_pc_next = mepc[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_jalr)
      ex_pc_next = jalr_target_64[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_jal)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else if (branch_taken)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else
      ex_pc_next = id_ex_q.is_16b ? id_ex_q.pc + 32'd2 : id_ex_q.pc + 32'd4;
  end

  // STAGE3: branch predictor — misprediction detection and update
  assign is_branch_or_jump = id_ex_q.dec.is_branch | id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr;
  assign actual_taken      = branch_taken | id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr;

  // Direction-only misprediction: taken/not-taken disagrees with prediction.
  // Target misprediction (both predicted and actually taken, but wrong target)
  // is deferred to the MEM stage (bpred_mispredict_target) so that the JALR
  // target adder and the 32-bit comparator are removed from the ex_redirect
  // combinational path.
  assign bpred_mispredict = id_ex_q.valid & (
    (id_ex_q.pred_taken & ~actual_taken) |
    (~id_ex_q.pred_taken & actual_taken)
  );

  // Suppress BTB update from the speculative instruction in EX when mem_redirect fires.
  assign bpred_update_en = id_ex_q.valid & ex_mem_en & is_branch_or_jump & ~mem_redirect;

  assign ex_redirect = bpred_mispredict |
    (id_ex_q.valid &
     (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak | id_ex_q.dec.illegal |
      irq_pending | id_ex_q.dec.is_mret));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ex_mem_csr_q <= 1'b0;
    else if (ex_mem_en) ex_mem_csr_q <= (id_ex_q.dec.wb_sel == WB_CSR);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '0;
    end else if (ex_mem_en) begin
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.dec        <= id_ex_q.dec;
      // For FP arithmetic instructions, use fp_result_cur (either just-fired
      // fpu_result or the latched fp_result_q).  The pipeline only advances
      // here when combined_stall=0, which requires fp_result_avail=1, so
      // fp_result_cur is always valid for FP instructions at this point.
      ex_mem_q.alu_result <= (id_ex_q.valid & id_ex_q.dec.is_fp &
                              ~id_ex_q.dec.fp_load & ~id_ex_q.dec.fp_store)
                             ? fp_result_cur : ex_result;
      ex_mem_q.rs2_data   <= fwd_rs2_data;
      ex_mem_q.pc_next    <= ex_pc_next;
      ex_mem_q.csr_rdata  <= csr_rdata;
      ex_mem_q.redirect    <= ex_redirect;
      // When mem_redirect fires, the instruction currently in EX (id_ex_q) was
      // fetched from the wrong BTB target. Invalidate it so it cannot trigger
      // the LSU, WB, or bpred_mispredict_target on the next cycle.
      ex_mem_q.valid       <= (id_ex_q.valid & ~irq_pending) & ~mem_redirect;
      ex_mem_q.is_16b      <= id_ex_q.is_16b;
      ex_mem_q.pred_taken  <= id_ex_q.pred_taken;
      ex_mem_q.pred_target <= id_ex_q.pred_target;
    end
  end

  // MEM-stage target misprediction: predictor predicted taken with the right
  // direction (so EX did not redirect), but the predicted target was wrong.
  // Both ex_mem_q.pc_next and ex_mem_q.pred_target are registered, so this
  // comparison sits on a short path. Guard with ~ex_mem_q.redirect: if EX
  // already redirected (direction mismatch or trap), no second redirect needed.
  assign bpred_mispredict_target = ex_mem_q.valid & ~ex_mem_q.redirect &
    ex_mem_q.pred_taken & (ex_mem_q.pred_target != ex_mem_q.pc_next);
  assign mem_redirect = bpred_mispredict_target;

  // Any flush that redirects the fetch stream.
  assign fetch_flush = if_id_flush | (pred_taken & pc_en & ~ex_redirect & ~mem_redirect);

  // Stale-fetch tracking: mark an in-flight AR as stale when a redirect fires.
  // Two cases:
  //   (a) FETCH_IDLE + AR accepted + flush this cycle: the AR just accepted
  //       carries old pc_q; redirect target is already latched by kronos_align.
  //   (b) FETCH_WAIT_R + flush before r_valid: redirect fired mid-wait.
  // In both cases the eventual r_valid must be drained without forwarding.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_stale_q <= 1'b0;
    end else begin
      if ((fetch_state_q == FETCH_IDLE &&
           instr_axi_req_o.ar_valid && instr_axi_rsp_i.ar_ready && fetch_flush) ||
          (fetch_state_q == FETCH_WAIT_R && fetch_flush && !instr_axi_rsp_i.r_valid))
        fetch_stale_q <= 1'b1;
      else if (fetch_stale_q && instr_axi_rsp_i.r_valid)
        fetch_stale_q <= 1'b0;
    end
  end

  // =========================================================================
  // MEM stage — mem_done_q / lsu_rdata_latch handle pipeline stall bridging
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_done_q      <= 1'b0;
      lsu_rdata_latch <= '0;
    end else begin
      if (lsu_valid) begin
        mem_done_q      <= 1'b1;
        lsu_rdata_latch <= lsu_rdata;
      end
      if (mem_wb_en) begin
        mem_done_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '0;
    end else if (mem_wb_en) begin
      mem_wb_q.dec        <= ex_mem_q.dec;
      // fpu_result was already captured into ex_mem_q.alu_result at the
      // EX→MEM boundary (when fpu_out_valid fired while the FP instruction
      // was stalled in EX).  Simply pass it through here.
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.lsu_rdata  <= lsu_valid ? lsu_rdata : lsu_rdata_latch;
      mem_wb_q.csr_rdata  <= ex_mem_q.csr_rdata;
      mem_wb_q.pc4        <= ex_mem_q.pc + (ex_mem_q.is_16b ? 32'd2 : 32'd4);
      mem_wb_q.valid      <= ex_mem_q.valid;
    end
  end

  // =========================================================================
  // WB→ID bypass (64-bit, integer only)
  // =========================================================================
  assign wb_writing = mem_wb_q.valid & mem_wb_q.dec.rd_wen
                      & (mem_wb_q.dec.rd != 5'd0) & ~mem_wb_q.dec.rd_fp;

  // =========================================================================
  // WB stage (64-bit)
  // =========================================================================
  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result_64 = mem_wb_q.alu_result;
      WB_MEM:  wb_result_64 = mem_wb_q.lsu_rdata;
      WB_PC4:  wb_result_64 = {32'b0, mem_wb_q.pc4};
      WB_CSR:  wb_result_64 = mem_wb_q.csr_rdata;
      default: wb_result_64 = mem_wb_q.alu_result;
    endcase

    // FP→int instructions (FCVT.W.S, FMV.X.W, FCLASS, FEQ, FLT, FLE) set
    // wb_sel = WB_ALU and mem_wb_q.alu_result holds fpu_result (captured at
    // the MEM/WB boundary above), so wb_result_64 is correct without an
    // explicit override here.
  end

endmodule
