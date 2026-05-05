// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode_mem.sv — MEM sub-decoder.
// Owns LOAD, STORE, LOAD_FP, STORE_FP, AMO. All produce a rs1+imm address
// adder via alu_op = ALU_ADD; FP variants additionally tag is_fp/fp_load/etc.

module kronos_decode_mem
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

  // funct7[1:0] are AMO aq/rl bits; AMO decoding lives in kronos_decode_int
  // (this sub-decoder only handles plain LOAD/STORE), so the bits are dropped.
  logic       _unused;

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
      LOAD: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        decoded_o.is_load    = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_MEM;
        if (funct3 == 3'b111) illegal = 1'b1;
      end

      STORE: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rs2_used   = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        decoded_o.is_store   = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.rd_wen     = 1'b0;
        if (funct3 > 3'b011) illegal = 1'b1;
      end

      LOAD_FP: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        decoded_o.is_load    = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_MEM;
        decoded_o.is_fp      = 1'b1;
        decoded_o.fp_load    = 1'b1;
        decoded_o.rd_fp      = 1'b1;
        decoded_o.fmt_d      = (funct3 == 3'b011);
        if (funct3 != 3'b010 && funct3 != 3'b011) illegal = 1'b1;
      end

      STORE_FP: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        decoded_o.is_store   = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.rd_wen     = 1'b0;
        decoded_o.is_fp      = 1'b1;
        decoded_o.fp_store   = 1'b1;
        decoded_o.rs2_fp     = 1'b1;
        decoded_o.fmt_d      = (funct3 == 3'b011);
        if (funct3 != 3'b010 && funct3 != 3'b011) illegal = 1'b1;
      end

      AMO: begin
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.wb_sel     = WB_MEM;
        decoded_o.mem_funct3 = funct3;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = 32'd0;

        unique case (funct7[6:2])
          5'b00010: begin
            decoded_o.is_load = 1'b1;
            decoded_o.is_lr   = 1'b1;
          end
          5'b00011: begin
            decoded_o.is_store = 1'b1;
            decoded_o.is_sc    = 1'b1;
            decoded_o.rs2_used = 1'b1;
          end
          default: begin
            decoded_o.is_amo     = 1'b1;
            decoded_o.amo_funct5 = funct7[6:2];
            decoded_o.rs2_used   = 1'b1;
          end
        endcase

        if (funct3 != 3'b010 && funct3 != 3'b011) illegal = 1'b1;
      end

      default: begin
        decoded_o = kronos_pkg::DECODED_INSTR_ZERO;
        illegal   = 1'b0;
      end
    endcase

    illegal_o = illegal;
  end

  assign _unused = ^funct7[1:0];

endmodule
