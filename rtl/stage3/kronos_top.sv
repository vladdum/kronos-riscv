// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage3) — 5-stage in-order pipeline with RV32M and AXI4 bus.
// Replaces OBI ports with native AXI4 master ports.
// Reuses stage0: kronos_regfile, kronos_alu, kronos_csr
// Reuses stage1: kronos_forward, kronos_hazard
// Reuses stage2: kronos_decode (RV32I+M), kronos_muldiv
// New in stage3:  kronos_lsu (AXI4 FSM), fetch FSM in kronos_top
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
  logic [31:0]    rs1_data_id, rs2_data_id;
  logic           wb_writing;

  // -------------------------------------------------------------------------
  // EX-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] fwd_rs1_data, fwd_rs2_data;
  logic [31:0] alu_a, alu_b, alu_result;
  logic [31:0] ex_result;
  logic [31:0] ex_pc_next;
  logic        ex_redirect;
  logic        branch_taken;
  logic        irq_pending;
  logic [31:0] csr_rdata, trap_vector, mepc;
  logic [31:0] trap_cause;

  // STAGE2: muldiv signals
  logic [31:0] muldiv_result;
  logic        muldiv_valid, muldiv_idle;
  logic        muldiv_stall;

  // STAGE3: fetch FSM
  typedef enum logic { FETCH_IDLE = 1'b0, FETCH_WAIT_R = 1'b1 } fetch_state_e;
  fetch_state_e fetch_state_q;
  logic         instr_fetch_stall;
  logic         combined_stall;

  // -------------------------------------------------------------------------
  // MEM-stage wires
  // -------------------------------------------------------------------------
  logic [31:0]      lsu_rdata;
  logic             lsu_valid;
  logic             mem_stall;
  // mem_done_q: set when LSU signals valid_o; cleared when MEM/WB register
  // advances.  Gates req_i so LSU does not re-issue while the pipeline is
  // frozen by instr_fetch_stall.
  logic             mem_done_q;
  logic [31:0]      lsu_rdata_latch;  // holds rdata across the stall gap
  kronos_axi_req_t  data_req;
  kronos_axi_resp_t data_rsp;

  // -------------------------------------------------------------------------
  // WB-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] wb_result;
  logic [63:0] wb_result_64;

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
    .id_ex_rs1_i      (id_ex_q.dec.rs1),
    .id_ex_rs1_used_i (id_ex_q.dec.rs1_used),
    .id_ex_rs2_i      (id_ex_q.dec.rs2),
    .id_ex_rs2_used_i (id_ex_q.dec.rs2_used),
    .ex_mem_rd_i      (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i  (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .ex_mem_is_load_i (ex_mem_q.dec.is_load),
    .mem_wb_rd_i      (mem_wb_q.dec.rd),
    .mem_wb_rd_wen_i  (mem_wb_q.dec.rd_wen & mem_wb_q.valid),
    .fwd_rs1_sel_o    (fwd_rs1_sel),
    .fwd_rs2_sel_o    (fwd_rs2_sel)
  );

  // STAGE3: combined_stall — mem_stall | muldiv_stall | instr_fetch_stall
  assign muldiv_stall      = id_ex_q.valid & id_ex_q.dec.is_muldiv & ~muldiv_valid;
  // instr_fetch_stall: deasserts only on the cycle r_valid fires in FETCH_WAIT_R.
  assign instr_fetch_stall = ~(fetch_state_q == FETCH_WAIT_R && instr_axi_rsp_i.r_valid);
  assign combined_stall    = mem_stall | muldiv_stall | instr_fetch_stall;

  kronos_hazard u_hazard (
    .id_ex_is_load_i  (id_ex_q.dec.is_load),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_valid_i    (id_ex_q.valid),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .if_id_rs2_i      (id_dec.rs2),
    .ex_redirect_i    (ex_redirect),
    .mem_stall_i      (combined_stall),
    .pc_en_o          (pc_en),
    .if_id_en_o       (if_id_en),
    .id_ex_en_o       (id_ex_en),
    .ex_mem_en_o      (ex_mem_en),
    .mem_wb_en_o      (mem_wb_en),
    .if_id_flush_o    (if_id_flush),
    .id_ex_flush_o    (id_ex_flush)
  );

  kronos_alu u_alu (
    .op_i     (id_ex_q.dec.alu_op),
    .a_i      (alu_a),
    .b_i      (alu_b),
    .result_o (alu_result)
  );

  kronos_muldiv u_muldiv (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .req_i    (id_ex_q.valid & id_ex_q.dec.is_muldiv & muldiv_idle & ~mem_stall),
    .op_i     (id_ex_q.dec.muldiv_op),
    .a_i      (fwd_rs1_data),
    .b_i      (fwd_rs2_data),
    .result_o (muldiv_result),
    .busy_o   (),
    .valid_o  (muldiv_valid),
    .idle_o   (muldiv_idle)
  );

  assign ex_result = id_ex_q.dec.is_muldiv ? muldiv_result : alu_result;

  kronos_csr #(.MISA_EXT(26'h1100)) u_csr (
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
    // Gate trap_i and mret_i with ~combined_stall: the CSR must only update state
    // (MEPC, MCAUSE, mstatus.MIE) when the pipeline is actually advancing.
    // When combined_stall=1 (e.g. instr_fetch_stall active), the pipeline is frozen
    // and no redirect occurs, so processing trap_i would clear MIE without the
    // handler ever running.
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

  // STAGE3: LSU with AXI4 interface.
  // mem_done_q gates req_i to prevent re-issue while the pipeline is frozen
  // by instr_fetch_stall after a data response has already been received.
  kronos_lsu u_lsu (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store) & ~mem_done_q),
    .we_i        (ex_mem_q.dec.is_store),
    .addr_i      (ex_mem_q.alu_result),
    .wdata_i     (ex_mem_q.rs2_data),
    .funct3_i    (ex_mem_q.dec.mem_funct3),
    .rdata_o     (lsu_rdata),
    .valid_o     (lsu_valid),
    .mem_stall_o (mem_stall),
    .axi_req_o   (data_req),
    .axi_rsp_i   (data_rsp)
  );

  assign data_axi_req_o = data_req;
  assign data_rsp       = data_axi_rsp_i;

  // =========================================================================
  // PC register
  // =========================================================================
  logic [31:0] pc_next;
  assign pc_next = ex_redirect ? ex_pc_next : pc_q + 32'd4;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pc_q <= boot_addr_i;
    else if (pc_en) pc_q <= pc_next;
  end

  // =========================================================================
  // IF stage — 2-state fetch FSM
  // =========================================================================
  // IDLE:      drive ar_valid=1, ar_addr=pc_q.  Transition to FETCH_WAIT_R on ar_ready.
  // FETCH_WAIT_R: drive r_ready=1.  Transition to IDLE on r_valid.
  //
  // instr_fetch_stall deasserts only on the cycle r_valid fires (FETCH_WAIT_R).
  // The PC and pipeline are frozen in all other cycles.

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) fetch_state_q <= FETCH_IDLE;
    else begin
      unique case (fetch_state_q)
        FETCH_IDLE:   if (instr_axi_rsp_i.ar_ready)  fetch_state_q <= FETCH_WAIT_R;
        FETCH_WAIT_R: if (instr_axi_rsp_i.r_valid)   fetch_state_q <= FETCH_IDLE;
        default:      fetch_state_q <= FETCH_IDLE;
      endcase
    end
  end

  // Instr AXI4 request: ar_valid in IDLE, r_ready in FETCH_WAIT_R.
  // AW/W/B unused on instr port (read-only).
  always_comb begin
    instr_axi_req_o            = '0;
    unique case (fetch_state_q)
      FETCH_IDLE: begin
        instr_axi_req_o.ar_valid  = rst_ni;
        instr_axi_req_o.ar.addr   = pc_q;
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
      if_id_q.pc    <= pc_q;
      if_id_q.instr <= instr_axi_rsp_i.r.data;
      if_id_q.valid <= (fetch_state_q == FETCH_WAIT_R) & instr_axi_rsp_i.r_valid;
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
      id_ex_q.pc       <= if_id_q.pc;
      id_ex_q.dec      <= id_dec;
      id_ex_q.rs1_data <= rs1_data_id;
      id_ex_q.rs2_data <= rs2_data_id;
      id_ex_q.valid    <= if_id_q.valid;
    end
  end

  // =========================================================================
  // EX stage
  // =========================================================================
  always_comb begin
    unique case (fwd_rs1_sel)
      FWD_NONE:  fwd_rs1_data = id_ex_q.rs1_data;
      FWD_EXMEM: fwd_rs1_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs1_data = wb_result;
      default:   fwd_rs1_data = id_ex_q.rs1_data;
    endcase
    unique case (fwd_rs2_sel)
      FWD_NONE:  fwd_rs2_data = id_ex_q.rs2_data;
      FWD_EXMEM: fwd_rs2_data = ex_mem_q.alu_result;
      FWD_MEMWB: fwd_rs2_data = wb_result;
      default:   fwd_rs2_data = id_ex_q.rs2_data;
    endcase
  end

  assign alu_a = id_ex_q.dec.use_pc  ? id_ex_q.pc      : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? id_ex_q.dec.imm : fwd_rs2_data;

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
    if      (irq_pending)          trap_cause = 32'h80000007;
    else if (id_ex_q.dec.illegal)  trap_cause = 32'd2;
    else if (id_ex_q.dec.is_ecall) trap_cause = 32'd11;
    else                           trap_cause = 32'd3;
  end

  always_comb begin
    if      (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                               id_ex_q.dec.illegal  | irq_pending))
      ex_pc_next = trap_vector;
    else if (id_ex_q.valid & id_ex_q.dec.is_mret)
      ex_pc_next = mepc;
    else if (id_ex_q.valid & id_ex_q.dec.is_jalr)
      ex_pc_next = (fwd_rs1_data + id_ex_q.dec.imm) & ~32'd1;
    else if (id_ex_q.valid & id_ex_q.dec.is_jal)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else if (branch_taken)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else
      ex_pc_next = id_ex_q.pc + 32'd4;
  end

  assign ex_redirect = id_ex_q.valid &
    (id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr | branch_taken |
     id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak | id_ex_q.dec.illegal |
     id_ex_q.dec.is_mret  | irq_pending);

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
    end
  end

  // =========================================================================
  // MEM stage
  // =========================================================================
  // mem_done_q: prevents LSU re-issue while pipeline is frozen by instr_fetch_stall.
  // lsu_rdata_latch: holds the load data across the gap between data rvalid and
  // the next instr rvalid that allows the pipeline to advance.
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
        mem_done_q <= 1'b0;  // pipeline advanced — re-arm for next instruction
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '0;
    end else if (mem_wb_en) begin
      mem_wb_q.dec        <= ex_mem_q.dec;
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      // Use current rdata when LSU fires this cycle; use latched value when
      // the pipeline advances after an earlier lsu_valid (mem_done_q=1).
      mem_wb_q.lsu_rdata  <= lsu_valid ? lsu_rdata : lsu_rdata_latch;
      mem_wb_q.csr_rdata  <= ex_mem_q.csr_rdata;
      mem_wb_q.pc4        <= ex_mem_q.pc + 32'd4;
      mem_wb_q.valid      <= ex_mem_q.valid;
    end
  end

  // =========================================================================
  // WB→ID bypass
  // =========================================================================
  assign wb_writing  = mem_wb_q.valid & mem_wb_q.dec.rd_wen & (mem_wb_q.dec.rd != 5'd0);
  assign rs1_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs1) ? wb_result
                                                                       : rs1_rdata_64[31:0];
  assign rs2_data_id = (wb_writing && mem_wb_q.dec.rd == id_dec.rs2) ? wb_result
                                                                       : rs2_rdata_64[31:0];

  // =========================================================================
  // WB stage
  // =========================================================================
  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result = mem_wb_q.alu_result;
      WB_MEM:  wb_result = mem_wb_q.lsu_rdata;
      WB_PC4:  wb_result = mem_wb_q.pc4;
      WB_CSR:  wb_result = mem_wb_q.csr_rdata;
      default: wb_result = mem_wb_q.alu_result;
    endcase
  end

  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result_64 = {{32{wb_result[31]}}, wb_result};
      WB_MEM:  wb_result_64 = {{32{wb_result[31]}}, wb_result};
      WB_PC4:  wb_result_64 = {32'b0, wb_result};
      WB_CSR:  wb_result_64 = {32'b0, wb_result};
      default: wb_result_64 = {{32{wb_result[31]}}, wb_result};
    endcase
  end

endmodule
