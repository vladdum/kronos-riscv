// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Stage 6d unit testbench for kronos_ram (ASIC behavioural backend).
// FPGA backend (xpm_memory_sdpram) is verified by XPM library guarantees;
// this TB exercises the SV-side semantics consumed by the icache wrapper.

module tb_kronos_ram;

  localparam int unsigned DEPTH      = 16;
  localparam int unsigned WIDTH      = 32;
  localparam int unsigned BYTE_WIDTH = 8;
  localparam int unsigned NB         = WIDTH / BYTE_WIDTH;
  localparam int unsigned ADDR_W     = $clog2(DEPTH);

  logic                  clk = 1'b0;
  logic                  we;
  logic [ADDR_W-1:0]     waddr;
  logic [WIDTH-1:0]      wdata;
  logic [NB-1:0]         wmask;
  logic                  re;
  logic [ADDR_W-1:0]     raddr;
  logic [WIDTH-1:0]      rdata;

  always #5 clk = ~clk;

  kronos_ram #(
    .DEPTH      (DEPTH),
    .WIDTH      (WIDTH),
    .BYTE_WIDTH (BYTE_WIDTH)
  ) dut (
    .clk_i   (clk),
    .we_i    (we),
    .waddr_i (waddr),
    .wdata_i (wdata),
    .wmask_i (wmask),
    .re_i    (re),
    .raddr_i (raddr),
    .rdata_o (rdata)
  );

  int unsigned fail_count = 0;

  task automatic write_word(input logic [ADDR_W-1:0] a, input logic [WIDTH-1:0] d);
    @(negedge clk);
    we     = 1'b1;
    waddr  = a;
    wdata  = d;
    wmask  = '1;
    re     = 1'b0;
    @(posedge clk);
    @(negedge clk);
    we     = 1'b0;
  endtask

  task automatic read_word(input logic [ADDR_W-1:0] a, output logic [WIDTH-1:0] d);
    @(negedge clk);
    re     = 1'b1;
    raddr  = a;
    we     = 1'b0;
    @(posedge clk);
    @(negedge clk);
    d      = rdata;
    re     = 1'b0;
  endtask

  initial begin
    we    = 1'b0;
    re    = 1'b0;
    waddr = '0;
    raddr = '0;
    wdata = '0;
    wmask = '0;

    @(negedge clk);

    // Case 1: write-then-read every address
    for (int unsigned i = 0; i < DEPTH; i++) begin
      write_word(i[ADDR_W-1:0], 32'hCAFE_0000 | i);
    end
    for (int unsigned i = 0; i < DEPTH; i++) begin : check_case1
      logic [WIDTH-1:0] got;
      read_word(i[ADDR_W-1:0], got);
      if (got !== (32'hCAFE_0000 | i)) begin
        $display("FAIL case1: addr=%0d got=%h expected=%h", i, got, 32'hCAFE_0000 | i);
        fail_count++;
      end
    end

    // Case 2: byte-write strobes
    write_word(4'd0, 32'h0000_0000);
    @(negedge clk);
    we    = 1'b1;
    waddr = 4'd0;
    wdata = 32'hAABB_CCDD;
    wmask = 4'b0010;
    re    = 1'b0;
    @(posedge clk);
    @(negedge clk);
    we    = 1'b0;
    begin : check_case2
      logic [WIDTH-1:0] got;
      read_word(4'd0, got);
      if (got[15:8] !== 8'hCC) begin
        $display("FAIL case2: byte1 got=%h expected=CC", got[15:8]);
        fail_count++;
      end
      if (got[31:16] !== 16'h0000 || got[7:0] !== 8'h00) begin
        $display("FAIL case2: other bytes got=%h expected zero", got);
        fail_count++;
      end
    end

    // Case 3: read latency
    write_word(4'd5, 32'hDEAD_BEEF);
    @(negedge clk);
    re    = 1'b1;
    raddr = 4'd5;
    we    = 1'b0;
    @(posedge clk);
    #1;  // settle NBA from rdata_q <= mem[raddr_i] before sampling
    if (rdata !== 32'hDEAD_BEEF) begin
      $display("FAIL case3: latency too long, got=%h", rdata);
      fail_count++;
    end
    @(negedge clk);
    re    = 1'b0;

    // Case 4: concurrent W to A, R from B (A != B)
    write_word(4'd2, 32'h1111_1111);
    write_word(4'd3, 32'h2222_2222);
    @(negedge clk);
    we    = 1'b1;
    waddr = 4'd2;
    wdata = 32'hFFFF_FFFF;
    wmask = '1;
    re    = 1'b1;
    raddr = 4'd3;
    @(posedge clk);
    @(negedge clk);
    we    = 1'b0;
    re    = 1'b0;
    if (rdata !== 32'h2222_2222) begin
      $display("FAIL case4: concurrent W/R got=%h expected=22222222", rdata);
      fail_count++;
    end

    if (fail_count == 0) begin
      $display("tb_kronos_ram: PASS");
    end else begin
      $display("tb_kronos_ram: FAIL (%0d cases failed)", fail_count);
    end
    $finish;
  end

endmodule
