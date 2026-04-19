// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Testbench for kronos_lsu Stage 5 FP extensions.
// Tests FSW/FLW round-trip (NaN-boxing), FSD/FLD round-trip,
// and integer loads/stores unaffected by fp_dest_req_i=0.

module tb_lsu_fp;
  import kronos_pkg::*;

  logic             clk = 0, rst_n = 0;
  logic             req, we;
  logic [31:0]      addr;
  logic [63:0]      wdata;
  logic [2:0]       funct3;
  logic [63:0]      rdata;
  logic             valid_out, mem_stall;
  logic             is_lr, is_sc, is_amo;
  logic [4:0]       amo_funct5;
  logic [63:0]      amo_src;
  logic             sc_success;
  // FP extensions
  logic             fp_dest_req;
  logic [63:0]      fp_store_data;
  logic             fp_dest_rsp;
  logic [63:0]      fp_rdata;

  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  kronos_lsu u_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .req_i           (req),
    .we_i            (we),
    .addr_i          (addr),
    .wdata_i         (wdata),
    .funct3_i        (funct3),
    .rdata_o         (rdata),
    .valid_o         (valid_out),
    .mem_stall_o     (mem_stall),
    .is_lr_i         (is_lr),
    .is_sc_i         (is_sc),
    .is_amo_i        (is_amo),
    .amo_funct5_i    (amo_funct5),
    .amo_src_i       (amo_src),
    .sc_success_o    (sc_success),
    .fp_dest_req_i   (fp_dest_req),
    .fp_store_data_i (fp_store_data),
    .fp_dest_rsp_o   (fp_dest_rsp),
    .fp_rdata_o      (fp_rdata),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp)
  );

  always #5 clk = ~clk;

  // Simple AXI memory model (256 words × 32 bits = 1 KB).
  logic [31:0] mem [256];
  logic [31:0] ar_addr_q;
  logic        ar_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_rsp    <= '0;
      ar_pending <= 0;
    end else begin
      axi_rsp          <= '0;
      axi_rsp.ar_ready <= 1;
      axi_rsp.aw_ready <= 1;
      axi_rsp.w_ready  <= 1;

      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        ar_addr_q  <= axi_req.ar.addr;
        ar_pending <= 1;
      end

      if (ar_pending) begin
        axi_rsp.r_valid <= 1;
        axi_rsp.r.data  <= mem[ar_addr_q[9:2]];
        axi_rsp.r.last  <= 1;
        ar_pending      <= 0;
      end

      if (axi_req.aw_valid && axi_req.w_valid) begin
        for (int i = 0; i < 4; i++)
          if (axi_req.w.strb[i])
            mem[axi_req.aw.addr[9:2]][i*8 +: 8] <= axi_req.w.data[i*8 +: 8];
        axi_rsp.b_valid <= 1;
      end
    end
  end

  // Wait until valid_out pulses, then stabilise.  Add a cycle limit to
  // prevent infinite hangs if the RTL never completes.
  task automatic wait_valid;
    automatic int timeout = 0;
    while (!valid_out) begin
      @(posedge clk); #1;
      timeout++;
      if (timeout > 20) $fatal(1, "wait_valid: timed out waiting for valid_out");
    end
  endtask

  int errors = 0;

  initial begin
    is_lr = 0; is_sc = 0; is_amo = 0; amo_funct5 = 0; amo_src = 0;
    fp_dest_req = 0; fp_store_data = '0;
    req = 0; we = 0;
    for (int i = 0; i < 256; i++) mem[i] = 0;

    #12 rst_n = 1;
    @(posedge clk);

    // ------------------------------------------------------------------
    // 1. FSW: write 1.0f (0x3F800000) from FP register to addr 0x00
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 1; addr = 32'h0; wdata = '0;
    funct3 = 3'b010;                         // SW (word store)
    fp_dest_req   = 1;
    fp_store_data = {32'hFFFF_FFFF, 32'h3F80_0000};  // FP reg: NaN-boxed 1.0f
    @(posedge clk); #1; req = 0; fp_dest_req = 0; fp_store_data = '0;
    wait_valid;
    // fp_dest_rsp should be 0 for stores (stores don't produce load data)
    if (fp_dest_rsp !== 1'b0) begin
      $error("[FSW] fp_dest_rsp unexpectedly set after store");
      errors++;
    end
    @(posedge clk); #1;  // STORE_DONE → IDLE

    // ------------------------------------------------------------------
    // 2. FLW: load word from addr 0x00 → should NaN-box to 0xFFFFFFFF_3F800000
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b010;  // LW (word load)
    fp_dest_req = 1;
    @(posedge clk); #1; req = 0; fp_dest_req = 0;
    wait_valid;
    if (!fp_dest_rsp) begin
      $error("[FLW] fp_dest_rsp not set"); errors++;
    end else if (fp_rdata !== 64'hFFFF_FFFF_3F80_0000) begin
      $error("[FLW] fp_rdata %h != expected FFFF_FFFF_3F80_0000", fp_rdata); errors++;
    end else
      $display("[FLW] OK: fp_rdata=%h", fp_rdata);
    @(posedge clk); #1;  // LOAD_DONE → IDLE

    // ------------------------------------------------------------------
    // 3. FSD: write -2.5 (0xC004000000000000) from FP register to addr 0x10
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 1; addr = 32'h10; wdata = '0; funct3 = 3'b011;  // SD
    fp_dest_req   = 1;
    fp_store_data = 64'hC004_0000_0000_0000;
    @(posedge clk); #1; req = 0; fp_dest_req = 0; fp_store_data = '0;
    wait_valid;
    if (fp_dest_rsp !== 1'b0) begin
      $error("[FSD] fp_dest_rsp unexpectedly set after store"); errors++;
    end
    @(posedge clk); #1;  // STORE_DONE → IDLE

    // ------------------------------------------------------------------
    // 4. FLD: load dword from addr 0x10 → should return 64'hC004000000000000
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 0; addr = 32'h10; funct3 = 3'b011;  // LD
    fp_dest_req = 1;
    @(posedge clk); #1; req = 0; fp_dest_req = 0;
    wait_valid;
    if (!fp_dest_rsp) begin
      $error("[FLD] fp_dest_rsp not set"); errors++;
    end else if (fp_rdata !== 64'hC004_0000_0000_0000) begin
      $error("[FLD] fp_rdata %h != expected C004_0000_0000_0000", fp_rdata); errors++;
    end else
      $display("[FLD] OK: fp_rdata=%h", fp_rdata);
    @(posedge clk); #1;  // LOAD_DONE → IDLE

    // ------------------------------------------------------------------
    // 5. Integer SW (fp_dest_req=0): fp_dest_rsp must NOT be set on completion
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 1; addr = 32'h20; wdata = 64'hDEAD_BEEF_0000_0001; funct3 = 3'b010;
    fp_dest_req = 0;
    @(posedge clk); #1; req = 0;
    wait_valid;
    if (fp_dest_rsp !== 1'b0) begin
      $error("[INT_SW] fp_dest_rsp set for integer store (should be 0)"); errors++;
    end else
      $display("[INT_SW] OK: fp_dest_rsp=0");
    @(posedge clk); #1;  // STORE_DONE → IDLE

    // ------------------------------------------------------------------
    // 6. Integer LW (fp_dest_req=0): fp_dest_rsp must NOT be set on load
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b010;
    fp_dest_req = 0;
    @(posedge clk); #1; req = 0;
    wait_valid;
    if (fp_dest_rsp !== 1'b0) begin
      $error("[INT_LW] fp_dest_rsp set for integer load (should be 0)"); errors++;
    end else
      $display("[INT_LW] OK: fp_dest_rsp=0, rdata=%h", rdata);
    @(posedge clk); #1;  // LOAD_DONE → IDLE

    // ------------------------------------------------------------------
    // 7. FSW high bit NaN-box check: only low 32 bits of fp_store_data stored
    //    Store 64'hFFFF_FFFF_4000_0000 (NaN-boxed 2.0f), load as FLW
    // ------------------------------------------------------------------
    @(negedge clk);
    req = 1; we = 1; addr = 32'h30; wdata = '0; funct3 = 3'b010;
    fp_dest_req   = 1;
    fp_store_data = 64'hFFFF_FFFF_4000_0000;
    @(posedge clk); #1; req = 0; fp_dest_req = 0; fp_store_data = '0;
    wait_valid;
    @(posedge clk); #1;  // STORE_DONE → IDLE

    @(negedge clk);
    req = 1; we = 0; addr = 32'h30; funct3 = 3'b010;
    fp_dest_req = 1;
    @(posedge clk); #1; req = 0; fp_dest_req = 0;
    wait_valid;
    if (!fp_dest_rsp || fp_rdata !== 64'hFFFF_FFFF_4000_0000) begin
      $error("[FSW/FLW nanbox] fp_rdata %h != FFFF_FFFF_4000_0000", fp_rdata); errors++;
    end else
      $display("[FSW/FLW nanbox] OK: fp_rdata=%h", fp_rdata);

    if (errors != 0) $fatal(1, "tb_lsu_fp: %0d error(s)", errors);
    $display("tb_lsu_fp PASS");
    $finish;
  end
endmodule
