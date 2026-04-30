// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode.sv — RV32I instruction decoder
// Decodes one instruction word into a decoded_instr_t struct.
// Built incrementally: R-type first, other formats added in later tasks.
module kronos_decode
  import kronos_pkg::*;
(
  input  logic [31:0]    instr_i,
  output decoded_instr_t dec_o
);

  // -------------------------------------------------------------------------
  // Opcode constants
  // -------------------------------------------------------------------------
  localparam logic [6:0] OP     = 7'b011_0011; // R-type
  localparam logic [6:0] OP_IMM = 7'b001_0011; // I-type ALU
  localparam logic [6:0] LOAD   = 7'b000_0011;
  localparam logic [6:0] STORE  = 7'b010_0011;
  localparam logic [6:0] BRANCH = 7'b110_0011;
  localparam logic [6:0] LUI    = 7'b011_0111;
  localparam logic [6:0] AUIPC  = 7'b001_0111;
  localparam logic [6:0] JAL    = 7'b110_1111;
  localparam logic [6:0] JALR   = 7'b110_0111;
  localparam logic [6:0] SYSTEM = 7'b111_0011;

  // -------------------------------------------------------------------------
  // Combinational signals — instruction fields
  // -------------------------------------------------------------------------
  logic [6:0] opcode;
  logic [4:0] rd;
  logic [2:0] funct3;
  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [6:0] funct7;

  assign opcode = instr_i[6:0];
  assign rd     = instr_i[11:7];
  assign funct3 = instr_i[14:12];
  assign rs1    = instr_i[19:15];
  assign rs2    = instr_i[24:20];
  assign funct7 = instr_i[31:25];

  always_comb begin
    dec_o          = kronos_pkg::DECODED_INSTR_ZERO;
    dec_o.rs1      = rs1;
    dec_o.rs2      = rs2;
    dec_o.rd       = rd;
    dec_o.illegal  = 1'b0;

    unique case (opcode)
      OP: begin  // R-type: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
        dec_o.rs1_used = 1'b1;
        dec_o.rs2_used = 1'b1;
        dec_o.rd_wen   = 1'b1;
        dec_o.use_imm  = 1'b0;
        dec_o.wb_sel   = WB_ALU;
        unique case ({funct7, funct3})
          {7'b000_0000, 3'b000}: dec_o.alu_op = ALU_ADD;
          {7'b010_0000, 3'b000}: dec_o.alu_op = ALU_SUB;
          {7'b000_0000, 3'b001}: dec_o.alu_op = ALU_SLL;
          {7'b000_0000, 3'b010}: dec_o.alu_op = ALU_SLT;
          {7'b000_0000, 3'b011}: dec_o.alu_op = ALU_SLTU;
          {7'b000_0000, 3'b100}: dec_o.alu_op = ALU_XOR;
          {7'b000_0000, 3'b101}: dec_o.alu_op = ALU_SRL;
          {7'b010_0000, 3'b101}: dec_o.alu_op = ALU_SRA;
          {7'b000_0000, 3'b110}: dec_o.alu_op = ALU_OR;
          {7'b000_0000, 3'b111}: dec_o.alu_op = ALU_AND;
          default:               dec_o.illegal = 1'b1;
        endcase
      end
      OP_IMM: begin  // I-type ALU: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
        dec_o.rs1_used = 1'b1;
        dec_o.rd_wen   = 1'b1;
        dec_o.use_imm  = 1'b1;
        dec_o.wb_sel   = WB_ALU;
        dec_o.imm      = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: dec_o.alu_op = ALU_ADD;   // ADDI
          3'b010: dec_o.alu_op = ALU_SLT;   // SLTI
          3'b011: dec_o.alu_op = ALU_SLTU;  // SLTIU
          3'b100: dec_o.alu_op = ALU_XOR;   // XORI
          3'b110: dec_o.alu_op = ALU_OR;    // ORI
          3'b111: dec_o.alu_op = ALU_AND;   // ANDI
          3'b001: begin                      // SLLI
            dec_o.alu_op = ALU_SLL;
            dec_o.imm    = {27'b0, instr_i[24:20]};
            if (funct7 != 7'b000_0000) dec_o.illegal = 1'b1;
          end
          3'b101: begin                      // SRLI / SRAI
            dec_o.imm = {27'b0, instr_i[24:20]};
            if      (funct7 == 7'b000_0000) dec_o.alu_op = ALU_SRL;
            else if (funct7 == 7'b010_0000) dec_o.alu_op = ALU_SRA;
            else                            dec_o.illegal = 1'b1;
          end
          default: dec_o.illegal = 1'b1;
        endcase
      end
      LUI: begin
        dec_o.rd_wen  = 1'b1;
        dec_o.use_imm = 1'b1;
        dec_o.alu_op  = ALU_PASSB;
        dec_o.imm     = {instr_i[31:12], 12'b0};
        dec_o.wb_sel  = WB_ALU;
      end

      AUIPC: begin
        dec_o.rd_wen  = 1'b1;
        dec_o.use_imm = 1'b1;
        dec_o.use_pc  = 1'b1;
        dec_o.alu_op  = ALU_ADD;
        dec_o.imm     = {instr_i[31:12], 12'b0};
        dec_o.wb_sel  = WB_ALU;
      end

      JAL: begin
        dec_o.rd_wen = 1'b1;
        dec_o.is_jal = 1'b1;
        // J-type immediate: imm[20|10:1|11|19:12], bit 0 always 0
        dec_o.imm    = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                        instr_i[20], instr_i[30:21], 1'b0};
        dec_o.wb_sel = WB_PC4;
      end

      JALR: begin
        dec_o.rs1_used = 1'b1;
        dec_o.rd_wen   = 1'b1;
        dec_o.is_jalr  = 1'b1;
        dec_o.imm      = {{20{instr_i[31]}}, instr_i[31:20]};
        dec_o.wb_sel   = WB_PC4;
        if (funct3 != 3'b000) dec_o.illegal = 1'b1;
      end

      BRANCH: begin  // BEQ, BNE, BLT, BGE, BLTU, BGEU
        dec_o.rs1_used      = 1'b1;
        dec_o.rs2_used      = 1'b1;
        dec_o.is_branch     = 1'b1;
        dec_o.branch_funct3 = funct3;
        // B-type immediate: imm[12|10:5|4:1|11], bit 0 always 0
        dec_o.imm = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                     instr_i[30:25], instr_i[11:8], 1'b0};
        if (funct3 == 3'b010 || funct3 == 3'b011) dec_o.illegal = 1'b1;
      end

      LOAD: begin  // LB, LH, LW, LBU, LHU
        dec_o.rs1_used   = 1'b1;
        dec_o.rd_wen     = 1'b1;
        dec_o.use_imm    = 1'b1;
        dec_o.alu_op     = ALU_ADD;
        dec_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        dec_o.is_load    = 1'b1;
        dec_o.mem_funct3 = funct3;
        dec_o.wb_sel     = WB_MEM;
        if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111)
          dec_o.illegal = 1'b1; // LD/LWU not in RV32I
      end

      STORE: begin  // SB, SH, SW
        dec_o.rs1_used   = 1'b1;
        dec_o.rs2_used   = 1'b1;
        dec_o.use_imm    = 1'b1;
        dec_o.alu_op     = ALU_ADD;
        dec_o.imm        = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        dec_o.is_store   = 1'b1;
        dec_o.mem_funct3 = funct3;
        dec_o.wb_sel     = WB_ALU;
        dec_o.rd_wen     = 1'b0;
        if (funct3 > 3'b010) dec_o.illegal = 1'b1; // only SB/SH/SW
      end

      SYSTEM: begin
        unique case (funct3)
          3'b000: begin  // ECALL, EBREAK, MRET
            unique case (instr_i[31:20])
              12'h000: dec_o.is_ecall  = 1'b1;
              12'h001: dec_o.is_ebreak = 1'b1;
              12'h302: dec_o.is_mret   = 1'b1;
              default: dec_o.illegal   = 1'b1;
            endcase
          end
          default: begin  // CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
            dec_o.is_csr      = 1'b1;
            dec_o.rd_wen      = 1'b1;
            dec_o.rs1_used    = ~funct3[2]; // funct3[2]=1 means zimm form
            dec_o.csr_addr    = instr_i[31:20];
            dec_o.csr_funct3  = funct3;
            dec_o.csr_use_imm = funct3[2];
            dec_o.wb_sel      = WB_CSR;
          end
        endcase
      end

      default: dec_o.illegal = 1'b1;
    endcase
  end

endmodule
