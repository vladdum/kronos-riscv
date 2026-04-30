// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage1) — 5-stage in-order pipeline
// Stages: IF -> ID -> EX -> MEM -> WB
// Reuses stage0: kronos_decode, kronos_regfile, kronos_alu, kronos_csr
// New in stage1:  kronos_lsu (updated), kronos_forward, kronos_hazard
module kronos_top
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [ 3:0] data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  // Stage 6a IRQ sources — unused in stage 1; kept for sim_top wrapper compat.
  input  logic        irq_msi_i,
  input  logic        irq_mei_i,
  input  logic        irq_ssi_i,
  input  logic        irq_sti_i,
  input  logic        irq_sei_i,
  input  logic [31:0] boot_addr_i
);

  // -------------------------------------------------------------------------
  // Local constants
  // -------------------------------------------------------------------------
  // RV32I trap causes (mcause encoding for the events stage 1 can take).
  localparam logic [31:0] TRAP_CAUSE_MTI     = 32'h8000_0007; // M-mode timer IRQ
  localparam logic [31:0] TRAP_CAUSE_ILLEGAL = 32'd2;
  localparam logic [31:0] TRAP_CAUSE_ECALL_M = 32'd11;
  localparam logic [31:0] TRAP_CAUSE_BREAK   = 32'd3;

  // -------------------------------------------------------------------------
  // Pipeline registers (owned by kronos_top)
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
  // WB->ID bypass: when WB writes the same register that ID is reading in the
  // same cycle, forward the write data so the consumer sees the up-to-date
  // value.  wb_result comes from the registered mem_wb_q so there is no
  // combinatorial loop.
  logic [31:0]    rs1_data_id, rs2_data_id;
  logic           wb_writing;

  // -------------------------------------------------------------------------
  // EX-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] fwd_rs1_data, fwd_rs2_data;
  logic [31:0] alu_a, alu_b, alu_result;
  logic [31:0] ex_pc_d;
  logic        ex_redirect;
  logic        branch_taken;
  logic        irq_pending;
  logic [31:0] csr_rdata, trap_vector, mepc;
  logic [31:0] trap_cause;
  logic        csr_valid;

  // -------------------------------------------------------------------------
  // MEM-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] lsu_rdata;
  logic        lsu_valid;
  logic        mem_stall;

  // -------------------------------------------------------------------------
  // WB-stage wires
  // -------------------------------------------------------------------------
  logic [31:0] wb_result;     // 32-bit: used as forwarding source
  logic [63:0] wb_result_64;  // 64-bit: written to regfile

  // -------------------------------------------------------------------------
  // PC next-state (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] pc_d;

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
    .id_ex_is_load_i  (id_ex_q.dec.is_load),
    .ex_mem_rd_i      (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i  (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .id_ex_rd_fp_i    (1'b0),
    .ex_mem_rd_fp_i   (1'b0),
    .fwd_rs1_sel_o    (fwd_rs1_sel),
    .fwd_rs2_sel_o    (fwd_rs2_sel)
  );

  kronos_hazard u_hazard (
    .id_ex_is_load_i  (id_ex_q.dec.is_load),
    .id_ex_rd_i       (id_ex_q.dec.rd),
    .id_ex_valid_i    (id_ex_q.valid),
    .if_id_rs1_used_i (id_dec.rs1_used),
    .if_id_rs1_i      (id_dec.rs1),
    .if_id_rs2_used_i (id_dec.rs2_used),
    .if_id_rs2_i          (id_dec.rs2),
    .id_ex_is_fp_load_i   (1'b0),
    .if_id_rs1_fp_i       (1'b0),
    .if_id_rs2_fp_i       (1'b0),
    .if_id_rs3_fp_i       (1'b0),
    .if_id_rs3_i          (5'd0),
    .if_id_is_jalr_i      (id_dec.is_jalr),
    .ex_mem_rd_i          (ex_mem_q.dec.rd),
    .ex_mem_rd_wen_i      (ex_mem_q.dec.rd_wen & ex_mem_q.valid),
    .ex_mem_valid_i       (ex_mem_q.valid),
    .id_ex_is_frm_write_i (1'b0),
    .if_id_fp_dyn_rm_i    (1'b0),
    .ex_redirect_i        (ex_redirect),
    .mem_redirect_i       (1'b0),
    .mem_stall_i          (mem_stall),
    .muldiv_stall_i       (1'b0),
    .pc_en_o              (pc_en),
    .if_id_en_o           (if_id_en),
    .id_ex_en_o           (id_ex_en),
    .ex_mem_en_o          (ex_mem_en),
    .mem_wb_en_o          (mem_wb_en),
    .if_id_flush_o        (if_id_flush),
    .id_ex_flush_o        (id_ex_flush)
  );

  kronos_alu u_alu (
    .op_i     (id_ex_q.dec.alu_op),
    .a_i      (alu_a),
    .b_i      (alu_b),
    .result_o (alu_result)
  );

  kronos_csr u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (id_ex_q.valid & id_ex_q.dec.is_csr),
    .addr_i        (id_ex_q.dec.csr_addr),
    .funct3_i      (id_ex_q.dec.csr_funct3),
    .use_imm_i     (id_ex_q.dec.csr_use_imm),
    .rs1_data_i    (fwd_rs1_data),
    .rs1_addr_i    (id_ex_q.dec.rs1),
    .rdata_o       (csr_rdata),
    .valid_o       (csr_valid),
    .trap_i        (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                                      id_ex_q.dec.illegal  | irq_pending)),
    .trap_pc_i     (id_ex_q.pc),
    .trap_cause_i  (trap_cause),
    .mret_i        (id_ex_q.valid & id_ex_q.dec.is_mret),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .irq_timer_i   (irq_timer_i),
    .irq_fast_i    (irq_fast_i),
    .irq_pending_o (irq_pending)
  );

  kronos_lsu u_lsu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store)),
    .we_i          (ex_mem_q.dec.is_store),
    .addr_i        (ex_mem_q.alu_result[31:0]),
    .wdata_i       (ex_mem_q.rs2_data[31:0]),
    .funct3_i      (ex_mem_q.dec.mem_funct3),
    .rdata_o       (lsu_rdata),
    .valid_o       (lsu_valid),
    .mem_stall_o   (mem_stall),
    .data_req_o    (data_req_o),
    .data_gnt_i    (data_gnt_i),
    .data_rvalid_i (data_rvalid_i),
    .data_we_o     (data_we_o),
    .data_be_o     (data_be_o),
    .data_addr_o   (data_addr_o),
    .data_wdata_o  (data_wdata_o),
    .data_rdata_i  (data_rdata_i),
    .data_err_i    (data_err_i)
  );

  // =========================================================================
  // PC register
  // =========================================================================
  assign pc_d = ex_redirect ? ex_pc_d : pc_q + 32'd4;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        pc_q <= boot_addr_i;
    else if (pc_en)     pc_q <= pc_d;
  end

  // =========================================================================
  // IF stage
  // =========================================================================
  assign instr_req_o  = rst_ni;
  assign instr_addr_o = pc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if_id_q <= '{default: '0};
    end else if (if_id_flush) begin
      if_id_q <= '{default: '0};
    end else if (if_id_en) begin
      if_id_q.pc    <= pc_q;
      if_id_q.instr <= instr_rdata_i;
      if_id_q.valid <= instr_rvalid_i;
    end
  end

  // =========================================================================
  // ID stage
  // =========================================================================
  // kronos_decode and kronos_regfile driven by if_id_q (instantiated above)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_ex_q <= kronos_pkg::ID_EX_REG_ZERO;
    end else if (id_ex_flush) begin
      id_ex_q <= kronos_pkg::ID_EX_REG_ZERO;
    end else if (id_ex_en) begin
      id_ex_q.pc          <= if_id_q.pc;
      id_ex_q.dec         <= id_dec;
      id_ex_q.rs1_data    <= {{32{rs1_data_id[31]}}, rs1_data_id};
      id_ex_q.rs2_data    <= {{32{rs2_data_id[31]}}, rs2_data_id};
      id_ex_q.valid       <= if_id_q.valid;
      id_ex_q.fwd_rs1_sel <= fwd_rs1_sel;
      id_ex_q.fwd_rs2_sel <= fwd_rs2_sel;
    end
  end

  // =========================================================================
  // EX stage
  // =========================================================================

  // Forwarding muxes
  always_comb begin
    fwd_rs1_data = id_ex_q.rs1_data[31:0];
    fwd_rs2_data = id_ex_q.rs2_data[31:0];
    unique case (id_ex_q.fwd_rs1_sel)
      FWD_NONE:  fwd_rs1_data = id_ex_q.rs1_data[31:0];
      FWD_EXMEM: fwd_rs1_data = ex_mem_q.alu_result[31:0];
      FWD_MEMWB: fwd_rs1_data = wb_result;
      default:   fwd_rs1_data = id_ex_q.rs1_data[31:0];
    endcase
    unique case (id_ex_q.fwd_rs2_sel)
      FWD_NONE:  fwd_rs2_data = id_ex_q.rs2_data[31:0];
      FWD_EXMEM: fwd_rs2_data = ex_mem_q.alu_result[31:0];
      FWD_MEMWB: fwd_rs2_data = wb_result;
      default:   fwd_rs2_data = id_ex_q.rs2_data[31:0];
    endcase
  end

  // ALU operand selection
  assign alu_a = id_ex_q.dec.use_pc  ? id_ex_q.pc        : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? id_ex_q.dec.imm   : fwd_rs2_data;

  // Branch comparator
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

  // Trap cause encoding
  always_comb begin
    trap_cause = TRAP_CAUSE_BREAK;
    if      (irq_pending)               trap_cause = TRAP_CAUSE_MTI;
    else if (id_ex_q.dec.illegal)       trap_cause = TRAP_CAUSE_ILLEGAL;
    else if (id_ex_q.dec.is_ecall)      trap_cause = TRAP_CAUSE_ECALL_M;
    else                                trap_cause = TRAP_CAUSE_BREAK;
  end

  // PC redirect target
  always_comb begin
    ex_pc_d = id_ex_q.pc + 32'd4;
    if (id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                         id_ex_q.dec.illegal  | irq_pending)) begin
      ex_pc_d = trap_vector;
    end else if (id_ex_q.valid & id_ex_q.dec.is_mret) begin
      ex_pc_d = mepc;
    end else if (id_ex_q.valid & id_ex_q.dec.is_jalr) begin
      ex_pc_d = (fwd_rs1_data + id_ex_q.dec.imm) & ~32'd1;
    end else if (id_ex_q.valid & id_ex_q.dec.is_jal) begin
      ex_pc_d = id_ex_q.pc + id_ex_q.dec.imm;
    end else if (branch_taken) begin
      ex_pc_d = id_ex_q.pc + id_ex_q.dec.imm;
    end else begin
      ex_pc_d = id_ex_q.pc + 32'd4;
    end
  end

  assign ex_redirect = id_ex_q.valid &
    (id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr | branch_taken |
     id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak | id_ex_q.dec.illegal |
     id_ex_q.dec.is_mret  | irq_pending);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '{default: '0};
    end else if (ex_mem_en) begin
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.dec        <= id_ex_q.dec;
      ex_mem_q.alu_result <= {{32{alu_result[31]}}, alu_result};
      ex_mem_q.rs2_data   <= {{32{fwd_rs2_data[31]}}, fwd_rs2_data};
      ex_mem_q.pc_next    <= ex_pc_d;
      ex_mem_q.csr_rdata  <= {32'b0, csr_rdata};
      ex_mem_q.redirect   <= ex_redirect;
      // Squash valid on IRQ: instruction is re-fetched after MRET
      ex_mem_q.valid      <= id_ex_q.valid & ~irq_pending;
    end
  end

  // =========================================================================
  // MEM stage (kronos_lsu driven by ex_mem_q, instantiated above)
  // =========================================================================

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '{default: '0};
    end else if (mem_wb_en) begin
      mem_wb_q.dec        <= ex_mem_q.dec;
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.lsu_rdata  <= {{32{lsu_rdata[31]}}, lsu_rdata};
      mem_wb_q.csr_rdata  <= ex_mem_q.csr_rdata;
      mem_wb_q.pc4        <= ex_mem_q.pc + 32'd4;
      mem_wb_q.valid      <= ex_mem_q.valid;
    end
  end

  // =========================================================================
  // WB->ID bypass (3-cycle RAW)
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
    wb_result_64 = mem_wb_q.alu_result;
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result_64 = mem_wb_q.alu_result;
      WB_MEM:  wb_result_64 = mem_wb_q.lsu_rdata;
      WB_PC4:  wb_result_64 = {32'b0, mem_wb_q.pc4};
      WB_CSR:  wb_result_64 = mem_wb_q.csr_rdata;
      default: wb_result_64 = mem_wb_q.alu_result;
    endcase
  end

  assign wb_result = wb_result_64[31:0];

endmodule
