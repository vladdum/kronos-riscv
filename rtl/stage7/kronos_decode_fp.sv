// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode_fp.sv — FP sub-decoder.
// Owns OP_FP (funct7[6:2] dispatch table) and the four FMA opcodes
// (FMADD/FMSUB/FNMSUB/FNMADD). The only sub-decoder that consumes frm_i.

module kronos_decode_fp
  import kronos_pkg::*;
(
  input  logic [kronos_pkg::INST_W-1:0] instr_i,
  input  logic [2:0]                    frm_i,
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
      OP_FP: begin
        decoded_o.is_fp = 1'b1;
        decoded_o.fmt_d = instr_i[25];

        unique case (funct7[6:2])
          5'b00000: begin  // FADD.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            decoded_o.fp_op  = FP_FADD;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b00001: begin  // FSUB.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            decoded_o.fp_op  = FP_FSUB;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b00010: begin  // FMUL.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            decoded_o.fp_op  = FP_FMUL;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b00011: begin  // FDIV.S/D
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            decoded_o.fp_op  = FP_FDIV;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b00100: begin  // FSGNJ / FSGNJN / FSGNJX
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
          5'b00101: begin  // FMIN / FMAX
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rs2_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            unique case (funct3)
              3'b000:  decoded_o.fp_op = FP_FMIN;
              3'b001:  decoded_o.fp_op = FP_FMAX;
              default: illegal = 1'b1;
            endcase
          end
          5'b01000: begin  // FCVT.S.D / FCVT.D.S
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            unique case (funct7[1:0])
              2'b01:   decoded_o.fp_op = FP_FCVT_D_S;
              2'b00:   decoded_o.fp_op = FP_FCVT_S_D;
              default: illegal = 1'b1;
            endcase
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b01011: begin  // FSQRT
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_fp  = 1'b1;
            decoded_o.fp_op  = FP_FSQRT;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
            if (instr_i[24:20] != 5'b00000) illegal = 1'b1;
          end
          5'b10100: begin  // FEQ / FLT / FLE
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
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b11010: begin  // FCVT.F.W/WU/L/LU (int→FP)
            decoded_o.rd_fp = 1'b1;
            unique case (instr_i[24:20])
              5'b00000: decoded_o.fp_op = FP_FCVT_F_W;
              5'b00001: decoded_o.fp_op = FP_FCVT_F_WU;
              5'b00010: decoded_o.fp_op = FP_FCVT_F_L;
              5'b00011: decoded_o.fp_op = FP_FCVT_F_LU;
              default:  illegal = 1'b1;
            endcase
            decoded_o.rs1_used = 1'b1;
            decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
            if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
          end
          5'b11100: begin  // FMV.X.W / FMV.X.D / FCLASS
            decoded_o.rs1_fp = 1'b1;
            decoded_o.rd_wen = 1'b1;
            decoded_o.wb_sel = WB_ALU;
            if (instr_i[25] == 1'b0) begin
              unique case (funct3)
                3'b000:  decoded_o.fp_op = FP_FMV_X_W;
                3'b001:  decoded_o.fp_op = FP_FCLASS;
                default: illegal = 1'b1;
              endcase
            end else begin
              unique case (funct3)
                3'b000:  decoded_o.fp_op = FP_FMV_X_D;
                3'b001:  decoded_o.fp_op = FP_FCLASS;
                default: illegal = 1'b1;
              endcase
            end
          end
          5'b11110: begin  // FMV.W.X / FMV.D.X
            decoded_o.rs1_used = 1'b1;
            decoded_o.rd_fp    = 1'b1;
            if (instr_i[25] == 1'b0) decoded_o.fp_op = FP_FMV_W_X;
            else                     decoded_o.fp_op = FP_FMV_D_X;
          end
          default: illegal = 1'b1;
        endcase
      end

      FMADD_OP: begin
        decoded_o.is_fp  = 1'b1;
        decoded_o.rs1_fp = 1'b1;
        decoded_o.rs2_fp = 1'b1;
        decoded_o.rs3_fp = 1'b1;
        decoded_o.rd_fp  = 1'b1;
        decoded_o.rs3    = instr_i[31:27];
        decoded_o.fmt_d  = instr_i[25];
        decoded_o.fp_op  = FP_FMADD;
        decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
        if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
      end

      FMSUB_OP: begin
        decoded_o.is_fp  = 1'b1;
        decoded_o.rs1_fp = 1'b1;
        decoded_o.rs2_fp = 1'b1;
        decoded_o.rs3_fp = 1'b1;
        decoded_o.rd_fp  = 1'b1;
        decoded_o.rs3    = instr_i[31:27];
        decoded_o.fmt_d  = instr_i[25];
        decoded_o.fp_op  = FP_FMSUB;
        decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
        if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
      end

      FNMSUB_OP: begin
        decoded_o.is_fp  = 1'b1;
        decoded_o.rs1_fp = 1'b1;
        decoded_o.rs2_fp = 1'b1;
        decoded_o.rs3_fp = 1'b1;
        decoded_o.rd_fp  = 1'b1;
        decoded_o.rs3    = instr_i[31:27];
        decoded_o.fmt_d  = instr_i[25];
        decoded_o.fp_op  = FP_FNMSUB;
        decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
        if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
      end

      FNMADD_OP: begin
        decoded_o.is_fp  = 1'b1;
        decoded_o.rs1_fp = 1'b1;
        decoded_o.rs2_fp = 1'b1;
        decoded_o.rs3_fp = 1'b1;
        decoded_o.rd_fp  = 1'b1;
        decoded_o.rs3    = instr_i[31:27];
        decoded_o.fmt_d  = instr_i[25];
        decoded_o.fp_op  = FP_FNMADD;
        decoded_o.rm_resolved = kronos_pkg::resolve_rm(instr_i[14:12], frm_i);
        if (kronos_pkg::rm_is_illegal(decoded_o.rm_resolved)) illegal = 1'b1;
      end

      default: begin
        decoded_o = kronos_pkg::DECODED_INSTR_ZERO;
        illegal   = 1'b0;
      end
    endcase

    illegal_o = illegal;
  end

endmodule
