// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode_ctrl.sv — CTRL-class sub-decoder (JAL, JALR, BRANCH).
// One of five per-class sub-decoders dispatched by kronos_decode.

module kronos_decode_ctrl
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
  logic       illegal;

  assign opcode = instr_i[6:0];
  assign rd     = instr_i[11:7];
  assign rs1    = instr_i[19:15];
  assign rs2    = instr_i[24:20];
  assign funct3 = instr_i[14:12];

  always_comb begin
    decoded_o     = kronos_pkg::DECODED_INSTR_ZERO;
    decoded_o.rs1 = rs1;
    decoded_o.rs2 = rs2;
    decoded_o.rd  = rd;
    illegal       = 1'b0;

    unique case (opcode)
      JAL: begin
        decoded_o.rd_wen = 1'b1;
        decoded_o.is_jal = 1'b1;
        decoded_o.imm    = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                            instr_i[20], instr_i[30:21], 1'b0};
        decoded_o.wb_sel = WB_PC4;
      end

      JALR: begin
        decoded_o.rs1_used = 1'b1;
        decoded_o.rd_wen   = 1'b1;
        decoded_o.is_jalr  = 1'b1;
        decoded_o.imm      = {{20{instr_i[31]}}, instr_i[31:20]};
        decoded_o.wb_sel   = WB_PC4;
        if (funct3 != 3'b000) illegal = 1'b1;
      end

      BRANCH: begin
        decoded_o.rs1_used      = 1'b1;
        decoded_o.rs2_used      = 1'b1;
        decoded_o.is_branch     = 1'b1;
        decoded_o.branch_funct3 = funct3;
        decoded_o.imm = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                         instr_i[30:25], instr_i[11:8], 1'b0};
        unique case (funct3)
          3'b100, 3'b101: decoded_o.alu_op = ALU_SLT;
          3'b110, 3'b111: decoded_o.alu_op = ALU_SLTU;
          default:        decoded_o.alu_op = ALU_SLTU;
        endcase
        if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
      end

      default: begin
        decoded_o = kronos_pkg::DECODED_INSTR_ZERO;
        illegal   = 1'b0;
      end
    endcase

    illegal_o = illegal;
  end

endmodule
