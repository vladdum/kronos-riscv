// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage4) — 5-stage in-order pipeline widened to RV64IMAC.
// Mirrors the stage3 top but uses 64-bit datapath components:
//   * kronos_alu / kronos_muldiv support word_op_i (W-suffix instructions)
//   * kronos_csr is 64-bit
//   * kronos_lsu supports 64-bit loads/stores (LD/SD/LWU) and A-extension stubs
// Reuses: kronos_regfile (stage0, already 64-bit), kronos_forward/hazard
//         (stage1), kronos_align/kronos_bpred (stage3) unchanged.
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
  logic [63:0]    rs1_data_id, rs2_data_id;
  logic           wb_writing;

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

  // STAGE3: fetch FSM
  typedef enum logic { FETCH_IDLE = 1'b0, FETCH_WAIT_R = 1'b1 } fetch_state_e;
  fetch_state_e fetch_state_q;
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
  logic        is_branch_or_jump;

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

  // -------------------------------------------------------------------------
  // WB-stage wires (64-bit)
  // -------------------------------------------------------------------------
  logic [63:0] wb_result_64;

  // -------------------------------------------------------------------------
  // PC next (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] pc_next;

  // =========================================================================
  // Submodule instantiations
  // =========================================================================

  kronos_decode u_decode (
    .instr_i (if_id_q.instr),
    .dec_o   (id_dec)
  );

  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (id_dec.rs1),
    .rs2_addr_i  (id_dec.rs2),
    .rs1_rdata_o (rs1_rdata_64),
    .rs2_rdata_o (rs2_rdata_64),
    .rd_addr_i   (mem_wb_q.dec.rd),
    .rd_wen_i    (mem_wb_q.valid & mem_wb_q.dec.rd_wen),
    .rd_wdata_i  (wb_result_64)
  );

  kronos_forward u_forward (
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs2_i      (id_dec.rs2),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_rd_wen_i   (id_ex_q.dec.rd_wen & id_ex_q.valid),
    .id_ex_is_load_i  (id_ex_q.dec.wb_sel == WB_MEM),
    .ex_mem_rd_i      (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i  (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .fwd_rs1_sel_o    (fwd_rs1_sel),
    .fwd_rs2_sel_o    (fwd_rs2_sel)
  );

  // STAGE3: combined_stall — mem_stall | muldiv_stall | instr_fetch_stall
  assign muldiv_stall      = id_ex_q.valid & id_ex_q.dec.is_muldiv & ~muldiv_valid;
  assign instr_fetch_stall = ~align_instr_valid;
  assign combined_stall    = mem_stall | muldiv_stall | instr_fetch_stall;

  kronos_hazard u_hazard (
    .id_ex_is_load_i  (id_ex_q.dec.is_load),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_valid_i    (id_ex_q.valid),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .if_id_rs2_i          (id_dec.rs2),
    .id_ex_is_fp_load_i   ('0),
    .if_id_rs1_fp_i       ('0),
    .if_id_rs2_fp_i       ('0),
    .if_id_rs3_fp_i       ('0),
    .if_id_rs3_i          (5'd0),
    .ex_redirect_i        (ex_redirect),
    .mem_stall_i          (combined_stall),
    .pc_en_o              (pc_en),
    .if_id_en_o           (if_id_en),
    .id_ex_en_o           (id_ex_en),
    .ex_mem_en_o          (ex_mem_en),
    .mem_wb_en_o          (mem_wb_en),
    .if_id_flush_o        (if_id_flush),
    .id_ex_flush_o        (id_ex_flush)
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
    .req_i     (id_ex_q.valid & id_ex_q.dec.is_muldiv & muldiv_idle & ~mem_stall),
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

  // MISA_EXT = I + M + A + C extension bits (bit 8, 12, 0, 2) = 26'h1105
  kronos_csr #(.MISA_EXT(26'h1105)) u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (id_ex_q.valid & id_ex_q.dec.is_csr),
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
    .irq_pending_o (irq_pending)
  );

  // STAGE4: 64-bit LSU with AXI4 interface and A-extension stubs.
  kronos_lsu u_lsu (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .req_i        (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store
                   | ex_mem_q.dec.is_amo) & ~mem_done_q),
    .we_i         (ex_mem_q.dec.is_store),
    .addr_i       (ex_mem_q.alu_result[31:0]),
    .wdata_i      (ex_mem_q.rs2_data),
    .funct3_i     (ex_mem_q.dec.mem_funct3),
    .rdata_o      (lsu_rdata),
    .valid_o      (lsu_valid),
    .mem_stall_o  (mem_stall),
    .is_lr_i      (ex_mem_q.dec.is_lr),
    .is_sc_i      (ex_mem_q.dec.is_sc),
    .is_amo_i     (ex_mem_q.dec.is_amo),
    .amo_funct5_i (ex_mem_q.dec.amo_funct5),
    .amo_src_i    (ex_mem_q.rs2_data),
    .sc_success_o (),
    .axi_req_o    (data_req),
    .axi_rsp_i    (data_rsp)
  );

  assign data_axi_req_o = data_req;
  assign data_rsp       = data_axi_rsp_i;

  kronos_align u_align (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .rdata_i             (instr_axi_rsp_i.r.data),
    .rvalid_i            ((fetch_state_q == FETCH_WAIT_R) & instr_axi_rsp_i.r_valid),
    .stall_i             (align_instr_valid & ~if_id_en),
    .flush_i             (if_id_flush | (pred_taken & pc_en & ~ex_redirect)),
    .pc_offset_i         (ex_redirect ? ex_pc_next[1]
                        : pred_taken  ? pred_target[1]
                        :               pc_q[1]),
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
  assign pc_next = ex_redirect   ? ex_pc_next
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
    if (!rst_ni) fetch_state_q <= FETCH_IDLE;
    else begin
      unique case (fetch_state_q)
        FETCH_IDLE:
          if (instr_axi_req_o.ar_valid & instr_axi_rsp_i.ar_ready)
            fetch_state_q <= FETCH_WAIT_R;
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
  always_comb begin
    unique case (id_ex_q.fwd_rs1_sel)
      FWD_NONE:  fwd_rs1_data = id_ex_q.rs1_data;
      FWD_EXMEM: fwd_rs1_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs1_data = wb_result_64;
      default:   fwd_rs1_data = id_ex_q.rs1_data;
    endcase
    unique case (id_ex_q.fwd_rs2_sel)
      FWD_NONE:  fwd_rs2_data = id_ex_q.rs2_data;
      FWD_EXMEM: fwd_rs2_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs2_data = wb_result_64;
      default:   fwd_rs2_data = id_ex_q.rs2_data;
    endcase
  end

  // ALU operand formation — PC zero-extends to 64, imm sign-extends to 64.
  assign alu_a = id_ex_q.dec.use_pc  ? {32'b0, id_ex_q.pc}
                                     : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? {{32{id_ex_q.dec.imm[31]}}, id_ex_q.dec.imm}
                                     : fwd_rs2_data;

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

  assign bpred_mispredict = id_ex_q.valid & (
    (id_ex_q.pred_taken & ~actual_taken) |
    (~id_ex_q.pred_taken & actual_taken) |
    (id_ex_q.pred_taken & actual_taken & (id_ex_q.pred_target != ex_pc_next))
  );

  assign bpred_update_en = id_ex_q.valid & ex_mem_en & is_branch_or_jump;

  assign ex_redirect = bpred_mispredict |
    (id_ex_q.valid &
     (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak | id_ex_q.dec.illegal |
      irq_pending | id_ex_q.dec.is_mret));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '0;
    end else if (ex_mem_en) begin
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.dec        <= id_ex_q.dec;
      ex_mem_q.alu_result <= ex_result;
      ex_mem_q.rs2_data   <= fwd_rs2_data;
      ex_mem_q.pc_next    <= ex_pc_next;
      ex_mem_q.csr_rdata  <= csr_rdata;
      ex_mem_q.redirect   <= ex_redirect;
      ex_mem_q.valid      <= id_ex_q.valid & ~irq_pending;
      ex_mem_q.is_16b     <= id_ex_q.is_16b;
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
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.lsu_rdata  <= lsu_valid ? lsu_rdata : lsu_rdata_latch;
      mem_wb_q.csr_rdata  <= ex_mem_q.csr_rdata;
      mem_wb_q.pc4        <= ex_mem_q.pc + (ex_mem_q.is_16b ? 32'd2 : 32'd4);
      mem_wb_q.valid      <= ex_mem_q.valid;
    end
  end

  // =========================================================================
  // WB→ID bypass (64-bit)
  // =========================================================================
  assign wb_writing  = mem_wb_q.valid & mem_wb_q.dec.rd_wen & (mem_wb_q.dec.rd != 5'd0);
  assign rs1_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs1)
                         ? wb_result_64 : rs1_rdata_64;
  assign rs2_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs2)
                         ? wb_result_64 : rs2_rdata_64;

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
  end

endmodule
