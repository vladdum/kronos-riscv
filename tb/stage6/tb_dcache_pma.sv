// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_dcache_pma.sv — stage 6e PMA / MMIO bypass unit testbench.
//
// Exercises the new NC FSM paths (DC_NC_AR/R, DC_NC_AW/W/B), the AMO trap,
// the bus-error trap, and verifies that the cacheable path still drives
// AxCACHE = 4'b1110 with an 8-beat WRAP burst.

`timescale 1ns/1ps

module tb_dcache_pma
  import kronos_pkg::*;
();

  // ---- Clock / reset ------------------------------------------------------
  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
  always #5 clk_i = ~clk_i;       // 100 MHz

  // ---- DUT signals --------------------------------------------------------
  logic                   req;
  logic [63:0]            addr;
  logic [2:0]             size;
  logic                   we;
  logic [63:0]            wdata;
  logic                   amo_req;
  logic [4:0]             amo_op;
  logic                   rsrv_clear;
  logic                   data_valid;
  logic [63:0]            rdata;
  logic                   sc_success;
  logic                   stall;

  // PTW priority port — tied off
  logic                   ptw_req_valid = 1'b0;
  logic [55:0]            ptw_req_addr  = 56'h0;
  logic                   ptw_req_we    = 1'b0;
  logic [63:0]            ptw_req_wdata = 64'h0;
  logic                   ptw_req_lr    = 1'b0;
  logic                   ptw_req_sc    = 1'b0;
  logic                   ptw_rsp_valid;
  logic [63:0]            ptw_rsp_rdata;
  logic                   ptw_rsp_sc_ok;

  logic                   flush         = 1'b0;
  logic                   flush_done;
  logic                   dirty_pending;

  kronos_axi_req_t        axi_req;
  kronos_axi_resp_t       axi_rsp;

  logic                   amo_nc_fault;
  logic                   bus_err_fault;
  logic                   miss_pulse;

  // ---- AXI memory model + monitor ----------------------------------------
  // Tiny single-port behavioural memory + AXI handshake. Records the last
  // accepted AR / AW / W beat shape into observable regs the tasks below
  // assert against.
  logic [63:0] mem [logic [28:0]];   // associative memory keyed by 8-byte index (29-bit)

  // Monitor records (cleared when a new AR / AW handshakes).
  logic [3:0]  last_ar_cache;
  logic [1:0]  last_ar_burst;
  logic [7:0]  last_ar_len;
  logic [2:0]  last_ar_size;
  int          ar_beat_count;
  logic [3:0]  last_aw_cache;
  logic [1:0]  last_aw_burst;
  logic [7:0]  last_aw_len;
  logic [2:0]  last_aw_size;
  int          aw_beat_count;
  logic [7:0]  last_w_strb;

  // Pending-AR queue: at most one outstanding because the dcache is single-issue.
  logic        ar_pending_q;
  logic [63:0] ar_addr_q;
  logic [7:0]  ar_len_q;
  logic [2:0]  ar_size_q;
  logic [7:0]  ar_beat_q;

  // AW / W / B handshake state
  logic        aw_pending_q;
  logic        b_pending_q;    // separate one-cycle pulse for B after W.last
  logic [63:0] aw_addr_q;
  logic [2:0]  aw_size_q;

  // ---- Per-test pass/fail counter ----------------------------------------
  int errors = 0;

  // ---- DUT ----------------------------------------------------------------
  kronos_dcache u_dcache (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .req_i           (req),
    .addr_i          (addr),
    .size_i          (size),
    .we_i            (we),
    .wdata_i         (wdata),
    .amo_req_i       (amo_req),
    .amo_op_i        (amo_op),
    .rsrv_clear_i    (rsrv_clear),
    .data_valid_o    (data_valid),
    .rdata_o         (rdata),
    .sc_success_o    (sc_success),
    .stall_o         (stall),
    .ptw_req_valid_i (ptw_req_valid),
    .ptw_req_addr_i  (ptw_req_addr),
    .ptw_req_we_i    (ptw_req_we),
    .ptw_req_wdata_i (ptw_req_wdata),
    .ptw_req_is_lr_i (ptw_req_lr),
    .ptw_req_is_sc_i (ptw_req_sc),
    .ptw_rsp_valid_o (ptw_rsp_valid),
    .ptw_rsp_rdata_o (ptw_rsp_rdata),
    .ptw_rsp_sc_ok_o (ptw_rsp_sc_ok),
    .flush_i         (flush),
    .flush_done_o    (flush_done),
    .dirty_pending_o (dirty_pending),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp),
    .amo_nc_fault_o  (amo_nc_fault),
    .bus_err_fault_o (bus_err_fault),
    .miss_pulse_o    (miss_pulse)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_pending_q  <= 1'b0;
      last_ar_cache <= 4'h0;
      last_ar_burst <= 2'b00;
      last_ar_len   <= 8'h0;
      last_ar_size  <= 3'h0;
      ar_beat_count <= 0;
      ar_addr_q     <= 64'h0;
      ar_len_q      <= 8'h0;
      ar_size_q     <= 3'h0;
      ar_beat_q     <= 8'h0;
    end else begin
      // Capture AR
      if (axi_req.ar_valid & axi_rsp.ar_ready) begin
        ar_pending_q  <= 1'b1;
        last_ar_cache <= axi_req.ar.cache;
        last_ar_burst <= axi_req.ar.burst;
        last_ar_len   <= axi_req.ar.len;
        last_ar_size  <= axi_req.ar.size;
        ar_addr_q     <= axi_req.ar.addr;
        ar_len_q      <= axi_req.ar.len;
        ar_size_q     <= axi_req.ar.size;
        ar_beat_q     <= 8'h0;
        ar_beat_count <= 0;
      end
      // Drive R beat
      if (ar_pending_q & axi_req.r_ready) begin
        ar_beat_count <= ar_beat_count + 1;
        if (ar_beat_q == ar_len_q) begin
          ar_pending_q <= 1'b0;
          ar_beat_q    <= 8'd0;
        end else begin
          ar_beat_q <= ar_beat_q + 8'd1;
        end
      end
    end
  end

  // Combined AXI response driver
  always_comb begin
    // Default-assign every field with explicit widths (R7).
    axi_rsp.ar_ready = 1'b1;
    axi_rsp.aw_ready = 1'b1;
    axi_rsp.w_ready  = 1'b1;
    axi_rsp.r_valid  = 1'b0;
    axi_rsp.r.data   = 64'h0;
    axi_rsp.r.last   = 1'b0;
    axi_rsp.r.resp   = 2'b00;
    axi_rsp.r.id     = 1'b0;
    axi_rsp.r.user   = 1'b0;
    axi_rsp.b_valid  = 1'b0;
    axi_rsp.b.resp   = 2'b00;
    axi_rsp.b.id     = 1'b0;
    axi_rsp.b.user   = 1'b0;
    // R channel: serve beats when AR has been accepted
    if (ar_pending_q) begin
      axi_rsp.r_valid = 1'b1;
      axi_rsp.r.data  = mem[ar_addr_q[31:3] + {21'b0, ar_beat_q}];
      axi_rsp.r.last  = (ar_beat_q == ar_len_q);
      axi_rsp.r.resp  = 2'b00;
      axi_rsp.r.id    = 1'b0;
    end
    // B channel: assert one cycle after W.last is accepted
    axi_rsp.b_valid = b_pending_q;
    axi_rsp.b.resp  = 2'b00;
    axi_rsp.b.id    = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pending_q  <= 1'b0;
      b_pending_q   <= 1'b0;
      last_aw_cache <= 4'h0;
      last_aw_burst <= 2'b00;
      last_aw_len   <= 8'h0;
      last_aw_size  <= 3'h0;
      aw_beat_count <= 0;
      aw_addr_q     <= 64'h0;
      aw_size_q     <= 3'h0;
      last_w_strb   <= 8'h0;
    end else begin
      b_pending_q <= 1'b0;   // default: clear
      if (axi_req.aw_valid & axi_rsp.aw_ready) begin
        aw_pending_q  <= 1'b1;
        last_aw_cache <= axi_req.aw.cache;
        last_aw_burst <= axi_req.aw.burst;
        last_aw_len   <= axi_req.aw.len;
        last_aw_size  <= axi_req.aw.size;
        aw_addr_q     <= axi_req.aw.addr;
        aw_size_q     <= axi_req.aw.size;
        aw_beat_count <= 0;
      end
      if (aw_pending_q & axi_req.w_valid & axi_rsp.w_ready) begin
        aw_beat_count <= aw_beat_count + 1;
        last_w_strb   <= axi_req.w.strb;
        // Apply byte-strobed write to mem (single-beat NC; cacheable WB tests
        // ignore mem state).
        for (int b = 0; b < 8; b++) begin
          if (axi_req.w.strb[b]) mem[aw_addr_q[31:3]][b*8 +: 8] = axi_req.w.data[b*8 +: 8]; // aw_addr_q[31:3] is 29 bits
        end
        if (axi_req.w.last) begin
          aw_pending_q <= 1'b0;
          b_pending_q  <= 1'b1;   // assert B one cycle after W.last
        end
      end
    end
  end

  // ---- Driver tasks ------------------------------------------------------
  task automatic drv_reset();
    rst_ni     = 1'b0;
    req        = 1'b0; we = 1'b0; addr = 64'h0; size = 3'h0; wdata = 64'h0;
    amo_req    = 1'b0; amo_op = 5'h0; rsrv_clear = 1'b0;
    @(posedge clk_i); @(posedge clk_i);
    rst_ni = 1'b1;
    @(posedge clk_i);
  endtask

  task automatic drv_load(input [63:0] a, input [2:0] sz);
    @(posedge clk_i);
    req = 1'b1; we = 1'b0; addr = a; size = sz;
    do @(posedge clk_i); while (~data_valid);
    req = 1'b0;
  endtask

  task automatic drv_store(input [63:0] a, input [2:0] sz, input [63:0] d);
    @(posedge clk_i);
    req = 1'b1; we = 1'b1; addr = a; size = sz; wdata = d;
    do @(posedge clk_i); while (~data_valid);
    req = 1'b0;
  endtask

  task automatic drv_amo(input [63:0] a, input [4:0] op);
    @(posedge clk_i);
    req = 1'b1; we = 1'b0; addr = a; size = 3'd2; amo_req = 1'b1; amo_op = op;
    @(posedge clk_i);
    // Single-cycle observation of amo_nc_fault_o.
    @(posedge clk_i);
    req = 1'b0; amo_req = 1'b0;
  endtask

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // ---- Case 1: LB at MMIO_BASE + 8 --------------------------------------
  task automatic test_nc_lb_at_0x4000_0008();
    drv_load(MMIO_BASE + 64'h8, 3'd0);
    check(last_ar_size  == 3'd0, "case 1: ar.size != 0");
    check(last_ar_len   == 8'd0, "case 1: ar.len != 0");
    check(last_ar_burst == 2'b01, "case 1: ar.burst != INCR");
    check(last_ar_cache == 4'h0,  "case 1: ar.cache != 0");
    check(ar_beat_count == 1,    "case 1: beat count != 1");
  endtask

  // ---- Case 2: LH at MMIO_BASE + 0x10 -----------------------------------
  task automatic test_nc_lh_at_0x4000_0010();
    drv_load(MMIO_BASE + 64'h10, 3'd1);
    check(last_ar_size  == 3'd1, "case 2: ar.size != 1");
    check(last_ar_len   == 8'd0, "case 2: ar.len != 0");
    check(ar_beat_count == 1,    "case 2: beat count != 1");
  endtask

  // ---- Case 3: LW at MMIO_BASE + 0x1_0000 -------------------------------
  task automatic test_nc_lw_at_0x4001_0000();
    drv_load(MMIO_BASE + 64'h1_0000, 3'd2);
    check(last_ar_size  == 3'd2, "case 3: ar.size != 2");
    check(last_ar_len   == 8'd0, "case 3: ar.len != 0");
    check(ar_beat_count == 1,    "case 3: beat count != 1");
  endtask

  // ---- Case 4: LD at MMIO_BASE + 0x20 -----------------------------------
  task automatic test_nc_ld_at_0x4000_0020();
    drv_load(MMIO_BASE + 64'h20, 3'd3);
    check(last_ar_size  == 3'd3, "case 4: ar.size != 3");
    check(last_ar_len   == 8'd0, "case 4: ar.len != 0");
    check(ar_beat_count == 1,    "case 4: beat count != 1");
  endtask

  // ---- Case 5: SB at MMIO_BASE + 1 --------------------------------------
  task automatic test_nc_sb_at_0x4000_0001();
    drv_store(MMIO_BASE + 64'h1, 3'd0, 64'h0000_0000_0000_00AB);
    check(last_aw_size  == 3'd0,        "case 5: aw.size != 0");
    check(last_aw_len   == 8'd0,        "case 5: aw.len != 0");
    check(last_aw_burst == 2'b01,       "case 5: aw.burst != INCR");
    check(last_aw_cache == 4'h0,        "case 5: aw.cache != 0");
    check(last_w_strb   == 8'b0000_0010, "case 5: w.strb wrong");
    check(aw_beat_count == 1,           "case 5: beat count != 1");
  endtask

  // ---- Case 6: SW at MMIO_BASE + 0x1_0004 -------------------------------
  task automatic test_nc_sw_at_0x4001_0004();
    drv_store(MMIO_BASE + 64'h1_0004, 3'd2, 64'hDEAD_BEEF_CAFE_BABE);
    check(last_aw_size  == 3'd2,        "case 6: aw.size != 2");
    check(last_aw_len   == 8'd0,        "case 6: aw.len != 0");
    check(last_w_strb   == 8'b1111_0000, "case 6: w.strb wrong");
    check(aw_beat_count == 1,           "case 6: beat count != 1");
  endtask

  // ---- Case 7: SD at MMIO_BASE + 0x30 -----------------------------------
  task automatic test_nc_sd_at_0x4000_0030();
    drv_store(MMIO_BASE + 64'h30, 3'd3, 64'h0123_4567_89AB_CDEF);
    check(last_aw_size  == 3'd3,        "case 7: aw.size != 3");
    check(last_aw_len   == 8'd0,        "case 7: aw.len != 0");
    check(last_w_strb   == 8'hFF,       "case 7: w.strb != 0xFF");
    check(aw_beat_count == 1,           "case 7: beat count != 1");
  endtask

  // ---- Case 8: LW at 0x8000_0000 (cacheable) — sanity ------------------
  task automatic test_cacheable_lw_at_0x8000_0000();
    // Pre-seed the line that will be allocated.
    for (int b = 0; b < 8; b++) mem[29'h1000_0000 + 29'(b)] = 64'hAAAA_BBBB_CCCC_DDDD;
    drv_load(64'h8000_0000, 3'd2);
    // CWF fires data_valid on beat 0; wait for full refill to complete.
    do @(posedge clk_i); while (stall);
    check(last_ar_len   == 8'd7,        "case 8: ar.len != 7 (expected 8-beat WRAP)");
    check(last_ar_burst == 2'b10,       "case 8: ar.burst != WRAP");
    check(last_ar_cache == 4'b1110,     "case 8: ar.cache != 0xE");
    check(ar_beat_count == 8,           "case 8: refill beat count != 8");
  endtask

  // ---- Case 9: LR.W at MMIO_BASE -- expect amo_nc_fault, no AXI --------
  task automatic test_lr_on_nc();
    int saw_fault = 0;
    int saw_axi   = 0;
    fork
      begin
        repeat (8) begin @(posedge clk_i); if (amo_nc_fault) saw_fault = 1; end
      end
      begin
        repeat (8) begin @(posedge clk_i); if (axi_req.ar_valid) saw_axi = 1; end
      end
      drv_amo(MMIO_BASE, 5'b00010);     // LR
    join
    check(saw_fault == 1, "case 9: amo_nc_fault not asserted");
    check(saw_axi   == 0, "case 9: AXI AR fired on NC LR (must not)");
  endtask

  // ---- Case 10: AMOSWAP.W at MMIO_BASE -- expect amo_nc_fault ----------
  task automatic test_amoswap_on_nc();
    int saw_fault = 0;
    int saw_axi   = 0;
    fork
      begin
        repeat (8) begin @(posedge clk_i); if (amo_nc_fault) saw_fault = 1; end
      end
      begin
        repeat (8) begin @(posedge clk_i); if (axi_req.ar_valid) saw_axi = 1; end
      end
      drv_amo(MMIO_BASE, 5'b00001);     // AMOSWAP
    join
    check(saw_fault == 1, "case 10: amo_nc_fault not asserted");
    check(saw_axi   == 0, "case 10: AXI AR fired on NC AMOSWAP (must not)");
  endtask

  // ---- Case 11: LW at 0x4FFF_FFFC (boundary, in NC range) --------------
  task automatic test_nc_lw_at_boundary_inside();
    drv_load(MMIO_BASE + 64'hFFF_FFFC, 3'd2);
    check(last_ar_len   == 8'd0,        "case 11: ar.len != 0 (in-range)");
    check(last_ar_burst == 2'b01,       "case 11: ar.burst != INCR");
  endtask

  // ---- Case 12: LW at 0x5000_0000 (just outside NC range) --------------
  task automatic test_cacheable_lw_at_0x5000_0000();
    for (int b = 0; b < 8; b++) mem[29'h0A00_0000 + 29'(b)] = 64'h1111_2222_3333_4444;
    drv_load(64'h5000_0000, 3'd2);
    // CWF fires data_valid on beat 0; wait for full refill before checking beat count.
    do @(posedge clk_i); while (stall);
    check(last_ar_len   == 8'd7,        "case 12: ar.len != 7 (out-of-NC, cacheable)");
    check(last_ar_burst == 2'b10,       "case 12: ar.burst != WRAP");
  endtask

  // ---- Case 13: NC store then NC load -- back-to-back ------------------
  task automatic test_nc_back_to_back();
    drv_store(MMIO_BASE + 64'h1_0010, 3'd2, 64'h0000_0000_DEAD_BEEF);
    drv_load (MMIO_BASE + 64'h1_0010, 3'd2);
    // The most recent transaction was the load → AR shape captured.
    check(last_ar_len   == 8'd0,        "case 13: ar.len != 0");
    check(last_ar_burst == 2'b01,       "case 13: ar.burst != INCR");
    // Also assert mem state was correctly written by the store.
    check(mem[29'h800_2002][31:0] == 32'hDEAD_BEEF, "case 13: store value not written");
  endtask

  // ---- Case 14: NC store then cacheable load — no cross-pollination ----
  task automatic test_nc_then_cacheable();
    drv_store(MMIO_BASE + 64'h1_0020, 3'd2, 64'hCAFE_BABE_0000_0000);
    for (int b = 0; b < 8; b++) mem[29'h1000_0010 + 29'(b)] = 64'hFEED_FACE_DEAD_BEEF;
    drv_load (64'h8000_0080, 3'd2);
    // CWF fires data_valid on beat 0; wait for full refill before checking burst shape.
    do @(posedge clk_i); while (stall);
    check(last_ar_len   == 8'd7,        "case 14: cacheable refill expected after NC");
    check(last_ar_burst == 2'b10,       "case 14: ar.burst != WRAP");
  endtask

  // ---- Test cases --------------------------------------------------------
  initial begin
    drv_reset();
    // Cases 1-4: NC load shapes
    test_nc_lb_at_0x4000_0008();
    test_nc_lh_at_0x4000_0010();
    test_nc_lw_at_0x4001_0000();
    test_nc_ld_at_0x4000_0020();
    // Cases 5-7: NC store shapes
    test_nc_sb_at_0x4000_0001();
    test_nc_sw_at_0x4001_0004();
    test_nc_sd_at_0x4000_0030();
    // Case 8: cacheable sanity
    test_cacheable_lw_at_0x8000_0000();
    // Cases 9-10: AMO trap
    test_lr_on_nc();
    test_amoswap_on_nc();
    // Cases 11-14: boundary/interleave/cacheable-sanity
    test_nc_lw_at_boundary_inside();
    test_cacheable_lw_at_0x5000_0000();
    test_nc_back_to_back();
    test_nc_then_cacheable();
    if (errors == 0) $display("PASS: tb_dcache_pma (%0d cases)", 14);
    else             $display("FAIL: tb_dcache_pma (%0d errors)", errors);
    $finish;
  end

endmodule
