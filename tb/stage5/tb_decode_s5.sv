// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_decode_s5;
  import kronos_pkg::*;

  logic [31:0]    instr;
  logic [2:0]     frm;
  decoded_instr_t dec;
  logic           illegal;
  int errors = 0;

  kronos_decode dut (
    .instr_i       (instr),
    .frm_i         (frm),
    .decoded_o     (dec),
    .illegal_insn_o(illegal)
  );

  task check_field(string name, logic [63:0] got, logic [63:0] expected);
    if (got !== expected) begin
      $display("FAIL %s: got %0h, expected %0h (instr=%08h)", name, got, expected, instr);
      errors++;
    end
  endtask

  initial begin
    frm = 3'b000;

    // ── OP (R-type, funct7=0): ADD SUB SLL SLT SLTU XOR SRL SRA OR AND ─────
    instr = {7'b000_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_0011}; #1; // ADD
    check_field("ADD.alu_op",     dec.alu_op,     ALU_ADD);
    check_field("ADD.rd_wen",     dec.rd_wen,     1);
    check_field("ADD.is_word",    dec.is_word_op, 0);
    check_field("ADD.illegal",    dec.illegal,    0);

    instr = {7'b010_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_0011}; #1; // SUB
    check_field("SUB.alu_op",     dec.alu_op,     ALU_SUB);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b001, 5'd1, 7'b011_0011}; #1; // SLL
    check_field("SLL.alu_op",     dec.alu_op,     ALU_SLL);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b010, 5'd1, 7'b011_0011}; #1; // SLT
    check_field("SLT.alu_op",     dec.alu_op,     ALU_SLT);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b011, 5'd1, 7'b011_0011}; #1; // SLTU
    check_field("SLTU.alu_op",    dec.alu_op,     ALU_SLTU);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b100, 5'd1, 7'b011_0011}; #1; // XOR
    check_field("XOR.alu_op",     dec.alu_op,     ALU_XOR);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b101, 5'd1, 7'b011_0011}; #1; // SRL
    check_field("SRL.alu_op",     dec.alu_op,     ALU_SRL);

    instr = {7'b010_0000, 5'd3, 5'd2, 3'b101, 5'd1, 7'b011_0011}; #1; // SRA
    check_field("SRA.alu_op",     dec.alu_op,     ALU_SRA);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b110, 5'd1, 7'b011_0011}; #1; // OR
    check_field("OR.alu_op",      dec.alu_op,     ALU_OR);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b111, 5'd1, 7'b011_0011}; #1; // AND
    check_field("AND.alu_op",     dec.alu_op,     ALU_AND);

    // MUL / DIV / REM (M-extension, funct7=1)
    instr = {7'b000_0001, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_0011}; #1; // MUL
    check_field("MUL.is_muldiv",  dec.is_muldiv,  1);
    check_field("MUL.muldiv_op",  dec.muldiv_op,  MULDIV_MUL);

    instr = {7'b000_0001, 5'd3, 5'd2, 3'b100, 5'd1, 7'b011_0011}; #1; // DIV
    check_field("DIV.is_muldiv",  dec.is_muldiv,  1);
    check_field("DIV.muldiv_op",  dec.muldiv_op,  MULDIV_DIV);

    instr = {7'b000_0001, 5'd3, 5'd2, 3'b110, 5'd1, 7'b011_0011}; #1; // REM
    check_field("REM.is_muldiv",  dec.is_muldiv,  1);
    check_field("REM.muldiv_op",  dec.muldiv_op,  MULDIV_REM);

    // ── OP_IMM (I-type ALU) ───────────────────────────────────────────────
    instr = {12'd10, 5'd2, 3'b000, 5'd1, 7'b001_0011}; #1; // ADDI
    check_field("ADDI.alu_op",    dec.alu_op,     ALU_ADD);
    check_field("ADDI.use_imm",   dec.use_imm,    1);
    check_field("ADDI.imm",       dec.imm,        64'd10);
    check_field("ADDI.illegal",   dec.illegal,    0);

    instr = {12'd1, 5'd2, 3'b010, 5'd1, 7'b001_0011}; #1; // SLTI
    check_field("SLTI.alu_op",    dec.alu_op,     ALU_SLT);

    instr = {12'd1, 5'd2, 3'b011, 5'd1, 7'b001_0011}; #1; // SLTIU
    check_field("SLTIU.alu_op",   dec.alu_op,     ALU_SLTU);

    instr = {12'hAA, 5'd2, 3'b100, 5'd1, 7'b001_0011}; #1; // XORI
    check_field("XORI.alu_op",    dec.alu_op,     ALU_XOR);

    instr = {12'hAA, 5'd2, 3'b110, 5'd1, 7'b001_0011}; #1; // ORI
    check_field("ORI.alu_op",     dec.alu_op,     ALU_OR);

    instr = {12'hAA, 5'd2, 3'b111, 5'd1, 7'b001_0011}; #1; // ANDI
    check_field("ANDI.alu_op",    dec.alu_op,     ALU_AND);

    instr = {6'b000_000, 6'd10, 5'd2, 3'b001, 5'd1, 7'b001_0011}; #1; // SLLI (6-bit shamt)
    check_field("SLLI.alu_op",    dec.alu_op,     ALU_SLL);
    check_field("SLLI.imm",       dec.imm,        64'd10);
    check_field("SLLI.illegal",   dec.illegal,    0);

    instr = {6'b000_000, 6'd10, 5'd2, 3'b101, 5'd1, 7'b001_0011}; #1; // SRLI
    check_field("SRLI.alu_op",    dec.alu_op,     ALU_SRL);

    instr = {6'b010_000, 6'd10, 5'd2, 3'b101, 5'd1, 7'b001_0011}; #1; // SRAI
    check_field("SRAI.alu_op",    dec.alu_op,     ALU_SRA);

    // ── OP_IMM_32 (W-suffix I-type) ───────────────────────────────────────
    instr = 32'h0051_009B; #1; // ADDIW x1, x2, 5
    check_field("ADDIW.alu_op",   dec.alu_op,     ALU_ADD);
    check_field("ADDIW.is_word",  dec.is_word_op, 1);
    check_field("ADDIW.rd_wen",   dec.rd_wen,     1);
    check_field("ADDIW.illegal",  dec.illegal,    0);

    instr = {7'b000_0000, 5'd5, 5'd4, 3'b001, 5'd3, 7'b001_1011}; #1; // SLLIW
    check_field("SLLIW.alu_op",   dec.alu_op,     ALU_SLL);
    check_field("SLLIW.is_word",  dec.is_word_op, 1);

    instr = {7'b000_0000, 5'd3, 5'd6, 3'b101, 5'd5, 7'b001_1011}; #1; // SRLIW
    check_field("SRLIW.alu_op",   dec.alu_op,     ALU_SRL);

    instr = {7'b010_0000, 5'd3, 5'd8, 3'b101, 5'd7, 7'b001_1011}; #1; // SRAIW
    check_field("SRAIW.alu_op",   dec.alu_op,     ALU_SRA);

    // ── OP_32 (W-suffix R-type) ───────────────────────────────────────────
    instr = {7'b000_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_1011}; #1; // ADDW
    check_field("ADDW.alu_op",    dec.alu_op,     ALU_ADD);
    check_field("ADDW.is_word",   dec.is_word_op, 1);

    instr = {7'b010_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_1011}; #1; // SUBW
    check_field("SUBW.alu_op",    dec.alu_op,     ALU_SUB);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b001, 5'd1, 7'b011_1011}; #1; // SLLW
    check_field("SLLW.alu_op",    dec.alu_op,     ALU_SLL);

    instr = {7'b000_0000, 5'd3, 5'd2, 3'b101, 5'd1, 7'b011_1011}; #1; // SRLW
    check_field("SRLW.alu_op",    dec.alu_op,     ALU_SRL);

    instr = {7'b010_0000, 5'd3, 5'd2, 3'b101, 5'd1, 7'b011_1011}; #1; // SRAW
    check_field("SRAW.alu_op",    dec.alu_op,     ALU_SRA);

    instr = {7'b000_0001, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_1011}; #1; // MULW
    check_field("MULW.is_muldiv", dec.is_muldiv,  1);
    check_field("MULW.muldiv_op", dec.muldiv_op,  MULDIV_MUL);

    instr = {7'b000_0001, 5'd3, 5'd2, 3'b100, 5'd1, 7'b011_1011}; #1; // DIVW
    check_field("DIVW.muldiv_op", dec.muldiv_op,  MULDIV_DIV);

    // ── LUI / AUIPC / JAL / JALR ─────────────────────────────────────────
    instr = {20'hDEAD, 5'd1, 7'b011_0111}; #1; // LUI
    check_field("LUI.alu_op",     dec.alu_op,     ALU_PASSB);
    check_field("LUI.rd_wen",     dec.rd_wen,     1);
    check_field("LUI.imm",        dec.imm,        64'h00000000_0DEAD000);
    check_field("LUI.illegal",    dec.illegal,    0);

    instr = {20'h1,   5'd1, 7'b001_0111}; #1; // AUIPC
    check_field("AUIPC.use_pc",   dec.use_pc,     1);
    check_field("AUIPC.alu_op",   dec.alu_op,     ALU_ADD);
    check_field("AUIPC.illegal",  dec.illegal,    0);

    // JAL x1, +8 (imm = 8)
    instr = {1'b0, 10'd4, 1'b0, 8'h0, 5'd1, 7'b110_1111}; #1;
    check_field("JAL.is_jal",     dec.is_jal,     1);
    check_field("JAL.rd_wen",     dec.rd_wen,     1);
    check_field("JAL.illegal",    dec.illegal,    0);

    // JALR x1, x2, 4
    instr = {12'd4, 5'd2, 3'b000, 5'd1, 7'b110_0111}; #1;
    check_field("JALR.is_jalr",   dec.is_jalr,    1);
    check_field("JALR.rs1_used",  dec.rs1_used,   1);
    check_field("JALR.illegal",   dec.illegal,    0);

    // ── BRANCH ────────────────────────────────────────────────────────────
    // BEQ x1, x2, +4
    instr = {7'b000_0000, 5'd2, 5'd1, 3'b000, 5'b00010, 7'b110_0011}; #1;
    check_field("BEQ.is_branch",  dec.is_branch,  1);
    check_field("BEQ.rs1_used",   dec.rs1_used,   1);
    check_field("BEQ.rs2_used",   dec.rs2_used,   1);
    check_field("BEQ.illegal",    dec.illegal,    0);

    instr = {7'b000_0000, 5'd2, 5'd1, 3'b001, 5'b00010, 7'b110_0011}; #1; // BNE
    check_field("BNE.is_branch",  dec.is_branch,  1);

    instr = {7'b000_0000, 5'd2, 5'd1, 3'b100, 5'b00010, 7'b110_0011}; #1; // BLT
    check_field("BLT.is_branch",  dec.is_branch,  1);

    instr = {7'b000_0000, 5'd2, 5'd1, 3'b101, 5'b00010, 7'b110_0011}; #1; // BGE
    check_field("BGE.is_branch",  dec.is_branch,  1);

    instr = {7'b000_0000, 5'd2, 5'd1, 3'b110, 5'b00010, 7'b110_0011}; #1; // BLTU
    check_field("BLTU.is_branch", dec.is_branch,  1);

    instr = {7'b000_0000, 5'd2, 5'd1, 3'b111, 5'b00010, 7'b110_0011}; #1; // BGEU
    check_field("BGEU.is_branch", dec.is_branch,  1);

    // ── LOAD ─────────────────────────────────────────────────────────────
    instr = {12'd4, 5'd2, 3'b000, 5'd1, 7'b000_0011}; #1; // LB
    check_field("LB.is_load",     dec.is_load,    1);
    check_field("LB.mem_funct3",  dec.mem_funct3, 3'b000);
    check_field("LB.illegal",     dec.illegal,    0);

    instr = {12'd4, 5'd2, 3'b001, 5'd1, 7'b000_0011}; #1; // LH
    check_field("LH.mem_funct3",  dec.mem_funct3, 3'b001);

    instr = {12'd4, 5'd2, 3'b010, 5'd1, 7'b000_0011}; #1; // LW
    check_field("LW.is_load",     dec.is_load,    1);

    instr = {12'd8, 5'd2, 3'b011, 5'd1, 7'b000_0011}; #1; // LD
    check_field("LD.is_load",     dec.is_load,    1);
    check_field("LD.mem_funct3",  dec.mem_funct3, 3'b011);
    check_field("LD.illegal",     dec.illegal,    0);

    instr = {12'd4, 5'd2, 3'b100, 5'd1, 7'b000_0011}; #1; // LBU
    check_field("LBU.mem_funct3", dec.mem_funct3, 3'b100);

    instr = {12'd4, 5'd2, 3'b101, 5'd1, 7'b000_0011}; #1; // LHU
    check_field("LHU.mem_funct3", dec.mem_funct3, 3'b101);

    instr = {12'd4, 5'd2, 3'b110, 5'd1, 7'b000_0011}; #1; // LWU
    check_field("LWU.is_load",    dec.is_load,    1);
    check_field("LWU.mem_funct3", dec.mem_funct3, 3'b110);
    check_field("LWU.illegal",    dec.illegal,    0);

    // ── STORE ─────────────────────────────────────────────────────────────
    instr = {7'd0, 5'd3, 5'd4, 3'b000, 5'd0, 7'b010_0011}; #1; // SB
    check_field("SB.is_store",    dec.is_store,   1);
    check_field("SB.mem_funct3",  dec.mem_funct3, 3'b000);
    check_field("SB.illegal",     dec.illegal,    0);

    instr = {7'd0, 5'd3, 5'd4, 3'b001, 5'd0, 7'b010_0011}; #1; // SH
    check_field("SH.mem_funct3",  dec.mem_funct3, 3'b001);

    instr = {7'd0, 5'd3, 5'd4, 3'b010, 5'd0, 7'b010_0011}; #1; // SW
    check_field("SW.is_store",    dec.is_store,   1);

    instr = {7'd0, 5'd3, 5'd4, 3'b011, 5'd16, 7'b010_0011}; #1; // SD
    check_field("SD.is_store",    dec.is_store,   1);
    check_field("SD.mem_funct3",  dec.mem_funct3, 3'b011);

    // ── AMO ────────────────────────────────────────────────────────────
    // LR.W
    instr = {5'b00010, 2'b00, 5'd0, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("LR_W.is_lr",     dec.is_lr,      1);
    check_field("LR_W.is_load",   dec.is_load,    1);
    check_field("LR_W.illegal",   dec.illegal,    0);

    // SC.W
    instr = {5'b00011, 2'b00, 5'd3, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("SC_W.is_sc",     dec.is_sc,      1);
    check_field("SC_W.is_store",  dec.is_store,   1);

    // AMOADD.W
    instr = {5'b00000, 2'b00, 5'd3, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("AMOADD.is_amo",  dec.is_amo,     1);
    check_field("AMOADD.funct5",  dec.amo_funct5, 5'b00000);

    // LR.D
    instr = {5'b00010, 2'b00, 5'd0, 5'd2, 3'b011, 5'd1, 7'b010_1111}; #1;
    check_field("LR_D.is_lr",     dec.is_lr,      1);
    check_field("LR_D.mem_funct3",dec.mem_funct3, 3'b011);

    // ── FP loads/stores ───────────────────────────────────────────────────
    // FLW f1, 0(x2)
    instr = {12'h000, 5'd2, 3'b010, 5'd1, 7'b000_0111}; #1;
    check_field("FLW.is_fp",      dec.is_fp,      1);
    check_field("FLW.fp_load",    dec.fp_load,    1);
    check_field("FLW.rd_fp",      dec.rd_fp,      1);
    check_field("FLW.illegal",    dec.illegal,    0);

    // FLD f2, 0(x2)
    instr = {12'h000, 5'd2, 3'b011, 5'd2, 7'b000_0111}; #1;
    check_field("FLD.is_fp",      dec.is_fp,      1);
    check_field("FLD.fp_load",    dec.fp_load,    1);
    check_field("FLD.mem_funct3", dec.mem_funct3, 3'b011);
    check_field("FLD.illegal",    dec.illegal,    0);

    // FSW f3, 0(x2)
    instr = {7'b000_0000, 5'd3, 5'd2, 3'b010, 5'd0, 7'b010_0111}; #1;
    check_field("FSW.is_fp",      dec.is_fp,      1);
    check_field("FSW.is_store",   dec.is_store,   1);
    check_field("FSW.rs2_fp",     dec.rs2_fp,     1);
    check_field("FSW.illegal",    dec.illegal,    0);

    // FSD f4, 0(x2)
    instr = {7'b000_0000, 5'd4, 5'd2, 3'b011, 5'd0, 7'b010_0111}; #1;
    check_field("FSD.is_fp",      dec.is_fp,      1);
    check_field("FSD.is_store",   dec.is_store,   1);
    check_field("FSD.mem_funct3", dec.mem_funct3, 3'b011);

    // ── FP arithmetic ─────────────────────────────────────────────────────
    // FADD.S f5, f1, f2  funct7=0000000
    instr = {7'b000_0000, 5'd2, 5'd1, 3'b000, 5'd5, 7'b101_0011}; #1;
    check_field("FADD_S.is_fp",   dec.is_fp,      1);
    check_field("FADD_S.fp_op",   dec.fp_op,      FP_FADD);
    check_field("FADD_S.rd_fp",   dec.rd_fp,      1);
    check_field("FADD_S.rs1_fp",  dec.rs1_fp,     1);
    check_field("FADD_S.illegal", dec.illegal,    0);

    // FMUL.D f6, f1, f2  funct7=0001001
    instr = {7'b000_1001, 5'd2, 5'd1, 3'b000, 5'd6, 7'b101_0011}; #1;
    check_field("FMUL_D.is_fp",   dec.is_fp,      1);
    check_field("FMUL_D.fp_op",   dec.fp_op,      FP_FMUL);
    check_field("FMUL_D.illegal", dec.illegal,    0);

    // FMV.W.X f1, x1  funct7=1111000 funct3=000
    instr = {7'b111_1000, 5'd0, 5'd1, 3'b000, 5'd1, 7'b101_0011}; #1;
    check_field("FMV_W_X.is_fp",  dec.is_fp,      1);
    check_field("FMV_W_X.fp_op",  dec.fp_op,      FP_FMV_W_X);
    check_field("FMV_W_X.rd_fp",  dec.rd_fp,      1);
    check_field("FMV_W_X.rd_wen", dec.rd_wen,     0);
    check_field("FMV_W_X.illegal",dec.illegal,    0);

    // ── Illegal ───────────────────────────────────────────────────────────
    // OP with bad funct7/funct3
    instr = {7'b111_1111, 5'd0, 5'd0, 3'b000, 5'd0, 7'b101_0011}; #1;
    check_field("ILLEGAL_FP.illegal", {63'b0, illegal}, 64'h1);

    if (errors == 0) $display("tb_decode_s5: ALL PASSED");
    else $display("tb_decode_s5: %0d FAILED", errors);
    $finish;
  end
endmodule
