// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_muldiv_s4;
  import kronos_pkg::*;

  logic        clk, rst_n;
  logic        req;
  muldiv_op_e  op;
  logic [63:0] a, b;
  logic        word_op;
  logic [63:0] result;
  logic        busy, valid, idle;

  kronos_muldiv dut (
    .clk_i    (clk),
    .rst_ni   (rst_n),
    .req_i    (req),
    .op_i     (op),
    .a_i      (a),
    .b_i      (b),
    .word_op_i(word_op),
    .result_o (result),
    .busy_o   (busy),
    .valid_o  (valid),
    .idle_o   (idle)
  );

  initial begin clk = 0; forever #5 clk = ~clk; end

  int errors = 0;

  task do_op(muldiv_op_e o, logic [63:0] va, logic [63:0] vb, logic w,
             logic [63:0] expected, string name);
    @(posedge clk);
    op = o; a = va; b = vb; word_op = w; req = 1;
    @(posedge clk);
    req = 0;
    while (!valid) @(posedge clk);
    if (result !== expected) begin
      $display("FAIL %s: got %016h, expected %016h", name, result, expected);
      errors++;
    end
  endtask

  initial begin
    rst_n = 0; req = 0; word_op = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    do_op(MULDIV_MUL,  64'h1_0000_0000,          64'h3,           0, 64'h3_0000_0000,         "MUL64");
    do_op(MULDIV_MUL,  64'hFFFFFFFF_FFFFFFFF,    64'h2,           0, 64'hFFFFFFFF_FFFFFFFE,   "MUL64_neg");
    do_op(MULDIV_MULH, 64'h8000_0000_0000_0000,  64'h2,           0, 64'hFFFF_FFFF_FFFF_FFFF, "MULH64");
    do_op(MULDIV_MUL,  64'd100000,               64'd100000,      1, 64'h00000000_540BE400,   "MULW");
    do_op(MULDIV_MUL,  64'h7FFF_FFFF,            64'h2,           1, 64'hFFFF_FFFF_FFFF_FFFE, "MULW_ovf");
    do_op(MULDIV_DIV,  64'd100,                  64'd7,           0, 64'd14,                  "DIV64");
    do_op(MULDIV_DIV,  -64'sd100,                64'd7,           0, -64'sd14,                "DIV64_neg");
    do_op(MULDIV_DIV,  64'd42,                   64'd0,           0, 64'hFFFF_FFFF_FFFF_FFFF, "DIV64_zero");
    do_op(MULDIV_REM,  64'd100,                  64'd7,           0, 64'd2,                   "REM64");
    do_op(MULDIV_DIV,  64'd100,                  64'd7,           1, 64'd14,                  "DIVW");
    do_op(MULDIV_REM,  64'd100,                  64'd7,           1, 64'd2,                   "REMW");
    do_op(MULDIV_DIV,  64'd42,                   64'd0,           1, 64'hFFFF_FFFF_FFFF_FFFF, "DIVW_zero");

    if (errors == 0) $display("tb_muldiv_s4: ALL PASSED");
    else $display("tb_muldiv_s4: %0d FAILED", errors);
    $finish;
  end
endmodule
