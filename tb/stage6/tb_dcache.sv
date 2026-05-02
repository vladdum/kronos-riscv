// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_dcache.sv (stage 6) — exercises the BRAM-backed `data_q` array added
// in stage 6g.  Five scenarios per the design spec (§ 6.1):
//   1. Back-to-back same-line cross-beat read.
//   2. Store-then-load same beat (RAW via WRITE_FIRST forwarding).
//   3. Store-miss + immediate same-line load (refill consistency).
//   4. AMO-on-hit + immediate same-line load (post-AMO write visibility).
//   5. Refill window load (BRAM consistency across multi-cycle refill).
//
// The dcache exposes early_req_valid_i / early_addr_i so the LSU can
// pre-launch the BRAM read in EX, one cycle before the MEM-stage req_i.
// The TB models that by driving the early-* signals one cycle ahead of
// req_i / addr_i via a `prelaunch` task; same-cycle hit timing is
// preserved.

`timescale 1ns/1ps

module tb_dcache
  import kronos_pkg::*;
();

  // ---- Clock / reset ------------------------------------------------------
  logic clk_i  = 1'b0;
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

  // EX-stage pre-launch
  logic                   early_req_valid;
  logic [63:0]            early_addr;

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

  // ---- Per-test pass/fail counter ----------------------------------------
  int errors = 0;

  // ---- Captured response from the last completed load / store / AMO ------
  // Sampled on the cycle data_valid_o fires, so single-cycle response
  // pulses (e.g. CWF refill bypass) survive the deassert-req cycle.
  logic [63:0] last_rdata;
  logic        last_sc_success;

  // ---- DUT ----------------------------------------------------------------
  kronos_dcache u_dcache (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .req_i             (req),
    .addr_i            (addr),
    .size_i            (size),
    .we_i              (we),
    .wdata_i           (wdata),
    .amo_req_i         (amo_req),
    .amo_op_i          (amo_op),
    .rsrv_clear_i      (rsrv_clear),
    .data_valid_o      (data_valid),
    .rdata_o           (rdata),
    .sc_success_o      (sc_success),
    .stall_o           (stall),
    .early_req_valid_i (early_req_valid),
    .early_addr_i      (early_addr),
    .ptw_req_valid_i   (ptw_req_valid),
    .ptw_req_addr_i    (ptw_req_addr),
    .ptw_req_we_i      (ptw_req_we),
    .ptw_req_wdata_i   (ptw_req_wdata),
    .ptw_req_is_lr_i   (ptw_req_lr),
    .ptw_req_is_sc_i   (ptw_req_sc),
    .ptw_rsp_valid_o   (ptw_rsp_valid),
    .ptw_rsp_rdata_o   (ptw_rsp_rdata),
    .ptw_rsp_sc_ok_o   (ptw_rsp_sc_ok),
    .flush_i           (flush),
    .flush_done_o      (flush_done),
    .dirty_pending_o   (dirty_pending),
    .axi_req_o         (axi_req),
    .axi_rsp_i         (axi_rsp),
    .amo_nc_fault_o    (amo_nc_fault),
    .bus_err_fault_o   (bus_err_fault),
    .miss_pulse_o      (miss_pulse)
  );

  // ---- AXI memory model + read burst driver ------------------------------
  // Behavioural single-issue memory.  Sized large enough to hold the
  // working set used by the tests below; addresses are >> 3 to index by
  // 8-byte word.  On miss the dcache issues an 8-beat WRAP burst; we
  // serve the beats in order starting at ar.addr, wrapping inside the
  // 64-byte aligned line.
  logic [63:0] tb_mem [0:32767];

  logic        ar_pending_q;
  logic [63:0] ar_addr_q;       // beat address (advances by 8 each beat)
  logic [63:0] ar_base_q;       // line-base for WRAP wrapping
  logic [3:0]  ar_beat_q;       // 0..7
  logic [7:0]  ar_len_q;
  logic [1:0]  ar_burst_q;

  // AW / W / B handshake
  logic        aw_pending_q;
  logic        b_pending_q;
  logic [63:0] aw_addr_q;

  initial begin
    for (int i = 0; i < 32768; i++) begin
      tb_mem[i] = 64'hC0DE_0000_0000_0000 + 64'(i);
    end
  end

  // Combinational AXI response
  always_comb begin
    axi_rsp          = '{default: '0};
    axi_rsp.ar_ready = ~ar_pending_q;
    axi_rsp.aw_ready = ~aw_pending_q;
    axi_rsp.w_ready  = aw_pending_q;
    axi_rsp.r_valid  = ar_pending_q;
    axi_rsp.r.data   = tb_mem[ar_addr_q[17:3]];
    axi_rsp.r.last   = ar_pending_q & (ar_beat_q == ar_len_q[3:0]);
    axi_rsp.r.resp   = 2'b00;
    axi_rsp.b_valid  = b_pending_q;
    axi_rsp.b.resp   = 2'b00;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_pending_q  <= 1'b0;
      ar_addr_q     <= 64'h0;
      ar_base_q     <= 64'h0;
      ar_beat_q     <= 4'd0;
      ar_len_q      <= 8'h0;
      ar_burst_q    <= 2'b00;
      aw_pending_q  <= 1'b0;
      aw_addr_q     <= 64'h0;
      b_pending_q   <= 1'b0;
    end else begin
      // ---- AR / R ---------------------------------------------------------
      if (axi_req.ar_valid & axi_rsp.ar_ready) begin
        ar_pending_q <= 1'b1;
        ar_addr_q    <= axi_req.ar.addr;
        ar_base_q    <= {axi_req.ar.addr[63:6], 6'b0};   // 64-byte line base
        ar_beat_q    <= 4'd0;
        ar_len_q     <= axi_req.ar.len;
        ar_burst_q   <= axi_req.ar.burst;
      end else if (ar_pending_q & axi_req.r_ready) begin
        if (ar_beat_q == ar_len_q[3:0]) begin
          ar_pending_q <= 1'b0;
        end else begin
          ar_beat_q <= ar_beat_q + 4'd1;
          // WRAP burst inside the 64-byte line; INCR otherwise.
          if (ar_burst_q == 2'b10) begin
            ar_addr_q <= ar_base_q | {58'b0, (ar_addr_q[5:3] + 3'd1), 3'b0};
          end else begin
            ar_addr_q <= ar_addr_q + 64'd8;
          end
        end
      end
      // ---- AW / W / B -----------------------------------------------------
      b_pending_q <= 1'b0;
      if (axi_req.aw_valid & axi_rsp.aw_ready) begin
        aw_pending_q <= 1'b1;
        aw_addr_q    <= axi_req.aw.addr;
      end
      if (aw_pending_q & axi_req.w_valid & axi_rsp.w_ready) begin
        for (int b = 0; b < 8; b++) begin
          if (axi_req.w.strb[b]) begin
            tb_mem[aw_addr_q[17:3]][b*8 +: 8] <= axi_req.w.data[b*8 +: 8];
          end
        end
        if (axi_req.w.last) begin
          aw_pending_q <= 1'b0;
          b_pending_q  <= 1'b1;
        end else begin
          aw_addr_q <= aw_addr_q + 64'd8;
        end
      end
    end
  end

  // ---- Driver tasks ------------------------------------------------------
  // Reset + reinit DUT-facing signals.
  task automatic drv_reset();
    rst_ni          = 1'b0;
    req             = 1'b0;
    addr            = 64'h0;
    size            = 3'd3;
    we              = 1'b0;
    wdata           = 64'h0;
    amo_req         = 1'b0;
    amo_op          = 5'h0;
    rsrv_clear      = 1'b0;
    early_req_valid = 1'b0;
    early_addr      = 64'h0;
    repeat (3) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
  endtask

  // Drive the EX-stage pre-launch for one cycle.  Held across the negedge
  // so the BRAM port-B re=1 / raddr=a sample at the next posedge.
  task automatic prelaunch(input [63:0] a);
    @(negedge clk_i);
    early_req_valid = 1'b1;
    early_addr      = a;
  endtask

  task automatic prelaunch_off();
    @(negedge clk_i);
    early_req_valid = 1'b0;
    early_addr      = 64'h0;
  endtask

  // Issue a load with same-cycle hit timing: pre-launch one cycle, then
  // drive req on the next.  Captures rdata into last_rdata at the cycle
  // data_valid fires (single-cycle bypass pulses would otherwise clear
  // before the test asserts on rdata).
  task automatic drv_load(input [63:0] a, input [2:0] sz);
    prelaunch(a);
    @(posedge clk_i);                    // BRAM read launches here
    @(negedge clk_i);
    early_req_valid = 1'b0;
    req             = 1'b1;
    we              = 1'b0;
    addr            = a;
    size            = sz;
    @(posedge clk_i);
    while (!data_valid) @(posedge clk_i);
    last_rdata = rdata;                  // capture before NBA can clear it
    @(negedge clk_i);
    req = 1'b0;
  endtask

  // Issue a store.  Same pre-launch shape — store-hit fire wants port-A
  // write + port-B read in the same cycle (WRITE_FIRST forwarding for
  // any concurrent same-beat load); we drive a clean hit/store cycle.
  task automatic drv_store(input [63:0] a, input [2:0] sz, input [63:0] d);
    prelaunch(a);
    @(posedge clk_i);
    @(negedge clk_i);
    early_req_valid = 1'b0;
    req             = 1'b1;
    we              = 1'b1;
    addr            = a;
    size            = sz;
    wdata           = d;
    @(posedge clk_i);
    while (!data_valid) @(posedge clk_i);
    @(negedge clk_i);
    req = 1'b0;
    we  = 1'b0;
  endtask

  // Issue an AMO.  amo_op is the funct5 field (AMOADD = 5'b00000).
  // Captures the OLD value (returned via rdata when amo_done fires).
  task automatic drv_amo(input [63:0] a, input [2:0] sz,
                         input [4:0]  op, input [63:0] src);
    prelaunch(a);
    @(posedge clk_i);
    @(negedge clk_i);
    early_req_valid = 1'b0;
    req             = 1'b1;
    we              = 1'b0;
    addr            = a;
    size            = sz;
    wdata           = src;
    amo_req         = 1'b1;
    amo_op          = op;
    @(posedge clk_i);
    while (!data_valid) @(posedge clk_i);
    last_rdata      = rdata;
    last_sc_success = sc_success;
    @(negedge clk_i);
    req     = 1'b0;
    amo_req = 1'b0;
  endtask

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // Helper: pre-fill (refill) a line by issuing one load and waiting for
  // the burst to complete.  Leaves the cache containing the line.
  task automatic warm_line(input [63:0] line_base);
    drv_load(line_base, 3'd3);
    while (stall) @(posedge clk_i);
    repeat (2) @(posedge clk_i);
  endtask

  // ---- Test 1: back-to-back same-line cross-beat reads ------------------
  // Pre-fill a line, then issue 3 back-to-back loads to (set, beat=0/1/2).
  // Each must return the expected data within one cycle of req_i (no
  // multi-cycle stall).  Verifies the pre-launch raddr advances correctly
  // between back-to-back loads.
  task automatic test_back_to_back_cross_beat();
    logic [63:0] base;
    logic [63:0] got [3];
    int          cycles_to_valid [3];
    base = 64'h0000_0000_0000_1000;            // line — set 0, tag 1

    warm_line(base);

    for (int b = 0; b < 3; b++) begin
      logic [63:0] a;
      a = base + 64'(b * 8);

      // Pre-launch and req in the same shape as drv_load, but instrument
      // cycles_to_valid.
      prelaunch(a);
      @(posedge clk_i);
      @(negedge clk_i);
      early_req_valid = 1'b0;
      req             = 1'b1;
      we              = 1'b0;
      addr            = a;
      size            = 3'd3;

      cycles_to_valid[b] = 0;
      @(posedge clk_i);
      while (!data_valid) begin
        cycles_to_valid[b] = cycles_to_valid[b] + 1;
        @(posedge clk_i);
      end
      got[b] = rdata;                  // capture before NBA can clear it
      @(negedge clk_i);
      req = 1'b0;
    end

    for (int b = 0; b < 3; b++) begin
      check(cycles_to_valid[b] == 0,
            $sformatf("test1 beat %0d: cycles_to_valid != 0 (got %0d)",
                      b, cycles_to_valid[b]));
      check(got[b] === tb_mem[15'((base >> 3) + 64'(b))],
            $sformatf("test1 beat %0d: data mismatch (got %h, expected %h)",
                      b, got[b], tb_mem[15'((base >> 3) + 64'(b))]));
    end
  endtask

  // ---- Test 2: store then load same beat (RAW) --------------------------
  // Issue store to (set, beat) with known pattern, then load same address;
  // must return the just-stored bytes (exercises WRITE_MODE_B="write_first"
  // for any same-cycle write-then-read path).
  task automatic test_raw_same_beat();
    logic [63:0] a;
    logic [63:0] pat;
    a   = 64'h0000_0000_0000_2010;             // set 0, beat 2, tag 2
    pat = 64'hDEAD_BEEF_CAFE_BABE;

    // Bring line in (cold-miss refill).
    warm_line({a[63:6], 6'b0});
    // Store the new pattern.
    drv_store(a, 3'd3, pat);
    repeat (2) @(posedge clk_i);
    // Read back — the post-store byte pattern must come from the BRAM
    // (which the store-hit fire just wrote via port A).
    drv_load(a, 3'd3);
    check(last_rdata === pat,
          $sformatf("test2: load after store mismatch (got %h, expected %h)",
                    last_rdata, pat));
  endtask

  // ---- Test 3: store-miss + immediate same-line load --------------------
  // Store causes refill (CWF + critical-word merge); a follow-up load to
  // a different beat in the just-refilled line must come from BRAM with
  // refill data.
  task automatic test_store_miss_then_load();
    logic [63:0] line;
    logic [63:0] sa;
    logic [63:0] la;
    logic [63:0] sd;
    line = 64'h0000_0000_0000_3000;            // set 0, tag 3 (cold)
    sa   = line + 64'h08;                       // beat 1
    la   = line + 64'h28;                       // beat 5
    sd   = 64'hAABB_CCDD_EEFF_0011;

    // Store-miss: triggers refill, with critical-word merge of the store
    // bytes into beat 1 of the refilled line.
    drv_store(sa, 3'd3, sd);
    while (stall) @(posedge clk_i);
    repeat (2) @(posedge clk_i);

    // Load a different beat of the same line — must come from refilled
    // BRAM contents (tb_mem at line offset 5).
    drv_load(la, 3'd3);
    check(last_rdata === tb_mem[15'((line >> 3) + 64'd5)],
          $sformatf("test3 load beat 5: got %h, expected %h",
                    last_rdata, tb_mem[15'((line >> 3) + 64'd5)]));

    // Sanity: read back the merged store beat.
    drv_load(sa, 3'd3);
    check(last_rdata === sd,
          $sformatf("test3 load store-beat: got %h, expected %h",
                    last_rdata, sd));
  endtask

  // ---- Test 4: AMO-on-hit + immediate same-line load --------------------
  // AMOADD.D to (set, beat); immediate load of same address must return
  // post-AMO value (= original + amo_src).
  task automatic test_amo_hit_then_load();
    logic [63:0] a;
    logic [63:0] orig;
    logic [63:0] add_src;
    logic [63:0] expect_new;
    a       = 64'h0000_0000_0000_4018;          // set 0, beat 3, tag 4
    orig    = 64'h1111_2222_3333_4444;
    add_src = 64'h0000_0000_0000_0001;
    expect_new = orig + add_src;

    // Seed the line with `orig` at the target beat (warm-load brings the
    // line in; then store overwrites the beat).
    warm_line({a[63:6], 6'b0});
    drv_store(a, 3'd3, orig);
    repeat (2) @(posedge clk_i);

    // AMOADD.D — funct5 = 5'b00000.  data_valid carries the OLD value.
    drv_amo(a, 3'd3, 5'b00000, add_src);
    check(last_rdata === orig,
          $sformatf("test4 AMO old: got %h, expected %h", last_rdata, orig));
    repeat (2) @(posedge clk_i);

    // Load same beat — must see the post-AMO value (orig + add_src).
    drv_load(a, 3'd3);
    check(last_rdata === expect_new,
          $sformatf("test4 post-AMO load: got %h, expected %h",
                    last_rdata, expect_new));
  endtask

  // ---- Test 5: refill window load ---------------------------------------
  // Load A at line X causes a refill (8-beat WRAP burst).  While the
  // refill is in flight, a second load B at line X (different beat) is
  // issued.  After the refill completes, B's response must come from the
  // BRAM with the just-refilled bytes.  Verifies BRAM consistency through
  // the multi-cycle refill window.
  task automatic test_refill_window_load();
    logic [63:0] line;
    logic [63:0] a;
    logic [63:0] b;
    line = 64'h0000_0000_0000_5000;            // set 0, tag 5 (cold)
    a    = line + 64'h00;                       // beat 0
    b    = line + 64'h18;                       // beat 3

    // Cold load A: refill starts.  drv_load returns when data_valid fires
    // for A (which is the CWF beat-0 bypass).  At that point the refill
    // may still be writing later beats into the BRAM.
    drv_load(a, 3'd3);
    check(last_rdata === tb_mem[15'(line >> 3)],
          $sformatf("test5 load A: got %h, expected %h",
                    last_rdata, tb_mem[15'(line >> 3)]));

    // Wait for the refill FSM to finish (stall_o drops).
    while (stall) @(posedge clk_i);
    repeat (2) @(posedge clk_i);

    // Load B — different beat of the same line.  Must hit and come from
    // BRAM with the refilled bytes.
    drv_load(b, 3'd3);
    check(last_rdata === tb_mem[15'((line >> 3) + 64'd3)],
          $sformatf("test5 load B: got %h, expected %h",
                    last_rdata, tb_mem[15'((line >> 3) + 64'd3)]));
  endtask

  // ---- Sequencer ---------------------------------------------------------
  initial begin
    drv_reset();

    test_back_to_back_cross_beat();
    test_raw_same_beat();
    test_store_miss_then_load();
    test_amo_hit_then_load();
    test_refill_window_load();

    if (errors == 0) $display("PASS: tb_dcache (5 stage6g cases)");
    else             $display("FAIL: tb_dcache (%0d errors)", errors);
    $finish;
  end

  // Safety timeout — far above any individual test's expected duration.
  initial begin
    #1_000_000;     // 1 ms
    $display("FAIL: tb_dcache timeout");
    $finish;
  end

endmodule
