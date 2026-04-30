// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decompress.sv — RV32C 16-bit instruction expander.
// Purely combinational. Returns the 32-bit canonical RV32I equivalent.
// Sets illegal_o=1 for reserved or undefined encodings.
module kronos_decompress
  import kronos_pkg::*;
(
  input  logic [15:0]        instr16_i,
  output logic [INST_W-1:0]  instr32_o,
  output logic               illegal_o
);
  // ---------------------------------------------------------------
  // 1. Constants
  // ---------------------------------------------------------------
  localparam logic [6:0] OP_IMM      = 7'b001_0011;
  localparam logic [6:0] OP_LUI      = 7'b011_0111;
  localparam logic [6:0] OP_JAL      = 7'b110_1111;
  localparam logic [6:0] OP_JALR     = 7'b110_0111;
  localparam logic [6:0] OP_LOAD     = 7'b000_0011;
  localparam logic [6:0] OP_STORE    = 7'b010_0011;
  localparam logic [6:0] OP_BRNCH    = 7'b110_0011;
  localparam logic [6:0] OP_REG      = 7'b011_0011;
  localparam logic [6:0] OP_IMM_32   = 7'b001_1011;  // RV64 OP-IMM-32 (ADDIW/SLLIW/etc.)
  localparam logic [6:0] OP_REG_32   = 7'b011_1011;  // RV64 OP-32 (ADDW/SUBW/etc.)
  localparam logic [6:0] OP_LOAD_FP  = 7'b000_0111;  // FLD / FLW
  localparam logic [6:0] OP_STORE_FP = 7'b010_0111;  // FSD / FSW

  localparam logic [4:0] REG_X0 = 5'd0;
  localparam logic [4:0] REG_X1 = 5'd1;
  localparam logic [4:0] REG_X2 = 5'd2;

  // ---------------------------------------------------------------
  // 4. Combinational signals
  // ---------------------------------------------------------------
  logic [2:0]         funct3;
  logic [4:0]         rd,  rs1,  rs2;
  logic [2:0]         rd_p, rs1_p, rs2_p;
  logic [4:0]         rd_full, rs1_full, rs2_full;

  // Temporary signals for immediate assembly (shared across case arms — only one active at a time)
  logic [11:0]        uimm;
  logic [INST_W-1:0]  nzimm;
  logic [INST_W-1:0]  imm;
  logic [INST_W-1:0]  off;
  logic [5:0]         shamt;

  // ---------------------------------------------------------------
  // Field extraction
  // ---------------------------------------------------------------
  assign funct3 = instr16_i[15:13];
  assign rd     = instr16_i[11:7];
  assign rs1    = instr16_i[11:7];
  assign rs2    = instr16_i[6:2];
  assign rd_p   = instr16_i[4:2];
  assign rs1_p  = instr16_i[9:7];
  assign rs2_p  = instr16_i[4:2];

  assign rd_full  = {2'b01, rd_p};
  assign rs1_full = {2'b01, rs1_p};
  assign rs2_full = {2'b01, rs2_p};

  // ---------------------------------------------------------------
  // Decompression
  // ---------------------------------------------------------------
  always_comb begin
    // Defaults
    instr32_o = {INST_W{1'b0}};
    illegal_o = 1'b0;
    uimm      = 12'd0;
    nzimm     = {INST_W{1'b0}};
    imm       = {INST_W{1'b0}};
    off       = {INST_W{1'b0}};
    shamt     = 6'd0;

    unique case (instr16_i[1:0])

      // ---------------------------------------------------------------
      // Quadrant 0
      // ---------------------------------------------------------------
      2'b00: begin
        unique case (funct3)

          3'b000: begin  // C.ADDI4SPN → ADDI rd', x2, nzuimm
            uimm = {2'b0, instr16_i[10:7], instr16_i[12:11],
                    instr16_i[5], instr16_i[6], 2'b0};
            if (uimm == {12{1'b0}}) illegal_o = 1'b1;
            else instr32_o = {uimm, REG_X2, 3'b000, rd_full, OP_IMM};
          end

          3'b001: begin  // RV64C: C.FLD → FLD fd', uimm(rs1')
            uimm = {4'b0, instr16_i[6:5], instr16_i[12:10], 3'b0};
            instr32_o = {uimm, rs1_full, 3'b011, rd_full, OP_LOAD_FP};
          end

          3'b010: begin  // C.LW → LW rd', offset(rs1')
            uimm = {5'b0, instr16_i[5], instr16_i[12:10], instr16_i[6], 2'b0};
            instr32_o = {uimm, rs1_full, 3'b010, rd_full, OP_LOAD};
          end

          3'b011: begin  // RV64C: C.LD (also via funct3=011 in RV64) → LD rd', uimm(rs1')
            uimm = {4'b0, instr16_i[6:5], instr16_i[12:10], 3'b0};
            instr32_o = {uimm, rs1_full, 3'b011, rd_full, OP_LOAD};
          end

          3'b101: begin  // RV64C: C.FSD → FSD fs2', uimm(rs1')
            uimm = {4'b0, instr16_i[6:5], instr16_i[12:10], 3'b0};
            instr32_o = {uimm[11:5], rs2_full, rs1_full, 3'b011,
                         uimm[4:0], OP_STORE_FP};
          end

          3'b111: begin  // RV64C: C.SD (also via funct3=111 in RV64) → SD rs2', uimm(rs1')
            uimm = {4'b0, instr16_i[6:5], instr16_i[12:10], 3'b0};
            instr32_o = {uimm[11:5], rs2_full, rs1_full, 3'b011,
                         uimm[4:0], OP_STORE};
          end

          3'b110: begin  // C.SW → SW rs2', offset(rs1')
            uimm = {5'b0, instr16_i[5], instr16_i[12:10], instr16_i[6], 2'b0};
            instr32_o = {uimm[11:5], rs2_full, rs1_full, 3'b010,
                         uimm[4:0], OP_STORE};
          end

          default: illegal_o = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 1
      // ---------------------------------------------------------------
      2'b01: begin
        unique case (funct3)

          3'b000: begin  // C.NOP / C.ADDI → ADDI rd, rd, nzimm
            nzimm = {{27{instr16_i[12]}}, instr16_i[6:2]};
            instr32_o = {nzimm[11:0], rd, 3'b000, rd, OP_IMM};
          end

          3'b001: begin  // RV64C: C.ADDIW → ADDIW rd, rd, imm  (C.JAL removed in RV64)
            imm = {{27{instr16_i[12]}}, instr16_i[6:2]};
            if (rd == REG_X0) illegal_o = 1'b1;
            else instr32_o = {imm[11:0], rd, 3'b000, rd, OP_IMM_32};
          end

          3'b010: begin  // C.LI → ADDI rd, x0, imm
            imm = {{27{instr16_i[12]}}, instr16_i[6:2]};
            instr32_o = {imm[11:0], REG_X0, 3'b000, rd, OP_IMM};
          end

          3'b011: begin  // C.LUI / C.ADDI16SP
            if (rd == REG_X2) begin  // C.ADDI16SP → ADDI x2, x2, nzimm
              nzimm = {{23{instr16_i[12]}}, instr16_i[4:3], instr16_i[5],
                       instr16_i[2], instr16_i[6], 4'b0};
              if (nzimm == {INST_W{1'b0}}) illegal_o = 1'b1;
              else instr32_o = {nzimm[11:0], REG_X2, 3'b000, REG_X2, OP_IMM};
            end else begin  // C.LUI → LUI rd, nzimm
              nzimm = {{15{instr16_i[12]}}, instr16_i[6:2], 12'b0};
              if (nzimm == {INST_W{1'b0}}) illegal_o = 1'b1;
              else instr32_o = {nzimm[31:12], rd, OP_LUI};
            end
          end

          3'b100: begin  // C.SRLI / C.SRAI / C.ANDI / C.SUB/XOR/OR/AND / C.SUBW/C.ADDW
            shamt = {instr16_i[12], instr16_i[6:2]};
            unique case (instr16_i[11:10])

              2'b00: begin  // C.SRLI → SRLI rs1', rs1', shamt
                if (shamt == 6'd0) illegal_o = 1'b1;
                else instr32_o = {6'b000_000, shamt, rs1_full,
                                  3'b101, rs1_full, OP_IMM};
              end

              2'b01: begin  // C.SRAI → SRAI rs1', rs1', shamt
                if (shamt == 6'd0) illegal_o = 1'b1;
                else instr32_o = {6'b010_000, shamt, rs1_full,
                                  3'b101, rs1_full, OP_IMM};
              end

              2'b10: begin  // C.ANDI → ANDI rs1', rs1', imm
                imm = {{27{instr16_i[12]}}, instr16_i[6:2]};
                instr32_o = {imm[11:0], rs1_full, 3'b111, rs1_full, OP_IMM};
              end

              2'b11: begin
                if (instr16_i[12] == 1'b0) begin
                  // RV32C: C.SUB, C.XOR, C.OR, C.AND
                  unique case (instr16_i[6:5])
                    2'b00: instr32_o = {7'b010_0000, rs2_full, rs1_full,
                                        3'b000, rs1_full, OP_REG};
                    2'b01: instr32_o = {7'b000_0000, rs2_full, rs1_full,
                                        3'b100, rs1_full, OP_REG};
                    2'b10: instr32_o = {7'b000_0000, rs2_full, rs1_full,
                                        3'b110, rs1_full, OP_REG};
                    2'b11: instr32_o = {7'b000_0000, rs2_full, rs1_full,
                                        3'b111, rs1_full, OP_REG};
                    default: illegal_o = 1'b1;
                  endcase
                end else begin
                  // RV64C: C.SUBW, C.ADDW
                  unique case (instr16_i[6:5])
                    2'b00: instr32_o = {7'b010_0000, rs2_full, rs1_full,
                                        3'b000, rs1_full, OP_REG_32};  // C.SUBW
                    2'b01: instr32_o = {7'b000_0000, rs2_full, rs1_full,
                                        3'b000, rs1_full, OP_REG_32};  // C.ADDW
                    default: illegal_o = 1'b1;  // bits [6:5]=10/11 reserved
                  endcase
                end
              end

              default: illegal_o = 1'b1;
            endcase
          end

          3'b101: begin  // C.J → JAL x0, offset
            imm = {{21{instr16_i[12]}}, instr16_i[8], instr16_i[10:9],
                   instr16_i[6], instr16_i[7], instr16_i[2], instr16_i[11],
                   instr16_i[5:3], 1'b0};
            instr32_o = {imm[20], imm[10:1], imm[11], imm[19:12],
                         REG_X0, OP_JAL};
          end

          3'b110: begin  // C.BEQZ → BEQ rs1', x0, offset
            off = {{24{instr16_i[12]}}, instr16_i[6:5], instr16_i[2],
                   instr16_i[11:10], instr16_i[4:3], 1'b0};
            instr32_o = {off[12], off[10:5], REG_X0, rs1_full, 3'b000,
                         off[4:1], off[11], OP_BRNCH};
          end

          3'b111: begin  // C.BNEZ → BNE rs1', x0, offset
            off = {{24{instr16_i[12]}}, instr16_i[6:5], instr16_i[2],
                   instr16_i[11:10], instr16_i[4:3], 1'b0};
            instr32_o = {off[12], off[10:5], REG_X0, rs1_full, 3'b001,
                         off[4:1], off[11], OP_BRNCH};
          end

          default: illegal_o = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 2
      // ---------------------------------------------------------------
      2'b10: begin
        unique case (funct3)

          3'b000: begin  // C.SLLI → SLLI rd, rd, shamt
            shamt = {instr16_i[12], instr16_i[6:2]};
            if (shamt == 6'd0 || rd == REG_X0) illegal_o = 1'b1;
            else instr32_o = {6'b000_000, shamt, rd, 3'b001, rd, OP_IMM};
          end

          3'b001: begin  // RV64C: C.FLDSP → FLD fd, uimm(x2)
            uimm = {3'b0, instr16_i[4:2], instr16_i[12], instr16_i[6:5], 3'b0};
            instr32_o = {uimm, REG_X2, 3'b011, rd, OP_LOAD_FP};
          end

          3'b011: begin  // RV64C: C.LDSP → LD rd, uimm(x2)
            uimm = {3'b0, instr16_i[4:2], instr16_i[12], instr16_i[6:5], 3'b0};
            if (rd == REG_X0) illegal_o = 1'b1;
            else instr32_o = {uimm, REG_X2, 3'b011, rd, OP_LOAD};
          end

          3'b010: begin  // C.LWSP → LW rd, offset(x2)
            uimm = {4'b0, instr16_i[3:2], instr16_i[12], instr16_i[6:4], 2'b0};
            if (rd == REG_X0) illegal_o = 1'b1;
            else instr32_o = {uimm, REG_X2, 3'b010, rd, OP_LOAD};
          end

          3'b100: begin  // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
            if (instr16_i[12] == 1'b0) begin
              if (rs2 == REG_X0 && rs1 != REG_X0) begin
                instr32_o = {12'd0, rs1, 3'b000, REG_X0, OP_JALR};  // C.JR
              end else if (rs2 != REG_X0) begin
                instr32_o = {7'b000_0000, rs2, REG_X0, 3'b000, rd, OP_REG};  // C.MV
              end else begin
                illegal_o = 1'b1;
              end
            end else begin
              if (rs1 == REG_X0 && rs2 == REG_X0) begin
                instr32_o = 32'h00100073;  // C.EBREAK
              end else if (rs2 == REG_X0 && rs1 != REG_X0) begin
                instr32_o = {12'd0, rs1, 3'b000, REG_X1, OP_JALR};  // C.JALR
              end else if (rs2 != REG_X0) begin
                instr32_o = {7'b000_0000, rs2, rd, 3'b000, rd, OP_REG};  // C.ADD
              end else begin
                illegal_o = 1'b1;
              end
            end
          end

          3'b101: begin  // RV64C: C.FSDSP → FSD fs2, uimm(x2)
            uimm = {3'b0, instr16_i[9:7], instr16_i[12:10], 3'b0};
            instr32_o = {uimm[11:5], rs2, REG_X2, 3'b011, uimm[4:0], OP_STORE_FP};
          end

          3'b111: begin  // RV64C: C.SDSP → SD rs2, uimm(x2)
            uimm = {3'b0, instr16_i[9:7], instr16_i[12:10], 3'b0};
            instr32_o = {uimm[11:5], rs2, REG_X2, 3'b011, uimm[4:0], OP_STORE};
          end

          3'b110: begin  // C.SWSP → SW rs2, offset(x2)
            uimm = {4'b0, instr16_i[8:7], instr16_i[12:9], 2'b0};
            instr32_o = {uimm[11:5], rs2, REG_X2, 3'b010, uimm[4:0], OP_STORE};
          end

          default: illegal_o = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // 2'b11 — 32-bit instruction, not a compressed encoding
      // ---------------------------------------------------------------
      default: illegal_o = 1'b1;

    endcase
  end

endmodule
