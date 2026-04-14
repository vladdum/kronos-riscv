// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_decode_s4;
  import kronos_pkg::*;

  logic [31:0]    instr;
  decoded_instr_t dec;
  int errors = 0;

  kronos_decode dut (.instr_i(instr), .dec_o(dec));

  task check_field(string name, logic [63:0] got, logic [63:0] expected);
    if (got !== expected) begin
      $display("FAIL %s: got %0h, expected %0h (instr=%08h)", name, got, expected, instr);
      errors++;
    end
  endtask

  initial begin
    // ADDIW x1, x2, 5
    instr = 32'h0051_009B; #1;
    check_field("ADDIW.alu_op",    dec.alu_op,    ALU_ADD);
    check_field("ADDIW.is_word",   dec.is_word_op, 1);
    check_field("ADDIW.rd_wen",    dec.rd_wen,    1);
    check_field("ADDIW.rs1_used",  dec.rs1_used,  1);
    check_field("ADDIW.use_imm",   dec.use_imm,   1);
    check_field("ADDIW.imm",       dec.imm,       32'd5);

    instr = {7'b000_0000, 5'd15, 5'd4, 3'b001, 5'd3, 7'b001_1011}; #1;
    check_field("SLLIW.alu_op",    dec.alu_op,    ALU_SLL);
    check_field("SLLIW.is_word",   dec.is_word_op, 1);
    check_field("SLLIW.imm",       dec.imm,       32'd15);

    instr = {7'b000_0000, 5'd3, 5'd6, 3'b101, 5'd5, 7'b001_1011}; #1;
    check_field("SRLIW.alu_op",    dec.alu_op,    ALU_SRL);
    check_field("SRLIW.is_word",   dec.is_word_op, 1);

    instr = {7'b010_0000, 5'd3, 5'd8, 3'b101, 5'd7, 7'b001_1011}; #1;
    check_field("SRAIW.alu_op",    dec.alu_op,    ALU_SRA);
    check_field("SRAIW.is_word",   dec.is_word_op, 1);

    // ADDW x1, x2, x3
    instr = {7'b000_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_1011}; #1;
    check_field("ADDW.alu_op",     dec.alu_op,    ALU_ADD);
    check_field("ADDW.is_word",    dec.is_word_op, 1);
    check_field("ADDW.rs1_used",   dec.rs1_used,  1);
    check_field("ADDW.rs2_used",   dec.rs2_used,  1);

    // SUBW x4, x5, x6
    instr = {7'b010_0000, 5'd6, 5'd5, 3'b000, 5'd4, 7'b011_1011}; #1;
    check_field("SUBW.alu_op",     dec.alu_op,    ALU_SUB);
    check_field("SUBW.is_word",    dec.is_word_op, 1);

    // MULW x1, x2, x3
    instr = {7'b000_0001, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_1011}; #1;
    check_field("MULW.is_muldiv",  dec.is_muldiv, 1);
    check_field("MULW.is_word",    dec.is_word_op, 1);
    check_field("MULW.muldiv_op",  dec.muldiv_op, MULDIV_MUL);

    // DIVW
    instr = {7'b000_0001, 5'd3, 5'd2, 3'b100, 5'd1, 7'b011_1011}; #1;
    check_field("DIVW.is_muldiv",  dec.is_muldiv, 1);
    check_field("DIVW.is_word",    dec.is_word_op, 1);
    check_field("DIVW.muldiv_op",  dec.muldiv_op, MULDIV_DIV);

    // SLLI x1, x2, 33 (RV64 6-bit shamt)
    instr = {6'b000_000, 1'b1, 5'd1, 5'd2, 3'b001, 5'd1, 7'b001_0011}; #1;
    check_field("SLLI64.alu_op",   dec.alu_op,    ALU_SLL);
    check_field("SLLI64.is_word",  dec.is_word_op, 0);
    check_field("SLLI64.imm",      dec.imm,       32'd33);

    // LD
    instr = {12'd8, 5'd2, 3'b011, 5'd1, 7'b000_0011}; #1;
    check_field("LD.is_load",      dec.is_load,   1);
    check_field("LD.illegal",      dec.illegal,   0);
    check_field("LD.mem_funct3",   dec.mem_funct3, 3'b011);

    // LWU
    instr = {12'd4, 5'd2, 3'b110, 5'd1, 7'b000_0011}; #1;
    check_field("LWU.is_load",     dec.is_load,   1);
    check_field("LWU.illegal",     dec.illegal,   0);
    check_field("LWU.mem_funct3",  dec.mem_funct3, 3'b110);

    // SD
    instr = {7'd0, 5'd3, 5'd4, 3'b011, 5'd16, 7'b010_0011}; #1;
    check_field("SD.is_store",     dec.is_store,  1);
    check_field("SD.illegal",      dec.illegal,   0);

    // LR.W
    instr = {5'b00010, 2'b00, 5'd0, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("LR_W.is_lr",      dec.is_lr,     1);
    check_field("LR_W.is_load",    dec.is_load,   1);
    check_field("LR_W.illegal",    dec.illegal,   0);

    // SC.W
    instr = {5'b00011, 2'b00, 5'd3, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("SC_W.is_sc",      dec.is_sc,     1);
    check_field("SC_W.is_store",   dec.is_store,  1);

    // AMOADD.W
    instr = {5'b00000, 2'b00, 5'd3, 5'd2, 3'b010, 5'd1, 7'b010_1111}; #1;
    check_field("AMOADD_W.is_amo", dec.is_amo,    1);
    check_field("AMOADD_W.funct5", dec.amo_funct5, 5'b00000);

    // LR.D
    instr = {5'b00010, 2'b00, 5'd0, 5'd2, 3'b011, 5'd1, 7'b010_1111}; #1;
    check_field("LR_D.is_lr",      dec.is_lr,     1);
    check_field("LR_D.mem_funct3", dec.mem_funct3, 3'b011);

    // ADD x1, x2, x3 (RV32 backward compat)
    instr = {7'b000_0000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b011_0011}; #1;
    check_field("ADD32.alu_op",    dec.alu_op,    ALU_ADD);
    check_field("ADD32.is_word",   dec.is_word_op, 0);

    if (errors == 0) $display("tb_decode_s4: ALL PASSED");
    else $display("tb_decode_s4: %0d FAILED", errors);
    $finish;
  end
endmodule
