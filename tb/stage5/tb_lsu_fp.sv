// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Testbench for kronos_lsu Stage 5 FP extensions.
// Tests FSW/FLW round-trip (NaN-boxing), FSD/FLD round-trip,
// and integer loads/stores unaffected by fp_dest_req_i=0.
//
// Instantiates kronos_lsu + kronos_dcache together and provides an
// AXI4 slave memory model (256 words × 32 bits = 1 KB).

module tb_lsu_fp;
  import kronos_pkg::*;

  logic             clk, rst_n;
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

  // dcache ↔ LSU wires
  logic             dcache_req;
  logic [63:0]      dcache_addr;
  logic [2:0]       dcache_size;
  logic             dcache_we;
  logic [63:0]      dcache_wdata;
  logic             dcache_amo_req;
  logic [4:0]       dcache_amo_op;
  logic             dcache_data_valid;
  logic [63:0]      dcache_rdata;
  logic             dcache_sc_success;
  logic             dcache_stall;

  // AXI between dcache and AXI slave
  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  // -------------------------------------------------------------------------
  // DUT — LSU
  // -------------------------------------------------------------------------
  kronos_lsu u_lsu (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .req_i              (req),
    .we_i               (we),
    .addr_i             (addr),
    .wdata_i            (wdata),
    .funct3_i           (funct3),
    .rdata_o            (rdata),
    .valid_o            (valid_out),
    .mem_stall_o        (mem_stall),
    .fp_dest_req_i      (fp_dest_req),
    .fp_store_data_i    (fp_store_data),
    .fp_dest_rsp_o      (fp_dest_rsp),
    .fp_rdata_o         (fp_rdata),
    .is_lr_i            (is_lr),
    .is_sc_i            (is_sc),
    .is_amo_i           (is_amo),
    .amo_funct5_i       (amo_funct5),
    .amo_src_i          (amo_src),
    .sc_success_o       (sc_success),
    .dcache_req_o       (dcache_req),
    .dcache_addr_o      (dcache_addr),
    .dcache_size_o      (dcache_size),
    .dcache_we_o        (dcache_we),
    .dcache_wdata_o     (dcache_wdata),
    .dcache_amo_req_o   (dcache_amo_req),
    .dcache_amo_op_o    (dcache_amo_op),
    .dcache_data_valid_i(dcache_data_valid),
    .dcache_rdata_i     (dcache_rdata),
    .dcache_sc_success_i(dcache_sc_success),
    .dcache_stall_i     (dcache_stall)
  );

  // -------------------------------------------------------------------------
  // DUT — dcache
  // -------------------------------------------------------------------------
  kronos_dcache u_dcache (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .req_i          (dcache_req),
    .addr_i         (dcache_addr),
    .size_i         (dcache_size),
    .we_i           (dcache_we),
    .wdata_i        (dcache_wdata),
    .amo_req_i      (dcache_amo_req),
    .amo_op_i       (dcache_amo_op),
    .rsrv_clear_i   ('0),
    .data_valid_o   (dcache_data_valid),
    .rdata_o        (dcache_rdata),
    .sc_success_o   (dcache_sc_success),
    .stall_o        (dcache_stall),
    .axi_req_o      (axi_req),
    .axi_rsp_i      (axi_rsp),
    .miss_pulse_o   ()
  );

  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // AXI slave memory model (256 words × 32 bits = 1 KB).
  // Serves multi-beat WRAP/INCR bursts for dcache refills and writebacks.
  // -------------------------------------------------------------------------
  logic [31:0] mem [256];

  logic        ar_pending;
  logic [63:0] ar_addr_q;
  logic [7:0]  ar_len_q;
  logic [7:0]  ar_beat_cnt;

  logic        aw_pending;
  logic [63:0] aw_addr_q;
  logic [7:0]  aw_len_q;
  logic [7:0]  aw_beat_cnt;
  logic        b_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_rsp     <= '0;
      ar_pending  <= 0;
      ar_beat_cnt <= 0;
      aw_pending  <= 0;
      aw_beat_cnt <= 0;
      b_pending   <= 0;
    end else begin
      axi_rsp.r_valid  <= 0;
      axi_rsp.r.last   <= 0;
      axi_rsp.b_valid  <= 0;

      axi_rsp.ar_ready <= 1;
      axi_rsp.aw_ready <= 1;
      axi_rsp.w_ready  <= 1;

      // B response
      if (b_pending) begin
        axi_rsp.b_valid <= 1;
        axi_rsp.b.resp  <= 2'b00;
        b_pending       <= 0;
      end

      // AW handshake
      if (axi_req.aw_valid && axi_rsp.aw_ready && !aw_pending) begin
        aw_addr_q   <= axi_req.aw.addr;
        aw_len_q    <= axi_req.aw.len;
        aw_beat_cnt <= 0;
        aw_pending  <= 1;
      end

      // W channel write beats
      if (aw_pending && axi_req.w_valid && axi_rsp.w_ready) begin
        automatic logic [63:0] beat_addr;
        automatic int unsigned wi_lo;
        beat_addr = aw_addr_q + {56'b0, aw_beat_cnt} * 8;
        wi_lo = int'(beat_addr[9:3]) * 2;
        for (int i = 0; i < 4; i++)
          if (axi_req.w.strb[i])
            mem[wi_lo][i*8 +: 8] <= axi_req.w.data[i*8 +: 8];
        for (int i = 0; i < 4; i++)
          if (axi_req.w.strb[4+i])
            mem[wi_lo+1][i*8 +: 8] <= axi_req.w.data[(4+i)*8 +: 8];
        aw_beat_cnt <= aw_beat_cnt + 8'd1;
        if (axi_req.w.last) begin
          aw_pending <= 0;
          b_pending  <= 1;
        end
      end

      // AR handshake
      if (axi_req.ar_valid && axi_rsp.ar_ready && !ar_pending) begin
        ar_addr_q   <= axi_req.ar.addr;
        ar_len_q    <= axi_req.ar.len;
        ar_beat_cnt <= 0;
        ar_pending  <= 1;
      end

      // R channel read beats
      if (ar_pending && !axi_rsp.r_valid) begin
        automatic logic [63:0] beat_addr;
        automatic int unsigned wi_lo;
        beat_addr = ar_addr_q + {56'b0, ar_beat_cnt} * 8;
        wi_lo = int'(beat_addr[9:3]) * 2;
        axi_rsp.r_valid <= 1;
        axi_rsp.r.data  <= {mem[wi_lo+1], mem[wi_lo]};
        axi_rsp.r.last  <= (ar_beat_cnt == ar_len_q);
        ar_beat_cnt     <= ar_beat_cnt + 8'd1;
        if (ar_beat_cnt == ar_len_q)
          ar_pending <= 0;
      end
    end
  end

  // Wait until valid_out pulses.  Cycle limit prevents infinite hangs.
  task automatic wait_valid;
    automatic int timeout = 0;
    while (!valid_out) begin
      @(posedge clk); #1;
      timeout++;
      if (timeout > 200) $fatal(1, "wait_valid: timed out waiting for valid_out");
    end
  endtask

  int errors = 0;

  initial begin
    clk = 0; rst_n = 0;
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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
    @(posedge clk); #1;

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
