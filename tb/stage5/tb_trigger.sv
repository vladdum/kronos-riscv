// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_trigger;
  import kronos_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        csr_req;
  logic [11:0] csr_addr;
  logic        csr_we;
  logic [63:0] csr_wdata;
  logic [63:0] csr_rdata;
  logic        csr_match;

  logic        ex_valid;
  logic [31:0] ex_pc;
  logic        ex_is_load;
  logic        ex_is_store;
  logic [63:0] ex_mem_addr;

  logic        hit;
  logic [31:0] hit_pc;

  kronos_trigger u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .csr_req_i     (csr_req),
    .csr_addr_i    (csr_addr),
    .csr_we_i      (csr_we),
    .csr_wdata_i   (csr_wdata),
    .csr_rdata_o   (csr_rdata),
    .csr_match_o   (csr_match),
    .ex_valid_i    (ex_valid),
    .ex_pc_i       (ex_pc),
    .ex_is_load_i  (ex_is_load),
    .ex_is_store_i (ex_is_store),
    .ex_mem_addr_i (ex_mem_addr),
    .hit_o         (hit),
    .hit_pc_o      (hit_pc)
  );

  // ----- Helpers -----
  task csr_write(input [11:0] addr, input [63:0] data);
    @(negedge clk);
    csr_req = 1; csr_we = 1; csr_addr = addr; csr_wdata = data;
    @(posedge clk); #1;
    csr_req = 0; csr_we = 0;
  endtask

  task csr_read(input [11:0] addr, output [63:0] data);
    @(negedge clk);
    csr_req = 1; csr_we = 0; csr_addr = addr;
    #1;  // combinational read available
    data = csr_rdata;
    @(posedge clk); #1;
    csr_req = 0;
  endtask

  task ex_probe(input logic v, input [31:0] pc,
                input logic ld, input logic st, input [63:0] addr);
    @(negedge clk);
    ex_valid    = v;
    ex_pc       = pc;
    ex_is_load  = ld;
    ex_is_store = st;
    ex_mem_addr = addr;
    #1;
  endtask

  initial begin
    csr_req = 0; csr_we = 0; csr_addr = 0; csr_wdata = 0;
    ex_valid = 0; ex_pc = 0; ex_is_load = 0; ex_is_store = 0; ex_mem_addr = 0;
    #12 rst_n = 1;
    repeat (3) @(posedge clk);

    // ---- Test 1: tinfo reports mcontrol6=6 (bit 6 set) ----
    begin
      logic [63:0] v;
      csr_read(12'h7A4, v);
      if (v !== 64'h0000_0000_0000_0040)
        $fatal(1, "tinfo: expected 0x40, got %h", v);
    end

    // ---- Test 2: tselect read/write (only low 2 bits) ----
    begin
      logic [63:0] v;
      csr_write(12'h7A0, 64'h3);
      csr_read(12'h7A0, v);
      if (v[1:0] !== 2'd3) $fatal(1, "tselect: got %h", v);
    end
    csr_write(12'h7A0, 64'h0);  // reset

    // ---- Test 3: PC trigger fires on equality ----
    csr_write(12'h7A2, 64'h0000_0000_0000_1000);  // tdata2 = PC
    // tdata1: m=1 (bit 6), execute=1 (bit 3)
    csr_write(12'h7A1, 64'h0000_0000_0000_0048);
    ex_probe(1, 32'h1000, 0, 0, 64'h0);
    if (!hit)         $fatal(1, "PC trigger: expected hit at PC=0x1000");
    if (hit_pc !== 32'h1000) $fatal(1, "PC trigger: hit_pc=%h", hit_pc);
    ex_probe(1, 32'h1004, 0, 0, 64'h0);
    if (hit) $fatal(1, "PC trigger: spurious hit at PC=0x1004");

    // hit-bit is sticky -> tdata1[10] should now be 1
    begin
      logic [63:0] v;
      csr_read(12'h7A1, v);
      if (!v[10]) $fatal(1, "PC trigger: hit bit not sticky");
      // RW1C -- write 1 to bit 10 to clear; preserve other bits
      csr_write(12'h7A1, v | 64'h400);
      csr_read(12'h7A1, v);
      if (v[10]) $fatal(1, "PC trigger: hit not cleared by RW1C");
    end

    // Disable trigger
    csr_write(12'h7A1, 64'h0);

    // ---- Test 4: Load-address trigger fires on load only ----
    csr_write(12'h7A2, 64'h0000_0000_0000_2000);
    // tdata1: m=1, load=1 (bit 1)
    csr_write(12'h7A1, 64'h0000_0000_0000_0042);
    ex_probe(1, 32'h0, 1, 0, 64'h2000);
    if (!hit) $fatal(1, "Load trigger: expected hit");
    ex_probe(1, 32'h0, 0, 1, 64'h2000);
    if (hit)  $fatal(1, "Load trigger: spurious hit on store");
    csr_write(12'h7A1, 64'h0);  // disable

    // ---- Test 5: Store-address trigger fires on store only ----
    csr_write(12'h7A2, 64'h0000_0000_0000_3000);
    // tdata1: m=1, store=1 (bit 2)
    csr_write(12'h7A1, 64'h0000_0000_0000_0044);
    ex_probe(1, 32'h0, 0, 1, 64'h3000);
    if (!hit) $fatal(1, "Store trigger: expected hit");
    ex_probe(1, 32'h0, 1, 0, 64'h3000);
    if (hit)  $fatal(1, "Store trigger: spurious hit on load");
    csr_write(12'h7A1, 64'h0);

    // ---- Test 6: Independent triggers via tselect ----
    // T0: PC=0x1000, T1: load@0x4000
    csr_write(12'h7A0, 64'h0);
    csr_write(12'h7A2, 64'h1000);
    csr_write(12'h7A1, 64'h0000_0000_0000_0048);
    csr_write(12'h7A0, 64'h1);
    csr_write(12'h7A2, 64'h4000);
    csr_write(12'h7A1, 64'h0000_0000_0000_0042);
    // Probe load @0x4000 -> T1 fires.
    ex_probe(1, 32'hbeef, 1, 0, 64'h4000);
    if (!hit) $fatal(1, "T1 load trigger: expected hit");
    // Probe PC@0x1000 with no load -> T0 fires.
    ex_probe(1, 32'h1000, 0, 0, 64'h0);
    if (!hit) $fatal(1, "T0 PC trigger: expected hit");

    $display("tb_trigger: PASS");
    $finish;
  end

endmodule
