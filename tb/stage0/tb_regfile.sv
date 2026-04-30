// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
module tb_regfile;
  logic        clk;
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        rd_wen;
  logic [63:0] rd_wdata;
  logic [63:0] rs1_rdata, rs2_rdata;
  int errors = 0;

  always #5 clk = ~clk;

  kronos_regfile u_rf (
    .clk_i      (clk),
    .rs1_addr_i (rs1_addr),
    .rs2_addr_i (rs2_addr),
    .rs1_rdata_o(rs1_rdata),
    .rs2_rdata_o(rs2_rdata),
    .rd_addr_i  (rd_addr),
    .rd_wen_i   (rd_wen),
    .rd_wdata_i (rd_wdata)
  );

  task write_reg(input [4:0] addr, input [63:0] data);
    rd_addr = addr; rd_wdata = data; rd_wen = 1;
    @(posedge clk); #1; rd_wen = 0;
  endtask

  task check_rs1(input [4:0] addr, input [63:0] expected, input string name);
    rs1_addr = addr; #1;
    if (rs1_rdata !== expected) begin
      $display("FAIL %s: got %0h expected %0h", name, rs1_rdata, expected);
      errors++;
    end else $display("PASS %s", name);
  endtask

  initial clk = 0;

  initial begin
    rs2_addr = 5'd0;
    rd_wen   = 0;
    @(posedge clk); #1;

    // x0 is always 0
    write_reg(0, 64'hDEADBEEF);
    check_rs1(0, 64'd0, "x0 always zero");

    // Write and read back x1
    write_reg(1, 64'hCAFEBABE);
    check_rs1(1, 64'hCAFEBABE, "x1 write/read");

    // Write x31
    write_reg(31, 64'h0123456789ABCDEF);
    check_rs1(31, 64'h0123456789ABCDEF, "x31 write/read");

    if (errors == 0) $display("ALL REGFILE TESTS PASSED");
    else $display("%0d REGFILE TEST(S) FAILED", errors);
    $finish;
  end
endmodule
