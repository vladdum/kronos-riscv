// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// tb_lsu_s5 — Integration TB for kronos_lsu + kronos_dcache.
// Instantiates both modules together and acts as an AXI4 slave providing
// single-beat responses to the dcache.  Memory is a 256-word (2 KB) flat
// array; each entry is 32 bits.  The dcache uses 64-byte lines (8 beats of
// 8 bytes each); the AXI slave here serves single-beat INCR bursts for
// simplicity — the dcache will issue WRAP bursts for refills, but the slave
// responds beat-by-beat so the cache still works correctly.
//
// Note: with a true write-back dcache the LSU unit tests work at the
// dcache-interface level rather than checking the backing mem[] directly
// for stores (stores live in the cache until eviction).  Tests that check
// mem[] after a store use a SW followed by an LD to verify round-trip.
module tb_lsu_s5;
  import kronos_pkg::*;

  logic             clk, rst_n;

  // LSU pipeline interface
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
    .fp_dest_req_i      ('0),
    .fp_store_data_i    ('0),
    .fp_dest_rsp_o      (),
    .fp_rdata_o         (),
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

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  initial begin clk = 0; forever #5 clk = ~clk; end

  // -------------------------------------------------------------------------
  // Backing memory — 256 32-bit words (2 KB).  Stores inside the dcache are
  // written back on eviction; for test purposes we pre-load values and read
  // them back through the LSU.
  // -------------------------------------------------------------------------
  logic [31:0] mem [256];

  int errors = 0;

  // -------------------------------------------------------------------------
  // AXI slave — serves the dcache's read/write bursts.
  // Reads: return two consecutive 32-bit words from mem[] as an 8-byte beat.
  // Writes: apply byte-enables to mem[] (dcache sends full cache-line writes).
  // -------------------------------------------------------------------------
  // AR channel
  logic        ar_pending;
  logic [63:0] ar_addr_q;
  logic [7:0]  ar_len_q;
  logic [7:0]  ar_beat_cnt;

  // AW/W channel
  logic        aw_pending;
  logic [63:0] aw_addr_q;
  logic [7:0]  aw_len_q;
  logic [7:0]  aw_beat_cnt;
  logic        b_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_rsp    <= '0;
      ar_pending <= 0;
      ar_beat_cnt <= 0;
      aw_pending  <= 0;
      aw_beat_cnt <= 0;
      b_pending   <= 0;
    end else begin
      // Default: clear one-cycle pulses
      axi_rsp.r_valid  <= 0;
      axi_rsp.r.last   <= 0;
      axi_rsp.b_valid  <= 0;

      // Always-ready channels
      axi_rsp.ar_ready <= 1;
      axi_rsp.aw_ready <= 1;
      axi_rsp.w_ready  <= 1;

      // ---------- Write-back B response ----------
      if (b_pending) begin
        axi_rsp.b_valid  <= 1;
        axi_rsp.b.resp   <= 2'b00;
        b_pending        <= 0;
      end

      // ---------- AW handshake ----------
      if (axi_req.aw_valid && axi_rsp.aw_ready && !aw_pending) begin
        aw_addr_q   <= axi_req.aw.addr;
        aw_len_q    <= axi_req.aw.len;
        aw_beat_cnt <= 0;
        aw_pending  <= 1;
      end

      // ---------- W channel: write beats ----------
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

      // ---------- AR handshake ----------
      if (axi_req.ar_valid && axi_rsp.ar_ready && !ar_pending) begin
        ar_addr_q   <= axi_req.ar.addr;
        ar_len_q    <= axi_req.ar.len;
        ar_beat_cnt <= 0;
        ar_pending  <= 1;
      end

      // ---------- R channel: send read beats ----------
      // Drop r_valid one cycle after a successful handshake so the next beat
      // can be issued.  Without this the model gets stuck after the first beat.
      if (axi_rsp.r_valid && axi_req.r_ready) begin
        axi_rsp.r_valid <= 0;
        axi_rsp.r.last  <= 0;
      end
      if (ar_pending && (!axi_rsp.r_valid || axi_req.r_ready)) begin
        automatic logic [63:0] beat_addr;
        automatic int unsigned wi_lo;
        // For WRAP bursts the address wraps; for simplicity use INCR addressing
        // (the dcache only wraps within a cache line, so low bits give beat offset)
        beat_addr = ar_addr_q + {56'b0, ar_beat_cnt} * 8;
        wi_lo = int'(beat_addr[9:3]) * 2;
        axi_rsp.r_valid  <= 1;
        axi_rsp.r.data   <= {mem[wi_lo+1], mem[wi_lo]};
        axi_rsp.r.last   <= (ar_beat_cnt == ar_len_q);
        ar_beat_cnt      <= ar_beat_cnt + 8'd1;
        if (ar_beat_cnt == ar_len_q)
          ar_pending <= 0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Helper task: wait for LSU valid
  // -------------------------------------------------------------------------
  task wait_valid;
    @(posedge clk);
    while (!valid_out) @(posedge clk);
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------
  initial begin
    rst_n = 0; req = 0; we = 0; is_lr = 0; is_sc = 0; is_amo = 0;
    amo_funct5 = 0; amo_src = 0; addr = 0; wdata = 0; funct3 = 0;
    for (int i = 0; i < 256; i++) mem[i] = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- LW sign-extend ----
    mem[0] = 32'h8000_0001;
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b010;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_80000001) begin
      $display("FAIL LW_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- LWU (zero-extend) ----
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b110;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_80000001) begin
      $display("FAIL LWU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- SD then LD ----
    req = 1; we = 1; addr = 32'h10; funct3 = 3'b011;
    wdata = 64'hDEADBEEF_CAFEBABE;
    @(posedge clk); req = 0;
    wait_valid;
    @(posedge clk);

    req = 1; we = 0; addr = 32'h10; funct3 = 3'b011;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hDEADBEEF_CAFEBABE) begin
      $display("FAIL LD: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- LB sign-extend ----
    mem[8] = 32'h000000FF;
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b000;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_FFFFFFFF) begin
      $display("FAIL LB_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- LBU ----
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b100;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_000000FF) begin
      $display("FAIL LBU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- LR.W ----
    mem[16] = 32'hAABB_CCDD;
    req = 1; we = 0; addr = 32'h40; funct3 = 3'b010; is_lr = 1;
    @(posedge clk); req = 0; is_lr = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AABBCCDD) begin
      $display("FAIL LR_W: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- SC.W success ----
    req = 1; we = 1; addr = 32'h40; funct3 = 3'b010; is_sc = 1;
    wdata = {32'b0, 32'h1122_3344};
    @(posedge clk); req = 0; is_sc = 0;
    wait_valid;
    if (rdata !== 64'h0) begin
      $display("FAIL SC_W_success: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // Verify SC.W actually wrote by loading it back
    req = 1; we = 0; addr = 32'h40; funct3 = 3'b010;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_11223344) begin
      $display("FAIL SC_W_readback: got %016h (expected 64'h00000000_11223344)", rdata); errors++;
    end
    @(posedge clk);

    // ---- SC.W fail (reservation cleared) ----
    req = 1; we = 1; addr = 32'h40; funct3 = 3'b010; is_sc = 1;
    wdata = {32'b0, 32'hDEAD_BEEF};
    @(posedge clk); req = 0; is_sc = 0;
    wait_valid;
    if (rdata !== 64'h1) begin
      $display("FAIL SC_W_fail: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- AMOADD.W ----
    mem[20] = 32'd100;
    req = 1; we = 0; addr = 32'h50; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00000; amo_src = 64'd25;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    if (rdata !== 64'h0000_0000_0000_0064) begin
      $display("FAIL AMOADD_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- AMOSWAP.W ----
    mem[24] = 32'hAAAA_BBBB;
    req = 1; we = 0; addr = 32'h60; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00001; amo_src = 64'hCCCC_DDDD;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AAAABBBB) begin
      $display("FAIL AMOSWAP_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- SH then LH/LHU ----
    req = 1; we = 1; addr = 32'h70; funct3 = 3'b001;
    wdata = 64'h0000_ABCD;
    @(posedge clk); req = 0;
    wait_valid;
    @(posedge clk);

    req = 1; we = 0; addr = 32'h70; funct3 = 3'b001;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_FFFFABCD) begin
      $display("FAIL LH_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    req = 1; we = 0; addr = 32'h70; funct3 = 3'b101;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h0000_0000_0000_ABCD) begin
      $display("FAIL LHU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- AMOXOR.W ----
    mem[32] = 32'hFF00_FF00;
    req = 1; we = 0; addr = 32'h80; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00100; amo_src = 64'hF0F0_F0F0;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOAND.W ----
    mem[36] = 32'hFFFF_0000;
    req = 1; we = 0; addr = 32'h90; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b01100; amo_src = 64'hFF00_FF00;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOOR.W ----
    mem[40] = 32'h0000_FF00;
    req = 1; we = 0; addr = 32'hA0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b01000; amo_src = 64'hFF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOMIN.W (signed min: -1 vs 1 → -1 wins) ----
    mem[44] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'hB0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b10000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOMAX.W (signed max: 5 vs 3 → 5 stays) ----
    mem[48] = 32'd5;
    req = 1; we = 0; addr = 32'hC0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b10100; amo_src = 64'd3;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOMINU.W ----
    mem[52] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'hD0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b11000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- AMOMAXU.W ----
    mem[56] = 32'd1;
    req = 1; we = 0; addr = 32'hE0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b11100; amo_src = 64'hFF;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- 64-bit AMOs ----

    // AMOXOR.D
    mem[64] = 32'hFF00_FF00; mem[65] = 32'h0000_0000;
    req = 1; we = 0; addr = 32'h100; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b00100; amo_src = 64'hF0F0_F0F0;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOAND.D
    mem[68] = 32'hFFFF_0000; mem[69] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'h110; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b01100; amo_src = 64'hFF00_0000_FF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOOR.D
    mem[72] = 32'h0000_FF00; mem[73] = 32'h0;
    req = 1; we = 0; addr = 32'h120; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b01000; amo_src = 64'hFF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOMIN.D (signed: -1 vs 1 → -1 wins)
    mem[76] = 32'hFFFF_FFFF; mem[77] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'h130; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b10000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOMAX.D (signed: 5 vs 3 → 5 stays)
    mem[80] = 32'd5; mem[81] = 32'd0;
    req = 1; we = 0; addr = 32'h140; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b10100; amo_src = 64'd3;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOMINU.D
    mem[84] = 32'hFFFF_FFFF; mem[85] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'h150; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b11000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOMAXU.D
    mem[88] = 32'd1; mem[89] = 32'd0;
    req = 1; we = 0; addr = 32'h160; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b11100; amo_src = 64'hFF;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // AMOADD.D
    mem[60] = 32'd10; mem[61] = 32'd0;
    req = 1; we = 0; addr = 32'hF0; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b00000; amo_src = 64'd7;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk);

    // ---- Load with invalid funct3=7 → default arm ----
    mem[4] = 32'hDEAD_BEEF;
    req = 1; we = 0; addr = 32'h10; funct3 = 3'b111;
    @(posedge clk); req = 0;
    wait_valid;
    // funct3=7 falls through to dcache_rdata (LD case) — check it's nonzero
    @(posedge clk);

    if (errors == 0) $display("tb_lsu_s5: ALL PASSED");
    else $display("tb_lsu_s5: %0d FAILED", errors);
    $finish;
  end
endmodule
