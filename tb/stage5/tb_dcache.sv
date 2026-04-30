// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_dcache;
  import kronos_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        req;
  logic [63:0] addr;
  logic [2:0]  size;
  // Eviction-test address vector (promoted from `automatic` block-local; see R2).
  bit [63:0]   evict_addrs[4] = '{64'h1_0000, 64'h2_0000, 64'h3_0000, 64'h4_0000};
  logic        we;
  logic [63:0] wdata;
  logic        amo_req;
  logic [4:0]  amo_op;
  logic        rsrv_clear;
  logic        data_valid;
  logic [63:0] rdata;
  logic        sc_success;
  logic        stall;
  logic        miss_pulse;
  logic        flush;
  logic        flush_done;
  logic        dirty_pending;

  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  kronos_dcache u_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
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
    .flush_i         (flush),
    .flush_done_o    (flush_done),
    .dirty_pending_o (dirty_pending),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp),
    .miss_pulse_o    (miss_pulse)
  );

  // TB-side AXI memory model with multi-beat read support (read-only for now;
  // write-burst comes in Task 5/Phase 2).
  logic [63:0] tb_mem [0:32767];
  logic [63:0] burst_addr_q;
  logic [3:0]  burst_beat_q;
  logic        burst_pending_q;

  initial begin
    for (int i = 0; i < 32768; i++) begin
      tb_mem[i] = 64'hC0DE_0000_0000_0000 + 64'(i);
    end
  end

  logic [63:0] wb_addr_q;
  logic [3:0]  wb_beat_q;
  logic        wb_pending_q;
  logic        bvalid_pending_q;

  always_comb begin
    axi_rsp = '{default: '0};
    axi_rsp.ar_ready = ~burst_pending_q;
    axi_rsp.aw_ready = ~wb_pending_q;
    axi_rsp.w_ready  = wb_pending_q;
    axi_rsp.r_valid  = burst_pending_q;
    axi_rsp.r.data   = tb_mem[15'({burst_addr_q[14:6], 3'b000}) |
                              15'({12'b0, burst_addr_q[5:3]} + {12'b0, burst_beat_q[2:0]})];
    axi_rsp.r.last   = burst_pending_q & (burst_beat_q == 4'd7);
    axi_rsp.r.resp   = 2'b00;
    axi_rsp.b_valid  = bvalid_pending_q;
    axi_rsp.b.resp   = 2'b00;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      burst_pending_q  <= 1'b0;
      burst_beat_q     <= 4'd0;
      wb_pending_q     <= 1'b0;
      wb_beat_q        <= 4'd0;
      bvalid_pending_q <= 1'b0;
    end else begin
      // AR / R
      if (axi_req.ar_valid & axi_rsp.ar_ready) begin
        burst_pending_q <= 1'b1;
        burst_beat_q    <= 4'd0;
        burst_addr_q    <= axi_req.ar.addr;
      end else if (axi_req.r_ready & axi_rsp.r_valid) begin
        if (axi_rsp.r.last) burst_pending_q <= 1'b0;
        else                burst_beat_q    <= burst_beat_q + 4'd1;
      end
      // AW
      if (axi_req.aw_valid & axi_rsp.aw_ready) begin
        wb_pending_q <= 1'b1;
        wb_beat_q    <= 4'd0;
        wb_addr_q    <= axi_req.aw.addr;
      end
      // W
      if (axi_req.w_valid & axi_rsp.w_ready) begin
        for (int b = 0; b < 8; b++) begin
          if (axi_req.w.strb[b]) begin
            tb_mem[15'(wb_addr_q[31:3]) + 15'(wb_beat_q[2:0])][b*8 +: 8]
              <= axi_req.w.data[b*8 +: 8];
          end
        end
        wb_beat_q <= wb_beat_q + 4'd1;
        if (axi_req.w.last) begin
          wb_pending_q     <= 1'b0;
          bvalid_pending_q <= 1'b1;
        end
      end
      // B
      if (axi_req.b_ready & axi_rsp.b_valid) bvalid_pending_q <= 1'b0;
    end
  end

  initial begin
    req = 0; addr = 0; size = 3'd3; we = 0; wdata = 0;
    amo_req = 0; amo_op = 0; rsrv_clear = 0;
    flush = 0;
    #12 rst_n = 1;
    repeat (5) @(posedge clk);

    // Cold load miss
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    if (!stall)      $fatal(1, "stall_o should be 1 on cold miss");
    if (!miss_pulse) $fatal(1, "miss_pulse_o should fire on cold miss");
    @(negedge clk); req = 0;

    repeat (15) @(posedge clk);

    // Re-issue: should hit
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    if (!data_valid) $fatal(1, "expected hit on second access");
    if (rdata !== 64'hC0DE_0000_0000_0000)
      $fatal(1, "data mismatch on hit: got %h expected C0DE_0000_0000_0000", rdata);
    @(negedge clk); req = 0;

    // CWF: cold miss should produce data_valid_o on first beat (~5 cycles).
    @(negedge clk); req = 1; addr = 64'h100; size = 3'd3; we = 0;
    @(posedge clk);
    begin
      integer cycles_to_valid;
      cycles_to_valid = 0;
      while (!data_valid && cycles_to_valid < 30) begin
        @(posedge clk);
        cycles_to_valid++;
      end
      if (cycles_to_valid > 8)
        $fatal(1, "CWF should bypass within ~8 cycles, got %0d", cycles_to_valid);
    end
    @(negedge clk); req = 0;
    repeat (15) @(posedge clk);

    // Size = byte (zero-extended). tb_mem[1] = 64'hC0DE_0000_0000_0001
    // addr = 64'h8 → beat_idx = 1 within line 0 → tb_mem[1]; byte offset 0 → low byte = 0x01
    @(negedge clk); req = 1; addr = 64'h8; size = 3'd0; we = 0;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (rdata[7:0] !== 8'h01) $fatal(1, "byte load: got %h", rdata[7:0]);
    if (rdata[63:8] !== 56'b0) $fatal(1, "byte load: upper bits should be zero, got %h", rdata[63:8]);
    @(negedge clk); req = 0;

    // Store hit (line at addr 0 was loaded earlier in the TB)
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 1;
                    wdata = 64'hDEAD_BEEF_CAFE_BABE;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (!data_valid) $fatal(1, "store hit should ack via data_valid");
    @(negedge clk); req = 0;
    repeat (3) @(posedge clk);

    // Read back
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (rdata !== 64'hDEAD_BEEF_CAFE_BABE)
      $fatal(1, "store-hit readback: got %h", rdata);
    @(negedge clk); req = 0;

    // Store miss → write-allocate
    @(negedge clk); req = 1; addr = 64'h200; size = 3'd3; we = 1;
                    wdata = 64'hAAAA_BBBB_CCCC_DDDD;
    @(posedge clk) #1;
    if (!miss_pulse) $fatal(1, "store miss should fire miss_pulse");
    while (stall) @(posedge clk);
    @(negedge clk); req = 0;
    repeat (3) @(posedge clk);

    // Read back
    @(negedge clk); req = 1; addr = 64'h200; size = 3'd3; we = 0;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (rdata !== 64'hAAAA_BBBB_CCCC_DDDD)
      $fatal(1, "store-miss-allocate readback: got %h", rdata);
    @(negedge clk); req = 0;

    // Dirty eviction.  Fill 4 ways of one set with stores; 5th access evicts.
    begin
      foreach (evict_addrs[i]) begin
        @(negedge clk); req = 1; addr = evict_addrs[i]; size = 3'd3; we = 1;
                        wdata = 64'h1111_1111_1111_1111 + 64'(i);
        @(posedge clk) #1;
        while (stall) @(posedge clk);
        @(negedge clk); req = 0;
        repeat (2) @(posedge clk);
      end
      // 5th store maps to same set; the LRU way must be written back.
      @(negedge clk); req = 1; addr = 64'h5_0000; size = 3'd3; we = 1;
                      wdata = 64'hCAFE_CAFE_CAFE_CAFE;
      @(posedge clk) #1;
      while (stall) @(posedge clk);
      @(negedge clk); req = 0;
      repeat (10) @(posedge clk);
    end

    // AMOADD on cached line at addr 0.
    // After previous tests, line at addr 0 contains 0xDEAD_BEEF_CAFE_BABE
    // (from the store-hit test in Phase 2).
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
                    amo_req = 1; amo_op = 5'b00000;     // AMOADD
                    wdata = 64'd1;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    if (rdata !== 64'hDEAD_BEEF_CAFE_BABE)
      $fatal(1, "AMO old value: got %h", rdata);
    @(negedge clk); req = 0; amo_req = 0;
    repeat (3) @(posedge clk);

    // Verify new value is old + 1
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (rdata !== (64'hDEAD_BEEF_CAFE_BABE + 64'd1))
      $fatal(1, "AMO new value: got %h", rdata);
    @(negedge clk); req = 0;
    repeat (3) @(posedge clk);

    // AMOSWAP on cached line
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
                    amo_req = 1; amo_op = 5'b00001;     // AMOSWAP
                    wdata = 64'hFEED_FACE_BABE_F00D;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    @(negedge clk); req = 0; amo_req = 0;
    repeat (3) @(posedge clk);

    // Verify swapped value
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    if (rdata !== 64'hFEED_FACE_BABE_F00D)
      $fatal(1, "AMOSWAP new value: got %h", rdata);
    @(negedge clk); req = 0;

    // LR.D
    @(negedge clk); req = 1; addr = 64'h8; size = 3'd3; we = 0;
                    amo_req = 1; amo_op = 5'b00010;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    @(negedge clk); req = 0; amo_req = 0;
    repeat (3) @(posedge clk);

    // SC.D — should succeed
    @(negedge clk); req = 1; addr = 64'h8; size = 3'd3; we = 1;
                    amo_req = 1; amo_op = 5'b00011;
                    wdata = 64'h1234_5678_9ABC_DEF0;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    if (!sc_success) $fatal(1, "SC should succeed after LR with no intervening store");
    @(negedge clk); req = 0; amo_req = 0;
    repeat (3) @(posedge clk);

    // LR; intervening plain store; SC — should fail
    @(negedge clk); req = 1; addr = 64'h8; size = 3'd3; we = 0;
                    amo_req = 1; amo_op = 5'b00010;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    @(negedge clk); req = 0; amo_req = 0;

    @(negedge clk); req = 1; addr = 64'h8; size = 3'd3; we = 1;
                    wdata = 64'hAAAA_AAAA_AAAA_AAAA;
    @(posedge clk) #1;
    while (stall) @(posedge clk);
    @(negedge clk); req = 0;
    repeat (2) @(posedge clk);

    @(negedge clk); req = 1; addr = 64'h8; size = 3'd3; we = 1;
                    amo_req = 1; amo_op = 5'b00011;
                    wdata = 64'hBBBB;
    @(posedge clk) #1;
    while (stall || !data_valid) @(posedge clk);
    if (sc_success) $fatal(1, "SC should fail (reservation cleared by intervening store)");
    @(negedge clk); req = 0; amo_req = 0;

    // -----------------------------------------------------------------------
    // FENCE.I flush directed test (Stage 5g):
    //   1. Prime several cache lines with stores so they become dirty.
    //   2. Confirm dirty_pending_o == 1.
    //   3. Assert flush_i; expect AXI write bursts for each dirty line.
    //   4. After flush_done_o, expect dirty_pending_o == 0 and a load to
    //      one of the previously-dirty addresses to miss (refill via AR).
    // -----------------------------------------------------------------------
    repeat (2) @(posedge clk);

    // Prime 4 distinct cache lines (different set indices).
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); req = 1; addr = 64'(i) * 64'h40; size = 3'd3; we = 1;
                      wdata = 64'hF00D_0000_0000_0000 | 64'(i);
      @(posedge clk) #1;
      while (stall) @(posedge clk);
      @(negedge clk); req = 0; we = 0;
      repeat (1) @(posedge clk);
    end

    if (!dirty_pending) $fatal(1, "dirty_pending should be 1 after stores");

    // Assert flush_i; wait for flush_done.
    @(negedge clk); flush = 1;
    fork
      begin : wait_flush
        int t;
        t = 0;
        while (!flush_done && t < 5000) begin
          @(posedge clk);
          t = t + 1;
        end
        if (!flush_done) $fatal(1, "flush_done never asserted");
      end
    join
    @(negedge clk); flush = 0;
    repeat (2) @(posedge clk);

    if (dirty_pending) $fatal(1, "dirty_pending should be 0 after flush");

    // A load to a previously-dirty address should now miss (line invalidated).
    @(negedge clk); req = 1; addr = 64'h0; size = 3'd3; we = 0;
    @(posedge clk) #1;
    if (!stall) $fatal(1, "post-flush load should miss (stall_o=1)");
    while (stall || !data_valid) @(posedge clk);
    if (rdata !== 64'hF00D_0000_0000_0000)
      $fatal(1, "post-flush load: expected F00D_..._0, got %h", rdata);
    @(negedge clk); req = 0;

    $display("tb_dcache PASS");
    $finish;
  end
endmodule
