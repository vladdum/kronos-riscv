// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode_int.sv — INT sub-decoder.
// Owns OP, OP_IMM, OP_IMM_32, OP_32 (incl. M-ext on funct7=0x01), LUI, AUIPC.

module kronos_decode_int
  import kronos_pkg::*;
(
  input  logic [kronos_pkg::INST_W-1:0] instr_i,
  output decoded_instr_t                decoded_o,
  output logic                          illegal_o
);

  logic [6:0] opcode;
  logic [4:0] rd;
  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic       illegal;

  assign opcode = instr_i[6:0];
  assign rd     = instr_i[11:7];
  assign rs1    = instr_i[19:15];
  assign rs2    = instr_i[24:20];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];

  always_comb begin
    decoded_o     = kronos_pkg::DECODED_INSTR_ZERO;
    decoded_o.rs1 = rs1;
    decoded_o.rs2 = rs2;
    decoded_o.rd  = rd;
    illegal       = 1'b0;

    unique case (opcode)
      OP: begin
        decoded_o.rs1_used = 1'b1;
        decoded_o.rs2_used = 1'b1;
        decoded_o.rd_wen   = 1'b1;
        decoded_o.wb_sel   = WB_ALU;

        if (funct7 == 7'b000_0001) begin
          decoded_o.is_muldiv = 1'b1;
          decoded_o.muldiv_op = muldiv_op_e'(funct3);
          decoded_o.use_imm   = 1'b0;
          decoded_o.alu_op    = ALU_ADD;
        end else begin
          decoded_o.use_imm = 1'b0;
          unique case ({funct7, funct3})
            {7'b000_0000, 3'b000}: decoded_o.alu_op = ALU_ADD;
            {7'b010_0000, 3'b000}: decoded_o.alu_op = ALU_SUB;
            {7'b000_0000, 3'b001}: decoded_o.alu_op = ALU_SLL;
            {7'b000_0000, 3'b010}: decoded_o.alu_op = ALU_SLT;
            {7'b000_0000, 3'b011}: decoded_o.alu_op = ALU_SLTU;
            {7'b000_0000, 3'b100}: decoded_o.alu_op = ALU_XOR;
            {7'b000_0000, 3'b101}: decoded_o.alu_op = ALU_SRL;
            {7'b010_0000, 3'b101}: decoded_o.alu_op = ALU_SRA;
            {7'b000_0000, 3'b110}: decoded_o.alu_op = ALU_OR;
            {7'b000_0000, 3'b111}: decoded_o.alu_op = ALU_AND;
            default:               illegal = 1'b1;
          endcase
        end
      end

      OP_IMM: begin
        decoded_o.rs1_used = 1'b1;
        decoded_o.rd_wen   = 1'b1;
        decoded_o.use_imm  = 1'b1;
        decoded_o.wb_sel   = WB_ALU;
        decoded_o.imm      = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: decoded_o.alu_op = ALU_ADD;
          3'b010: decoded_o.alu_op = ALU_SLT;
          3'b011: decoded_o.alu_op = ALU_SLTU;
          3'b100: decoded_o.alu_op = ALU_XOR;
          3'b110: decoded_o.alu_op = ALU_OR;
          3'b111: decoded_o.alu_op = ALU_AND;
          3'b001: begin
            decoded_o.alu_op = ALU_SLL;
            decoded_o.imm    = {26'b0, instr_i[25:20]};
            if (funct7[6:1] != 6'b000_000) illegal = 1'b1;
          end
          3'b101: begin
            decoded_o.imm = {26'b0, instr_i[25:20]};
            if      (funct7[6:1] == 6'b000_000) decoded_o.alu_op = ALU_SRL;
            else if (funct7[6:1] == 6'b010_000) decoded_o.alu_op = ALU_SRA;
            else                                illegal = 1'b1;
          end
          // verilator coverage_off
          default: illegal = 1'b1;
          // verilator coverage_on
        endcase
      end

      OP_IMM_32: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.is_word_op = 1'b1;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: decoded_o.alu_op = ALU_ADD;
          3'b001: begin
            decoded_o.alu_op = ALU_SLL;
            decoded_o.imm    = {27'b0, instr_i[24:20]};
            if (funct7 != 7'b000_0000) illegal = 1'b1;
          end
          3'b101: begin
            decoded_o.imm = {27'b0, instr_i[24:20]};
            if      (funct7 == 7'b000_0000) decoded_o.alu_op = ALU_SRL;
            else if (funct7 == 7'b010_0000) decoded_o.alu_op = ALU_SRA;
            else                            illegal = 1'b1;
          end
          default: illegal = 1'b1;
        endcase
      end

      OP_32: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rs2_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.is_word_op = 1'b1;

        if (funct7 == 7'b000_0001) begin
          decoded_o.is_muldiv = 1'b1;
          decoded_o.muldiv_op = muldiv_op_e'(funct3);
          decoded_o.use_imm   = 1'b0;
          decoded_o.alu_op    = ALU_ADD;
          if (funct3 > 3'b000 && funct3 < 3'b100) illegal = 1'b1;
        end else begin
          decoded_o.use_imm = 1'b0;
          unique case ({funct7, funct3})
            {7'b000_0000, 3'b000}: decoded_o.alu_op = ALU_ADD;
            {7'b010_0000, 3'b000}: decoded_o.alu_op = ALU_SUB;
            {7'b000_0000, 3'b001}: decoded_o.alu_op = ALU_SLL;
            {7'b000_0000, 3'b101}: decoded_o.alu_op = ALU_SRL;
            {7'b010_0000, 3'b101}: decoded_o.alu_op = ALU_SRA;
            default:               illegal = 1'b1;
          endcase
        end
      end

      LUI: begin
        decoded_o.rd_wen  = 1'b1;
        decoded_o.use_imm = 1'b1;
        decoded_o.alu_op  = ALU_PASSB;
        decoded_o.imm     = {instr_i[31:12], 12'b0};
        decoded_o.wb_sel  = WB_ALU;
      end

      AUIPC: begin
        decoded_o.rd_wen  = 1'b1;
        decoded_o.use_imm = 1'b1;
        decoded_o.use_pc  = 1'b1;
        decoded_o.alu_op  = ALU_ADD;
        decoded_o.imm     = {instr_i[31:12], 12'b0};
        decoded_o.wb_sel  = WB_ALU;
      end

      default: begin
        decoded_o = kronos_pkg::DECODED_INSTR_ZERO;
        illegal   = 1'b0;
      end
    endcase

    illegal_o = illegal;
  end

endmodule
