// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_alu.sv — unit test for kronos_alu
`timescale 1ns/1ps
module tb_alu;
  import kronos_pkg::*;

  logic [31:0] a, b, result;
  alu_op_e     op;

  kronos_alu u_alu (.a_i(a), .b_i(b), .op_i(op), .result_o(result));

  int errors = 0;

  task check(input [31:0] expected, input string name);
    #1;
    if (result !== expected) begin
      $display("FAIL %s: got %08h expected %08h", name, result, expected);
      errors++;
    end else
      $display("PASS %s", name);
  endtask

  initial begin
    // ADD
    a = 32'd10; b = 32'd20; op = ALU_ADD; check(32'd30,          "ADD");
    a = 32'hFFFFFFFF; b = 32'd1; op = ALU_ADD; check(32'd0,      "ADD wrap");
    // SUB
    a = 32'd30; b = 32'd10; op = ALU_SUB; check(32'd20,          "SUB");
    a = 32'd5;  b = 32'd10; op = ALU_SUB; check(32'hFFFFFFFB,    "SUB neg");
    // SLL
    a = 32'd1; b = 32'd4; op = ALU_SLL; check(32'd16,            "SLL");
    a = 32'd1; b = 32'd31; op = ALU_SLL; check(32'h80000000,     "SLL 31");
    // SLT (signed)
    a = 32'hFFFFFFFF; b = 32'd0; op = ALU_SLT; check(32'd1,      "SLT neg<0");
    a = 32'd1; b = 32'd0; op = ALU_SLT; check(32'd0,             "SLT pos>0");
    // SLTU (unsigned)
    a = 32'd0; b = 32'd1; op = ALU_SLTU; check(32'd1,            "SLTU 0<1");
    a = 32'hFFFFFFFF; b = 32'd0; op = ALU_SLTU; check(32'd0,     "SLTU big>0");
    // XOR
    a = 32'hF0F0F0F0; b = 32'h0F0F0F0F; op = ALU_XOR; check(32'hFFFFFFFF, "XOR");
    // SRL (logical right shift)
    a = 32'h80000000; b = 32'd1; op = ALU_SRL; check(32'h40000000, "SRL");
    // SRA (arithmetic right shift)
    a = 32'h80000000; b = 32'd1; op = ALU_SRA; check(32'hC0000000, "SRA");
    // OR
    a = 32'hF0F0F0F0; b = 32'h0F0F0F0F; op = ALU_OR; check(32'hFFFFFFFF, "OR");
    // AND
    a = 32'hFFFFFFFF; b = 32'h0F0F0F0F; op = ALU_AND; check(32'h0F0F0F0F, "AND");
    // PASSB (for LUI)
    a = 32'hDEADBEEF; b = 32'h12345000; op = ALU_PASSB; check(32'h12345000, "PASSB");

    if (errors == 0) $display("ALL ALU TESTS PASSED");
    else $display("%0d ALU TEST(S) FAILED", errors);
    $finish;
  end
endmodule
