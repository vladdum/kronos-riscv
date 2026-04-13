// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_lsu_s1;
  logic        clk, rst_n;
  logic        req, we;
  logic [31:0] addr, wdata;
  logic [2:0]  funct3;
  logic [31:0] rdata;
  logic        valid, mem_stall;
  logic        data_req, data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic        data_gnt, data_rvalid, data_err;

  initial clk = 0;
  always #5 clk = ~clk;

  kronos_lsu u_lsu (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .req_i         (req),
    .we_i          (we),
    .addr_i        (addr),
    .wdata_i       (wdata),
    .funct3_i      (funct3),
    .rdata_o       (rdata),
    .valid_o       (valid),
    .mem_stall_o   (mem_stall),
    .data_req_o    (data_req),
    .data_gnt_i    (data_gnt),
    .data_rvalid_i (data_rvalid),
    .data_we_o     (data_we),
    .data_be_o     (data_be),
    .data_addr_o   (data_addr),
    .data_wdata_o  (data_wdata),
    .data_rdata_i  (data_rdata),
    .data_err_i    (data_err)
  );

  int errors = 0;

  task check_outputs(input string name, input logic exp_valid, exp_stall);
    if (valid !== exp_valid || mem_stall !== exp_stall) begin
      $display("FAIL %s: valid=%0b(exp %0b) stall=%0b(exp %0b)",
               name, valid, exp_valid, mem_stall, exp_stall);
      errors++;
    end else $display("PASS %s", name);
  endtask

  initial begin
    rst_n = 0; req = 0; we = 0; addr = '0; wdata = '0;
    funct3 = 3'b010; data_gnt = 0; data_rvalid = 0; data_rdata = '0; data_err = 0;
    @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;

    // Test 1: no request — no stall, no valid
    req = 0; data_gnt = 0; data_rvalid = 0;
    #1; check_outputs("idle", 0, 0);

    // Test 2: single-cycle load (gnt + rvalid same cycle)
    @(posedge clk); #1;
    req = 1; we = 0; addr = 32'h100; funct3 = 3'b010;
    data_rdata = 32'hDEADBEEF; data_gnt = 1; data_rvalid = 1;
    #1; check_outputs("single-cycle: valid+no stall", 1, 0);
    @(posedge clk); #1;
    req = 0; data_gnt = 0; data_rvalid = 0;
    if (rdata !== 32'hDEADBEEF) begin
      $display("FAIL single-cycle rdata: got %0h", rdata); errors++;
    end else $display("PASS single-cycle rdata");

    // Test 3: stall while waiting for gnt (gnt not asserted)
    @(posedge clk); #1;
    req = 1; addr = 32'h200; data_gnt = 0; data_rvalid = 0;
    #1; check_outputs("wait-gnt: stall", 0, 1);
    // now grant arrives with rvalid same cycle
    data_gnt = 1; data_rvalid = 1; data_rdata = 32'hCAFEBABE;
    #1; check_outputs("gnt+rvalid: valid", 1, 0);
    @(posedge clk); #1;
    req = 0; data_gnt = 0; data_rvalid = 0;

    // Test 4: two-cycle load — gnt this cycle, rvalid next (WAIT_RVALID state)
    @(posedge clk); #1;
    req = 1; addr = 32'h300; data_gnt = 1; data_rvalid = 0;
    #1; check_outputs("gnt no rvalid: stall", 0, 1);
    @(posedge clk); #1;           // clock edge: FSM → WAIT_RVALID
    data_gnt = 0;
    #1; check_outputs("WAIT_RVALID: stalling", 0, 1);
    data_rvalid = 1; data_rdata = 32'h55AA55AA;
    #1; check_outputs("WAIT_RVALID: rvalid → valid", 1, 0);
    if (rdata !== 32'h55AA55AA) begin
      $display("FAIL WAIT_RVALID rdata: got %0h", rdata); errors++;
    end else $display("PASS WAIT_RVALID rdata");
    @(posedge clk); #1;
    req = 0; data_rvalid = 0;

    // Test 5: store, single-cycle (OBI still issues rvalid for write response)
    @(posedge clk); #1;
    req = 1; we = 1; addr = 32'h400; wdata = 32'hAABBCCDD; funct3 = 3'b010;
    data_gnt = 1; data_rvalid = 1;
    #1; check_outputs("store single-cycle: valid", 1, 0);
    @(posedge clk); #1;
    req = 0; we = 0; data_gnt = 0; data_rvalid = 0;

    if (errors == 0) $display("ALL LSU STAGE1 TESTS PASSED");
    else $display("%0d LSU STAGE1 TEST(S) FAILED", errors);
    $finish;
  end
endmodule
