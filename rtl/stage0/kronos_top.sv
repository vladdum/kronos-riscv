// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv — single-cycle core top-level (Stage 0)
// One instruction per clock: fetch → decode → execute → writeback.
module kronos_top
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  // OBI instruction port
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,
  // OBI data port
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [ 3:0] data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,
  // Interrupts
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  // Stage 6a IRQ sources — unused in stage 0; kept for sim_top wrapper compat.
  input  logic        irq_msi_i,
  input  logic        irq_mei_i,
  input  logic        irq_ssi_i,
  input  logic        irq_sti_i,
  input  logic        irq_sei_i,
  // Boot address
  input  logic [31:0] boot_addr_i
);

  // -------------------------------------------------------------------------
  // Imported types
  // -------------------------------------------------------------------------
  decoded_instr_t dec;

  // -------------------------------------------------------------------------
  // State registers (driven by always_ff)
  // -------------------------------------------------------------------------
  logic [31:0] pc_q;

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  logic [31:0] pc_d;
  logic [31:0] alu_a, alu_b, alu_result;
  logic [63:0] rs1_data, rs2_data;
  logic [4:0]  rd_addr;
  logic        rd_wen;
  logic [63:0] rd_wdata;
  logic [31:0] lsu_rdata;
  logic        lsu_valid;
  logic [31:0] csr_rdata, trap_vector, mepc;
  logic        csr_valid, irq_pending;
  logic        trap;
  logic [31:0] trap_cause;
  logic        branch_taken;

  // -------------------------------------------------------------------------
  // PC
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pc_q <= boot_addr_i;
    else if (instr_rvalid_i) pc_q <= pc_d;
  end

  // -------------------------------------------------------------------------
  // Instruction fetch (OBI)
  // -------------------------------------------------------------------------
  assign instr_req_o  = rst_ni;
  assign instr_addr_o = pc_q;

  // -------------------------------------------------------------------------
  // Decode
  // -------------------------------------------------------------------------
  kronos_decode u_decode (
    .instr_i (instr_rdata_i),
    .dec_o   (dec)
  );

  // -------------------------------------------------------------------------
  // Register file
  // -------------------------------------------------------------------------
  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (dec.rs1),
    .rs2_addr_i  (dec.rs2),
    .rs1_rdata_o (rs1_data),
    .rs2_rdata_o (rs2_data),
    .rd_addr_i   (rd_addr),
    .rd_wen_i    (rd_wen),
    .rd_wdata_i  (rd_wdata)
  );

  // -------------------------------------------------------------------------
  // ALU
  // -------------------------------------------------------------------------
  assign alu_a = dec.use_pc  ? pc_q         : rs1_data[31:0];
  assign alu_b = dec.use_imm ? dec.imm      : rs2_data[31:0];

  kronos_alu u_alu (
    .a_i      (alu_a),
    .b_i      (alu_b),
    .op_i     (dec.alu_op),
    .result_o (alu_result)
  );

  // -------------------------------------------------------------------------
  // LSU
  // -------------------------------------------------------------------------
  kronos_lsu u_lsu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (instr_rvalid_i & (dec.is_load | dec.is_store)),
    .we_i          (dec.is_store),
    .addr_i        (alu_result),
    .wdata_i       (rs2_data[31:0]),
    .funct3_i      (dec.mem_funct3),
    .rdata_o       (lsu_rdata),
    .valid_o       (lsu_valid),
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

  // -------------------------------------------------------------------------
  // CSR
  // -------------------------------------------------------------------------
  kronos_csr u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (instr_rvalid_i & dec.is_csr),
    .addr_i        (dec.csr_addr),
    .funct3_i      (dec.csr_funct3),
    .use_imm_i     (dec.csr_use_imm),
    .rs1_data_i    (rs1_data[31:0]),
    .rs1_addr_i    (dec.rs1),
    .rdata_o       (csr_rdata),
    .valid_o       (csr_valid),
    .trap_i        (trap),
    .trap_pc_i     (pc_q),
    .trap_cause_i  (trap_cause),
    .mret_i        (dec.is_mret),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .irq_timer_i   (irq_timer_i),
    .irq_fast_i    (irq_fast_i),
    .irq_pending_o (irq_pending)
  );

  // -------------------------------------------------------------------------
  // Writeback
  // -------------------------------------------------------------------------
  always_comb begin
    rd_wdata = {64{1'b0}};
    unique case (dec.wb_sel)
      WB_ALU:  rd_wdata = {{32{alu_result[31]}}, alu_result};
      WB_MEM:  rd_wdata = {{32{lsu_rdata[31]}},  lsu_rdata};
      WB_PC4:  rd_wdata = {32'b0, pc_q + 32'd4};
      WB_CSR:  rd_wdata = {32'b0, csr_rdata};
      default: rd_wdata = {64{1'b0}};
    endcase
  end

  assign rd_addr = dec.rd;
  assign rd_wen  = instr_rvalid_i & dec.rd_wen & ~dec.illegal;

  // -------------------------------------------------------------------------
  // Trap detection
  // -------------------------------------------------------------------------
  assign trap = instr_rvalid_i & (dec.is_ecall | dec.is_ebreak | dec.illegal);

  always_comb begin
    trap_cause = 32'd3; // default: ebreak
    if      (dec.illegal)   trap_cause = 32'd2;  // illegal instruction
    else if (dec.is_ecall)  trap_cause = 32'd11; // ecall from M-mode
    else                    trap_cause = 32'd3;  // ebreak
  end

  // -------------------------------------------------------------------------
  // Next PC
  // -------------------------------------------------------------------------
  always_comb begin
    branch_taken = 1'b0;
    unique case (dec.branch_funct3)
      3'b000:  branch_taken = (rs1_data[31:0] == rs2_data[31:0]);                       // BEQ
      3'b001:  branch_taken = (rs1_data[31:0] != rs2_data[31:0]);                       // BNE
      3'b100:  branch_taken = ($signed(rs1_data[31:0]) <  $signed(rs2_data[31:0]));     // BLT
      3'b101:  branch_taken = ($signed(rs1_data[31:0]) >= $signed(rs2_data[31:0]));     // BGE
      3'b110:  branch_taken = (rs1_data[31:0] <  rs2_data[31:0]);                       // BLTU
      3'b111:  branch_taken = (rs1_data[31:0] >= rs2_data[31:0]);                       // BGEU
      default: branch_taken = 1'b0;
    endcase
  end

  always_comb begin
    pc_d = pc_q + 32'd4;
    if      (trap)          pc_d = trap_vector;
    else if (dec.is_mret)   pc_d = mepc;
    else if (dec.is_jal)    pc_d = pc_q + dec.imm;
    else if (dec.is_jalr)   pc_d = (rs1_data[31:0] + dec.imm) & ~32'd1;
    else if (dec.is_branch) pc_d = branch_taken ? (pc_q + dec.imm) : (pc_q + 32'd4);
    else                    pc_d = pc_q + 32'd4;
  end

endmodule
