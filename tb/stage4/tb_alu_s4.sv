// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_alu_s4;
  import kronos_pkg::*;

  logic [63:0] a, b, result;
  alu_op_e     op;
  logic        word_op;

  kronos_alu dut (
    .op_i      (op),
    .a_i       (a),
    .b_i       (b),
    .word_op_i (word_op),
    .result_o  (result)
  );

  int errors = 0;

  task check(string name, logic [63:0] expected);
    if (result !== expected) begin
      $display("FAIL %s: got %016h, expected %016h", name, result, expected);
      errors++;
    end
  endtask

  initial begin
    // ---- 64-bit operations ----
    word_op = 0;

    op = ALU_ADD; a = 64'h00000001_00000001; b = 64'h00000000_FFFFFFFF; #1;
    check("ADD64", 64'h00000002_00000000);

    op = ALU_SUB; a = 64'h00000001_00000000; b = 64'h00000000_00000001; #1;
    check("SUB64", 64'h00000000_FFFFFFFF);

    op = ALU_SLL; a = 64'h00000000_00000001; b = 64'd32; #1;
    check("SLL64_32", 64'h00000001_00000000);

    op = ALU_SRL; a = 64'h80000000_00000000; b = 64'd32; #1;
    check("SRL64_32", 64'h00000000_80000000);

    op = ALU_SRA; a = 64'hF000000000000000; b = 64'd4; #1;
    check("SRA64", 64'hFF00000000000000);

    op = ALU_SLT; a = 64'hFFFFFFFF_FFFFFFFF; b = 64'h00000000_00000001; #1;
    check("SLT64_neg", 64'h1);

    op = ALU_SLTU; a = 64'hFFFFFFFF_FFFFFFFF; b = 64'h00000000_00000001; #1;
    check("SLTU64", 64'h0);

    op = ALU_XOR; a = 64'hAAAAAAAA_AAAAAAAA; b = 64'h55555555_55555555; #1;
    check("XOR64", 64'hFFFFFFFF_FFFFFFFF);

    op = ALU_OR; a = 64'hAAAAAAAA_00000000; b = 64'h00000000_55555555; #1;
    check("OR64", 64'hAAAAAAAA_55555555);

    op = ALU_AND; a = 64'hFFFFFFFF_00000000; b = 64'h0F0F0F0F_0F0F0F0F; #1;
    check("AND64", 64'h0F0F0F0F_00000000);

    op = ALU_PASSB; a = 64'hDEADBEEF; b = 64'hCAFEBABE_12345678; #1;
    check("PASSB64", 64'hCAFEBABE_12345678);

    // ---- W-suffix operations ----
    word_op = 1;

    op = ALU_ADD; a = 64'h00000000_7FFFFFFF; b = 64'h00000000_00000001; #1;
    check("ADDW_overflow", 64'hFFFFFFFF_80000000);

    op = ALU_SUB; a = 64'h0; b = 64'h1; #1;
    check("SUBW_neg", 64'hFFFFFFFF_FFFFFFFF);

    op = ALU_SLL; a = 64'h00000000_00000001; b = 64'd31; #1;
    check("SLLW_31", 64'hFFFFFFFF_80000000);

    op = ALU_SRL; a = 64'hFFFFFFFF_80000000; b = 64'd1; #1;
    check("SRLW", 64'h00000000_40000000);

    op = ALU_SRA; a = 64'hFFFFFFFF_80000000; b = 64'd1; #1;
    check("SRAW", 64'hFFFFFFFF_C0000000);

    op = ALU_SLL; a = 64'h00000000_00000001; b = 64'd32; #1;
    check("SLLW_wrap32", 64'h00000000_00000001);

    if (errors == 0) $display("tb_alu_s4: ALL PASSED");
    else $display("tb_alu_s4: %0d FAILED", errors);
    $finish;
  end
endmodule
