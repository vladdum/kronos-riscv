// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
module tb_decode;
  import kronos_pkg::*;

  logic [31:0]    instr;
  decoded_instr_t dec;
  int errors = 0;

  kronos_decode u_dec (.instr_i(instr), .dec_o(dec));

  task check_rtype(
    input [31:0]  instr_in,
    input [4:0]   exp_rs1, exp_rs2, exp_rd,
    input alu_op_e exp_op,
    input string  name
  );
    instr = instr_in; #1;
    if (dec.rs1 !== exp_rs1 || dec.rs2 !== exp_rs2 || dec.rd !== exp_rd ||
        dec.alu_op !== exp_op || dec.rd_wen !== 1'b1 || dec.illegal !== 1'b0) begin
      $display("FAIL %s: rs1=%0d rs2=%0d rd=%0d op=%0d illegal=%0b",
               name, dec.rs1, dec.rs2, dec.rd, dec.alu_op, dec.illegal);
      errors++;
    end else $display("PASS %s", name);
  endtask

  initial begin
    // ADD x3, x1, x2  → 0000000 00010 00001 000 00011 0110011
    check_rtype(32'h002081B3, 1, 2, 3, ALU_ADD,  "ADD x3,x1,x2");
    // SUB x3, x1, x2  → 0100000 00010 00001 000 00011 0110011
    check_rtype(32'h402081B3, 1, 2, 3, ALU_SUB,  "SUB x3,x1,x2");
    // SLL x4, x1, x2  → 0000000 00010 00001 001 00100 0110011
    check_rtype(32'h00209233, 1, 2, 4, ALU_SLL,  "SLL x4,x1,x2");
    // SLT x4, x1, x2  → 0000000 00010 00001 010 00100 0110011
    check_rtype(32'h0020A233, 1, 2, 4, ALU_SLT,  "SLT x4,x1,x2");
    // XOR x4, x1, x2  → 0000000 00010 00001 100 00100 0110011
    check_rtype(32'h0020C233, 1, 2, 4, ALU_XOR,  "XOR x4,x1,x2");
    // OR  x4, x1, x2  → 0000000 00010 00001 110 00100 0110011
    check_rtype(32'h0020E233, 1, 2, 4, ALU_OR,   "OR x4,x1,x2");
    // AND x4, x1, x2  → 0000000 00010 00001 111 00100 0110011
    check_rtype(32'h0020F233, 1, 2, 4, ALU_AND,  "AND x4,x1,x2");

    // ---- I-type ALU -------------------------------------------------------
    // ADDI x3, x1, 42  → imm=42, rs1=1, rd=3, funct3=000, opcode=OP_IMM
    // encoding: 000000101010 00001 000 00011 0010011 = 0x02A08193
    instr = 32'h02A08193; #1;
    if (dec.alu_op !== ALU_ADD || dec.use_imm !== 1'b1 || dec.imm !== 32'd42 ||
        dec.rs1 !== 5'd1 || dec.rd !== 5'd3 || dec.illegal !== 1'b0) begin
      $display("FAIL ADDI: op=%0d use_imm=%0b imm=%0d illegal=%0b",
               dec.alu_op, dec.use_imm, dec.imm, dec.illegal);
      errors++;
    end else $display("PASS ADDI x3,x1,42");

    // XORI x5, x2, -1  → imm=0xFFF (sign-extend → -1), funct3=100
    // encoding: 111111111111 00010 100 00101 0010011 = 0xFFF14293
    instr = 32'hFFF14293; #1;
    if (dec.alu_op !== ALU_XOR || dec.imm !== 32'hFFFFFFFF || dec.illegal !== 1'b0) begin
      $display("FAIL XORI: op=%0d imm=%08h", dec.alu_op, dec.imm);
      errors++;
    end else $display("PASS XORI x5,x2,-1");

    // SLLI x6, x1, 3  → shamt=3, funct7=0000000, funct3=001
    // encoding: 0000000 00011 00001 001 00110 0010011 = 0x00309313
    instr = 32'h00309313; #1;
    if (dec.alu_op !== ALU_SLL || dec.imm !== 32'd3 || dec.illegal !== 1'b0) begin
      $display("FAIL SLLI: op=%0d imm=%0d", dec.alu_op, dec.imm);
      errors++;
    end else $display("PASS SLLI x6,x1,3");

    if (errors == 0) $display("ALL DECODE TESTS PASSED");
    else $display("%0d DECODE TEST(S) FAILED", errors);
    $finish;
  end
endmodule
