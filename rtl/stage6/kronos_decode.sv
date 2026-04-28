// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode.sv (stage5) — RV64IMAFDC instruction decoder.
// Extends the stage4 RV64IMAC decoder with:
//   - LOAD-FP  (0x07): FLW, FLD
//   - STORE-FP (0x27): FSW, FSD
//   - OP-FP    (0x53): FADD/FSUB/FMUL, FSGNJ*, FMIN/FMAX, FEQ/FLT/FLE,
//                      FCVT.*, FMV.*, FCLASS
//   - FMADD/FMSUB/FNMSUB/FNMADD (0x43/0x47/0x4B/0x4F)
//   - rm field resolution (dynamic FRM) + illegal-rm trap
// illegal_insn_o is asserted for any instruction that cannot be executed;
// the illegal flag is also mirrored into decoded_o.illegal for pipeline use.
module kronos_decode
  import kronos_pkg::*;
(
  input  logic [31:0]    instr_i,
  input  logic [2:0]     frm_i,        // current FRM from FCSR (for dynamic rm)
  output decoded_instr_t decoded_o,
  output logic           illegal_insn_o
);

  // Instruction fields
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

  // Opcode constants
  localparam logic [6:0] OP         = 7'b011_0011; // R-type
  localparam logic [6:0] OP_IMM     = 7'b001_0011; // I-type ALU
  localparam logic [6:0] OP_IMM_32  = 7'b001_1011; // RV64 I-type ALU-W
  localparam logic [6:0] OP_32      = 7'b011_1011; // RV64 R-type ALU-W
  localparam logic [6:0] LOAD       = 7'b000_0011;
  localparam logic [6:0] STORE      = 7'b010_0011;
  localparam logic [6:0] LOAD_FP    = 7'b000_0111;
  localparam logic [6:0] STORE_FP   = 7'b010_0111;
  localparam logic [6:0] OP_FP      = 7'b101_0011;
  localparam logic [6:0] FMADD_OP   = 7'b100_0011;
  localparam logic [6:0] FMSUB_OP   = 7'b100_0111;
  localparam logic [6:0] FNMSUB_OP  = 7'b100_1011;
  localparam logic [6:0] FNMADD_OP  = 7'b100_1111;
  localparam logic [6:0] BRANCH     = 7'b110_0011;
  localparam logic [6:0] LUI        = 7'b011_0111;
  localparam logic [6:0] AUIPC      = 7'b001_0111;
  localparam logic [6:0] JAL        = 7'b110_1111;
  localparam logic [6:0] JALR       = 7'b110_0111;
  localparam logic [6:0] SYSTEM     = 7'b111_0011;
  localparam logic [6:0] AMO        = 7'b010_1111;

  // Internal signal for illegal
  logic illegal;

  // Resolves the FP rounding mode field, substituting frm when rm_in=DYN (111).
  function automatic logic [2:0] resolve_rm(input logic [2:0] rm_in, input logic [2:0] frm);
    return (rm_in == 3'b111) ? frm : rm_in;
  endfunction
  function automatic logic rm_is_illegal(input logic [2:0] rm);
    return (rm == 3'b101) || (rm == 3'b110);
  endfunction

  always_comb begin
    decoded_o          = '0;
    decoded_o.rs1      = rs1;
    decoded_o.rs2      = rs2;
    decoded_o.rd       = rd;
    illegal            = 1'b0;

    unique case (opcode)
      OP: begin  // R-type: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND + M-ext
        decoded_o.rs1_used = 1'b1;
        decoded_o.rs2_used = 1'b1;
        decoded_o.rd_wen   = 1'b1;
        decoded_o.wb_sel   = WB_ALU;

        if (funct7 == 7'b000_0001) begin
          // M extension: MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
          decoded_o.is_muldiv = 1'b1;
          decoded_o.muldiv_op = muldiv_op_e'(funct3);
          decoded_o.use_imm   = 1'b0;
          decoded_o.alu_op    = ALU_ADD; // don't-care; ALU result is discarded
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

      OP_IMM: begin  // I-type ALU: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
        decoded_o.rs1_used = 1'b1;
        decoded_o.rd_wen   = 1'b1;
        decoded_o.use_imm  = 1'b1;
        decoded_o.wb_sel   = WB_ALU;
        decoded_o.imm      = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: decoded_o.alu_op = ALU_ADD;   // ADDI
          3'b010: decoded_o.alu_op = ALU_SLT;   // SLTI
          3'b011: decoded_o.alu_op = ALU_SLTU;  // SLTIU
          3'b100: decoded_o.alu_op = ALU_XOR;   // XORI
          3'b110: decoded_o.alu_op = ALU_OR;    // ORI
          3'b111: decoded_o.alu_op = ALU_AND;   // ANDI
          3'b001: begin  // SLLI (6-bit shamt in RV64)
            decoded_o.alu_op = ALU_SLL;
            decoded_o.imm    = {26'b0, instr_i[25:20]};
            if (funct7[6:1] != 6'b000_000) illegal = 1'b1;
          end
          3'b101: begin  // SRLI / SRAI (6-bit shamt in RV64)
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

      OP_IMM_32: begin  // ADDIW / SLLIW / SRLIW / SRAIW
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.is_word_op = 1'b1;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        unique case (funct3)
          3'b000: decoded_o.alu_op = ALU_ADD;
          3'b001: begin  // SLLIW
            decoded_o.alu_op = ALU_SLL;
            decoded_o.imm    = {27'b0, instr_i[24:20]};
            if (funct7 != 7'b000_0000) illegal = 1'b1;
          end
          3'b101: begin  // SRLIW / SRAIW
            decoded_o.imm = {27'b0, instr_i[24:20]};
            if      (funct7 == 7'b000_0000) decoded_o.alu_op = ALU_SRL;
            else if (funct7 == 7'b010_0000) decoded_o.alu_op = ALU_SRA;
            else                            illegal = 1'b1;
          end
          default: illegal = 1'b1;
        endcase
      end

      OP_32: begin  // ADDW / SUBW / SLLW / SRLW / SRAW + MULW/DIVW/DIVUW/REMW/REMUW
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

      JAL: begin
        decoded_o.rd_wen = 1'b1;
        decoded_o.is_jal = 1'b1;
        // J-type immediate: imm[20|10:1|11|19:12], bit 0 always 0
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

      BRANCH: begin  // BEQ, BNE, BLT, BGE, BLTU, BGEU
        decoded_o.rs1_used      = 1'b1;
        decoded_o.rs2_used      = 1'b1;
        decoded_o.is_branch     = 1'b1;
        decoded_o.branch_funct3 = funct3;
        // B-type immediate: imm[12|10:5|4:1|11], bit 0 always 0
        decoded_o.imm = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                         instr_i[30:25], instr_i[11:8], 1'b0};
        if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
      end

      LOAD: begin  // LB, LH, LW, LBU, LHU + RV64 LD, LWU
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rd_wen     = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:20]};
        decoded_o.is_load    = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_MEM;
        if (funct3 == 3'b111) illegal = 1'b1; // reserved in RV64
      end

      STORE: begin  // SB, SH, SW + RV64 SD
        decoded_o.rs1_used   = 1'b1;
        decoded_o.rs2_used   = 1'b1;
        decoded_o.use_imm    = 1'b1;
        decoded_o.alu_op     = ALU_ADD;
        decoded_o.imm        = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
        decoded_o.is_store   = 1'b1;
        decoded_o.mem_funct3 = funct3;
        decoded_o.wb_sel     = WB_ALU;
        decoded_o.rd_wen     = 1'b0;
        if (funct3 > 3'b011) illegal = 1'b1; // only SB/SH/SW/SD
      end

      AMO: begin  // LR.W/D, SC.W/D, AMO*.W/D
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

      SYSTEM: begin
        unique case (funct3)
          3'b000: begin  // ECALL, EBREAK, MRET, SRET, SFENCE.VMA, WFI
            // SFENCE.VMA — funct7 = 0x09 (Stage 6b: real op)
            if (instr_i[31:25] == 7'b000_1001) begin
              decoded_o.is_sfence_vma = 1'b1;
              illegal                 = 1'b0;
            end else begin
              unique case (instr_i[31:20])
                12'h000: decoded_o.is_ecall  = 1'b1;
                12'h001: decoded_o.is_ebreak = 1'b1;
                12'h302: decoded_o.is_mret   = 1'b1;
                12'h102: decoded_o.is_sret   = 1'b1;  // Stage 6a
                12'h105: decoded_o.is_wfi    = 1'b1;  // Stage 6b
                default: illegal             = 1'b1;
              endcase
            end
          end
          default: begin  // CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
            decoded_o.is_csr      = 1'b1;
            decoded_o.rd_wen      = 1'b1;
            decoded_o.rs1_used    = ~funct3[2]; // funct3[2]=1 means zimm form
            decoded_o.csr_addr    = instr_i[31:20];
            decoded_o.csr_funct3  = funct3;
            decoded_o.csr_use_imm = funct3[2];
            decoded_o.wb_sel      = WB_CSR;
          end
        endcase
      end

      // -----------------------------------------------------------------------
      // Stage 5a: Floating-point instructions
      // -----------------------------------------------------------------------

      LOAD_FP: begin  // FLW (funct3=010) / FLD (funct3=011)
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

      STORE_FP: begin  // FSW (funct3=010) / FSD (funct3=011)
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

      OP_FP: begin  // FP arithmetic, compare, convert, move
        decoded_o.is_fp = 1'b1;
        decoded_o.fmt_d = instr_i[25]; // bit 25: 0=single, 1=double

        unique case (funct7[6:2])
          5'b00000: begin  // FADD.S/D
            decoded_o.rs1_fp     = 1'b1;
            decoded_o.rs2_fp     = 1'b1;
            decoded_o.rd_fp      = 1'b1;
            decoded_o.fp_op      = FP_FADD;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b00001: begin  // FSUB.S/D
            decoded_o.rs1_fp     = 1'b1;
            decoded_o.rs2_fp     = 1'b1;
            decoded_o.rd_fp      = 1'b1;
            decoded_o.fp_op      = FP_FSUB;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b00010: begin  // FMUL.S/D
            decoded_o.rs1_fp     = 1'b1;
            decoded_o.rs2_fp     = 1'b1;
            decoded_o.rd_fp      = 1'b1;
            decoded_o.fp_op      = FP_FMUL;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b00011: begin  // FDIV.S/D
            decoded_o.rs1_fp     = 1'b1;
            decoded_o.rs2_fp     = 1'b1;
            decoded_o.rd_fp      = 1'b1;
            decoded_o.fp_op      = FP_FDIV;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b00100: begin  // FSGNJ.S/D, FSGNJN.S/D, FSGNJX.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            unique case (funct3)
              3'b000:  decoded_o.fp_op = FP_FSGNJ;
              3'b001:  decoded_o.fp_op = FP_FSGNJN;
              3'b010:  decoded_o.fp_op = FP_FSGNJX;
              default: illegal = 1'b1;
            endcase
          end
          5'b00101: begin  // FMIN.S/D, FMAX.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            unique case (funct3)
              3'b000:  decoded_o.fp_op = FP_FMIN;
              3'b001:  decoded_o.fp_op = FP_FMAX;
              default: illegal = 1'b1;
            endcase
          end
          5'b01000: begin  // FCVT.S.D / FCVT.D.S (inter-format conversion)
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            unique case (funct7[1:0])
              2'b01: decoded_o.fp_op = FP_FCVT_D_S;  // FCVT.D.S (S→D): funct7=0x21
              2'b00: decoded_o.fp_op = FP_FCVT_S_D;  // FCVT.S.D (D→S): funct7=0x20
              default: illegal = 1'b1;
            endcase
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b01011: begin  // FSQRT.S/D
            decoded_o.rs1_fp     = 1'b1;
            decoded_o.rd_fp      = 1'b1;
            decoded_o.fp_op      = FP_FSQRT;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
            // rs2 must be 00000 for FSQRT
            if (instr_i[24:20] != 5'b00000) illegal = 1'b1;
          end
          5'b10100: begin  // FEQ/FLT/FLE (result to integer rd)
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_wen = 1'b1;
            decoded_o.wb_sel = WB_ALU;
            unique case (funct3)
              3'b010:  decoded_o.fp_op = FP_FEQ;
              3'b001:  decoded_o.fp_op = FP_FLT;
              3'b000:  decoded_o.fp_op = FP_FLE;
              default: illegal = 1'b1;
            endcase
          end
          5'b11000: begin  // FCVT.W/WU/L/LU.F (FP→int)
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_wen = 1'b1;
            decoded_o.wb_sel = WB_ALU;
            unique case (instr_i[24:20])
              5'b00000: decoded_o.fp_op = FP_FCVT_W_F;
              5'b00001: decoded_o.fp_op = FP_FCVT_WU_F;
              5'b00010: decoded_o.fp_op = FP_FCVT_L_F;
              5'b00011: decoded_o.fp_op = FP_FCVT_LU_F;
              default:  illegal = 1'b1;
            endcase
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b11010: begin  // FCVT.F.W/WU/L/LU (int→FP)
            decoded_o.rd_fp  = 1'b1;
            unique case (instr_i[24:20])
              5'b00000: decoded_o.fp_op = FP_FCVT_F_W;
              5'b00001: decoded_o.fp_op = FP_FCVT_F_WU;
              5'b00010: decoded_o.fp_op = FP_FCVT_F_L;
              5'b00011: decoded_o.fp_op = FP_FCVT_F_LU;
              default:  illegal = 1'b1;
            endcase
            decoded_o.rs1_used = 1'b1;
            begin
              decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
              if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            end
          end
          5'b11100: begin  // FMV.X.W / FMV.X.D / FCLASS.S / FCLASS.D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_wen = 1'b1;
            decoded_o.wb_sel = WB_ALU;
            if (instr_i[25] == 1'b0) begin
              // Single-precision: FMV.X.W or FCLASS.S
              unique case (funct3)
                3'b000:  decoded_o.fp_op = FP_FMV_X_W;
                3'b001:  decoded_o.fp_op = FP_FCLASS;
                default: illegal = 1'b1;
              endcase
            end else begin
              // Double-precision: FMV.X.D or FCLASS.D
              unique case (funct3)
                3'b000:  decoded_o.fp_op = FP_FMV_X_D;
                3'b001:  decoded_o.fp_op = FP_FCLASS;
                default: illegal = 1'b1;
              endcase
            end
          end
          5'b11110: begin  // FMV.W.X / FMV.D.X (integer→FP register)
            decoded_o.rs1_used = 1'b1;
            decoded_o.rd_fp    = 1'b1;
            if (instr_i[25] == 1'b0) begin
              decoded_o.fp_op = FP_FMV_W_X;
            end else begin
              decoded_o.fp_op = FP_FMV_D_X;
            end
          end
          default: illegal = 1'b1;
        endcase
      end

      // FMA variants: FMADD/FMSUB/FNMSUB/FNMADD
      FMADD_OP: begin
        decoded_o.is_fp   = 1'b1;
        decoded_o.rs1_fp  = 1'b1;
        decoded_o.rs2_fp  = 1'b1;
        decoded_o.rs3_fp  = 1'b1;
        decoded_o.rd_fp   = 1'b1;
        decoded_o.rs3     = instr_i[31:27];
        decoded_o.fmt_d   = instr_i[25];
        decoded_o.fp_op   = FP_FMADD;
        begin
          decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
          if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
        end
      end

      FMSUB_OP: begin
        decoded_o.is_fp   = 1'b1;
        decoded_o.rs1_fp  = 1'b1;
        decoded_o.rs2_fp  = 1'b1;
        decoded_o.rs3_fp  = 1'b1;
        decoded_o.rd_fp   = 1'b1;
        decoded_o.rs3     = instr_i[31:27];
        decoded_o.fmt_d   = instr_i[25];
        decoded_o.fp_op   = FP_FMSUB;
        begin
          decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
          if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
        end
      end

      FNMSUB_OP: begin
        decoded_o.is_fp   = 1'b1;
        decoded_o.rs1_fp  = 1'b1;
        decoded_o.rs2_fp  = 1'b1;
        decoded_o.rs3_fp  = 1'b1;
        decoded_o.rd_fp   = 1'b1;
        decoded_o.rs3     = instr_i[31:27];
        decoded_o.fmt_d   = instr_i[25];
        decoded_o.fp_op   = FP_FNMSUB;
        begin
          decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
          if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
        end
      end

      FNMADD_OP: begin
        decoded_o.is_fp   = 1'b1;
        decoded_o.rs1_fp  = 1'b1;
        decoded_o.rs2_fp  = 1'b1;
        decoded_o.rs3_fp  = 1'b1;
        decoded_o.rd_fp   = 1'b1;
        decoded_o.rs3     = instr_i[31:27];
        decoded_o.fmt_d   = instr_i[25];
        decoded_o.fp_op   = FP_FNMADD;
        begin
          decoded_o.rm_resolved = resolve_rm(instr_i[14:12], frm_i);
          if (rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
        end
      end

      default: illegal = 1'b1;
    endcase

    decoded_o.illegal = illegal;
    illegal_insn_o    = illegal;
  end

endmodule
