// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_muldiv;
  import kronos_pkg::*;

  logic        clk, rst_n;
  logic        req;
  muldiv_op_e  op;
  logic [31:0] a, b;
  logic [31:0] result;
  logic        busy, valid, idle;

  initial clk = 0;
  always #5 clk = ~clk;

  kronos_muldiv u_muldiv (
    .clk_i    (clk),
    .rst_ni   (rst_n),
    .req_i    (req),
    .op_i     (op),
    .a_i      (a),
    .b_i      (b),
    .result_o (result),
    .busy_o   (busy),
    .valid_o  (valid),
    .idle_o   (idle)
  );

  int errors = 0;

  // Issue one operation and wait for valid_o. Returns the result.
  task automatic run_op(
    input muldiv_op_e  op_in,
    input logic [31:0] a_in, b_in,
    output logic [31:0] res_out
  );
    @(posedge clk); #1;
    op = op_in; a = a_in; b = b_in; req = 1;
    @(posedge clk); #1;
    req = 0;
    // Wait for valid
    while (!valid) begin
      @(posedge clk); #1;
    end
    res_out = result;
  endtask

  task automatic check(
    input string       name,
    input logic [31:0] got, expected
  );
    if (got !== expected) begin
      $display("FAIL %s: got 0x%08h, expected 0x%08h", name, got, expected);
      errors++;
    end else begin
      $display("PASS %s: 0x%08h", name, got);
    end
  endtask

  logic [31:0] res;

  initial begin
    rst_n = 0; req = 0; op = MULDIV_MUL; a = '0; b = '0;
    @(posedge clk); #1; rst_n = 1;

    // ------- MUL -------
    // 3 * 5 = 15
    run_op(MULDIV_MUL, 32'd3, 32'd5, res);
    check("MUL 3*5", res, 32'd15);

    // (-3) * 5 lower 32 bits = 32'hFFFF_FFF1
    run_op(MULDIV_MUL, 32'hFFFF_FFFD, 32'd5, res);
    check("MUL -3*5 lower", res, 32'hFFFF_FFF1);

    // 0x80000000 * 2 lower = 0x00000000 (overflow)
    run_op(MULDIV_MUL, 32'h8000_0000, 32'd2, res);
    check("MUL INT_MIN*2 lower", res, 32'h0000_0000);

    // ------- MULH -------
    // (-3) * (-5): upper = 0 (result fits in 32 bits, positive)
    run_op(MULDIV_MULH, 32'hFFFF_FFFD, 32'hFFFF_FFFB, res);
    check("MULH -3*-5 upper", res, 32'h0000_0000);

    // (-1) * (-1): product = 1, upper = 0
    run_op(MULDIV_MULH, 32'hFFFF_FFFF, 32'hFFFF_FFFF, res);
    check("MULH -1*-1 upper", res, 32'h0000_0000);

    // INT_MIN * INT_MIN upper = 0x40000000
    run_op(MULDIV_MULH, 32'h8000_0000, 32'h8000_0000, res);
    check("MULH INT_MIN*INT_MIN upper", res, 32'h4000_0000);

    // ------- MULHSU -------
    // -1 (signed) * 1 (unsigned) = 0xFFFFFFFF_FFFFFFFF, upper = 0xFFFFFFFF
    run_op(MULDIV_MULHSU, 32'hFFFF_FFFF, 32'h0000_0001, res);
    check("MULHSU -1*1 upper", res, 32'hFFFF_FFFF);

    // ------- MULHU -------
    // 0xFFFFFFFF * 0xFFFFFFFF upper = 0xFFFFFFFE
    run_op(MULDIV_MULHU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, res);
    check("MULHU max*max upper", res, 32'hFFFF_FFFE);

    // ------- DIV -------
    // 20 / 4 = 5
    run_op(MULDIV_DIV, 32'd20, 32'd4, res);
    check("DIV 20/4", res, 32'd5);

    // -20 / 4 = -5
    run_op(MULDIV_DIV, 32'hFFFF_FFEC, 32'd4, res);
    check("DIV -20/4", res, 32'hFFFF_FFFB);

    // 20 / -4 = -5
    run_op(MULDIV_DIV, 32'd20, 32'hFFFF_FFFC, res);
    check("DIV 20/-4", res, 32'hFFFF_FFFB);

    // -20 / -4 = 5
    run_op(MULDIV_DIV, 32'hFFFF_FFEC, 32'hFFFF_FFFC, res);
    check("DIV -20/-4", res, 32'd5);

    // Division by zero: result = -1 (0xFFFFFFFF)
    run_op(MULDIV_DIV, 32'd7, 32'd0, res);
    check("DIV by zero", res, 32'hFFFF_FFFF);

    // Signed overflow: INT_MIN / -1 = INT_MIN
    run_op(MULDIV_DIV, 32'h8000_0000, 32'hFFFF_FFFF, res);
    check("DIV INT_MIN/-1 overflow", res, 32'h8000_0000);

    // ------- DIVU -------
    // 20 / 4 = 5
    run_op(MULDIV_DIVU, 32'd20, 32'd4, res);
    check("DIVU 20/4", res, 32'd5);

    // 0xFFFFFFFF / 2 = 0x7FFFFFFF
    run_op(MULDIV_DIVU, 32'hFFFF_FFFF, 32'd2, res);
    check("DIVU 0xFFFFFFFF/2", res, 32'h7FFF_FFFF);

    // Division by zero: result = 0xFFFFFFFF
    run_op(MULDIV_DIVU, 32'd7, 32'd0, res);
    check("DIVU by zero", res, 32'hFFFF_FFFF);

    // ------- REM -------
    // 20 % 4 = 0
    run_op(MULDIV_REM, 32'd20, 32'd4, res);
    check("REM 20%4", res, 32'd0);

    // 21 % 4 = 1
    run_op(MULDIV_REM, 32'd21, 32'd4, res);
    check("REM 21%4", res, 32'd1);

    // -21 % 4 = -1 (sign of dividend)
    run_op(MULDIV_REM, 32'hFFFF_FFEB, 32'd4, res);
    check("REM -21%4", res, 32'hFFFF_FFFF);

    // Remainder by zero: result = dividend (21)
    run_op(MULDIV_REM, 32'd21, 32'd0, res);
    check("REM by zero", res, 32'd21);

    // Signed overflow: INT_MIN % -1 = 0
    run_op(MULDIV_REM, 32'h8000_0000, 32'hFFFF_FFFF, res);
    check("REM INT_MIN%-1 overflow", res, 32'h0000_0000);

    // ------- REMU -------
    // 21 % 4 = 1
    run_op(MULDIV_REMU, 32'd21, 32'd4, res);
    check("REMU 21%4", res, 32'd1);

    // Remainder by zero: result = dividend
    run_op(MULDIV_REMU, 32'd21, 32'd0, res);
    check("REMU by zero", res, 32'd21);

    if (errors == 0) $display("ALL MULDIV TESTS PASSED");
    else             $display("%0d MULDIV TEST(S) FAILED", errors);
    $finish;
  end
endmodule
