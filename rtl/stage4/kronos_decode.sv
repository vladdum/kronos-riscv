// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode.sv (stage4) — RV64IMAC instruction decoder.
// Extends the stage2 RV32IM decoder with:
//   - OP-IMM 6-bit shamts (RV64 SLLI/SRLI/SRAI)
//   - LOAD funct3=011 (LD), 110 (LWU); only 111 illegal
//   - STORE funct3=011 (SD); funct3>011 illegal
//   - OP-IMM-32 (0011011): ADDIW/SLLIW/SRLIW/SRAIW
//   - OP-32    (0111011): ADDW/SUBW/SLLW/SRLW/SRAW + MULW/DIVW/DIVUW/REMW/REMUW
//   - AMO      (0101111): LR/SC/AMO*
// Defaults for new fields (is_word_op, is_lr, is_sc, is_amo, amo_funct5) come
// from the kronos_pkg::DECODED_INSTR_ZERO assignment at the top of always_comb, which
// zero-initialises every field of the decoded_instr_t struct.
module kronos_decode
  import kronos_pkg::*;
(
  input  logic [31:0]    instr_i,
  output decoded_instr_t dec_o
);

  // 1. Constants — opcode encodings
  localparam logic [6:0] OP         = 7'b011_0011; // R-type
  localparam logic [6:0] OP_IMM     = 7'b001_0011; // I-type ALU
  localparam logic [6:0] OP_IMM_32  = 7'b001_1011; // RV64 I-type ALU-W
  localparam logic [6:0] OP_32      = 7'b011_1011; // RV64 R-type ALU-W
  localparam logic [6:0] LOAD       = 7'b000_0011;
  localparam logic [6:0] STORE      = 7'b010_0011;
  localparam logic [6:0] BRANCH     = 7'b110_0011;
  localparam logic [6:0] LUI        = 7'b011_0111;
  localparam logic [6:0] AUIPC      = 7'b001_0111;
  localparam logic [6:0] JAL        = 7'b110_1111;
  localparam logic [6:0] JALR       = 7'b110_0111;
  localparam logic [6:0] SYSTEM     = 7'b111_0011;
  localparam logic [6:0] AMO        = 7'b010_1111;

  // 4. Combinational signals — instruction fields
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
      OP: begin  // R-type: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND + M-ext
        dec_o.rs1_used = 1'b1;
        dec_o.rs2_used = 1'b1;
        dec_o.rd_wen   = 1'b1;
        dec_o.wb_sel   = WB_ALU;

        if (funct7 == 7'b000_0001) begin
          // M extension: MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
          dec_o.is_muldiv = 1'b1;
          dec_o.muldiv_op = muldiv_op_e'(funct3);
          dec_o.use_imm   = 1'b0;
          dec_o.alu_op    = ALU_ADD; // don't-care; ALU result is discarded
        end else begin
          dec_o.use_imm = 1'b0;
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
          3'b001: begin  // SLLI (6-bit shamt in RV64)
            dec_o.alu_op = ALU_SLL;
            dec_o.imm    = {26'b0, instr_i[25:20]};
            if (funct7[6:1] != 6'b000_000) dec_o.illegal = 1'b1;
          end
          3'b101: begin  // SRLI / SRAI (6-bit shamt in RV64)
            dec_o.imm = {26'b0, instr_i[25:20]};
            if      (funct7[6:1] == 6'b000_000) dec_o.alu_op = ALU_SRL;
            else if (funct7[6:1] == 6'b010_000) dec_o.alu_op = ALU_SRA;
            else                                dec_o.illegal = 1'b1;
          end
          default: dec_o.illegal = 1'b1;
        endcase
      end

      OP_IMM_32: begin  // ADDIW / SLLIW / SRLIW / SRAIW
        dec_o.rs1_used   = 1'b1;
        dec_o.rd_wen     = 1'b1;
        dec_o.use_imm    = 1'b1;
        dec_o.wb_sel     = WB_ALU;
        dec_o.is_word_op = 1'b1;
        dec_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: dec_o.alu_op = ALU_ADD;
          3'b001: begin  // SLLIW
            dec_o.alu_op = ALU_SLL;
            dec_o.imm    = {27'b0, instr_i[24:20]};
            if (funct7 != 7'b000_0000) dec_o.illegal = 1'b1;
          end
          3'b101: begin  // SRLIW / SRAIW
            dec_o.imm = {27'b0, instr_i[24:20]};
            if      (funct7 == 7'b000_0000) dec_o.alu_op = ALU_SRL;
            else if (funct7 == 7'b010_0000) dec_o.alu_op = ALU_SRA;
            else                            dec_o.illegal = 1'b1;
          end
          default: dec_o.illegal = 1'b1;
        endcase
      end

      OP_32: begin  // ADDW / SUBW / SLLW / SRLW / SRAW + MULW/DIVW/DIVUW/REMW/REMUW
        dec_o.rs1_used   = 1'b1;
        dec_o.rs2_used   = 1'b1;
        dec_o.rd_wen     = 1'b1;
        dec_o.wb_sel     = WB_ALU;
        dec_o.is_word_op = 1'b1;

        if (funct7 == 7'b000_0001) begin
          dec_o.is_muldiv = 1'b1;
          dec_o.muldiv_op = muldiv_op_e'(funct3);
          dec_o.use_imm   = 1'b0;
          dec_o.alu_op    = ALU_ADD;
          if (funct3 > 3'b000 && funct3 < 3'b100) dec_o.illegal = 1'b1;
        end else begin
          dec_o.use_imm = 1'b0;
          unique case ({funct7, funct3})
            {7'b000_0000, 3'b000}: dec_o.alu_op = ALU_ADD;
            {7'b010_0000, 3'b000}: dec_o.alu_op = ALU_SUB;
            {7'b000_0000, 3'b001}: dec_o.alu_op = ALU_SLL;
            {7'b000_0000, 3'b101}: dec_o.alu_op = ALU_SRL;
            {7'b010_0000, 3'b101}: dec_o.alu_op = ALU_SRA;
            default:               dec_o.illegal = 1'b1;
          endcase
        end
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

      LOAD: begin  // LB, LH, LW, LBU, LHU + RV64 LD, LWU
        dec_o.rs1_used   = 1'b1;
        dec_o.rd_wen     = 1'b1;
        dec_o.use_imm    = 1'b1;
        dec_o.alu_op     = ALU_ADD;
        dec_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        dec_o.is_load    = 1'b1;
        dec_o.mem_funct3 = funct3;
        dec_o.wb_sel     = WB_MEM;
        if (funct3 == 3'b111) dec_o.illegal = 1'b1; // reserved in RV64
      end

      STORE: begin  // SB, SH, SW + RV64 SD
        dec_o.rs1_used   = 1'b1;
        dec_o.rs2_used   = 1'b1;
        dec_o.use_imm    = 1'b1;
        dec_o.alu_op     = ALU_ADD;
        dec_o.imm        = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        dec_o.is_store   = 1'b1;
        dec_o.mem_funct3 = funct3;
        dec_o.wb_sel     = WB_ALU;
        dec_o.rd_wen     = 1'b0;
        if (funct3 > 3'b011) dec_o.illegal = 1'b1; // only SB/SH/SW/SD
      end

      AMO: begin  // LR.W/D, SC.W/D, AMO*.W/D
        dec_o.rs1_used   = 1'b1;
        dec_o.rd_wen     = 1'b1;
        dec_o.wb_sel     = WB_MEM;
        dec_o.mem_funct3 = funct3;
        dec_o.use_imm    = 1'b1;
        dec_o.alu_op     = ALU_ADD;
        dec_o.imm        = 32'd0;

        unique case (funct7[6:2])
          5'b00010: begin
            dec_o.is_load = 1'b1;
            dec_o.is_lr   = 1'b1;
          end
          5'b00011: begin
            dec_o.is_store = 1'b1;
            dec_o.is_sc    = 1'b1;
            dec_o.rs2_used = 1'b1;
          end
          default: begin
            dec_o.is_amo     = 1'b1;
            dec_o.amo_funct5 = funct7[6:2];
            dec_o.rs2_used   = 1'b1;
          end
        endcase

        if (funct3 != 3'b010 && funct3 != 3'b011) dec_o.illegal = 1'b1;
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
