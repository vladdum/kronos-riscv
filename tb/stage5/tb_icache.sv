// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Unit testbench for kronos_icache (BOOM-style v3 frontend, S0/S1/S2).
// Drives the cache standalone with a TB-side AXI memory model.
// Replaces the pre-stage-6f req/data_valid/stall protocol.
module tb_icache;
  import kronos_pkg::*;

  // Clock / reset
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // DUT staged interface
  logic        s0_valid;
  logic [63:0] s0_addr;
  logic [31:0] s0_pc;
  logic        s0_ready;

  logic        s1_kill;
  logic        s2_kill;
  logic        confirmed_redirect;
  logic        flush;

  logic        s2_valid;
  logic [31:0] s2_pc;
  logic [31:0] s2_data;
  logic        s2_ready;
  logic        miss_event;
  logic [31:0] miss_resync_pc;
  logic        miss_pulse;

  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  // TB-side AXI memory and burst FSM state.  Word i contains
  // 32'hC0DE_0000 + i so word 0 = 32'hC0DE_0000.  64-bit beat =
  // {tb_mem[idx*2+1], tb_mem[idx*2]}.
  logic [31:0] tb_mem [0:65535];     // 256 KB × 32-bit words
  logic [63:0] burst_addr_q;
  logic [3:0]  burst_beat_q;         // 4 bits for 0..7 (8 beats per refill)
  logic        burst_pending_q;

  // WRAP-burst memory model (64-bit beats): beat N is at 64-bit word
  // (crit_beat_idx + N) mod 8 within the 64-byte line.  64-bit word index
  // within line = addr[5:3].  32-bit word pair: lo = tb_mem[line_base +
  // wrap_beat*2], hi = tb_mem[line_base + wrap_beat*2 + 1].
  logic [2:0]  wrap_off64;
  logic [14:0] line_base;            // 64-byte line base in 32-bit word units
  logic [15:0] word_lo_idx;
  logic [15:0] word_hi_idx;

  // Tree-PLRU stimulus addresses.
  bit [63:0] plru_addr0;
  bit [63:0] plru_addr1;

  // Loop-bounded wait counter for the CWF check.
  integer cycles_to_valid;

  kronos_icache u_dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .s0_valid_i           (s0_valid),
    .s0_addr_i            (s0_addr),
    .s0_pc_i              (s0_pc),
    .s0_ready_o           (s0_ready),
    .s1_kill_i            (s1_kill),
    .s2_kill_i            (s2_kill),
    .confirmed_redirect_i (confirmed_redirect),
    .flush_i              (flush),
    .s2_enq_valid_o       (s2_valid),
    .s2_enq_pc_o          (s2_pc),
    .s2_enq_data_o        (s2_data),
    .s2_enq_ready_i       (s2_ready),
    .miss_event_o         (miss_event),
    .miss_resync_pc_o     (miss_resync_pc),
    .axi_req_o            (axi_req),
    .axi_rsp_i            (axi_rsp),
    .miss_pulse_o         (miss_pulse)
  );

  initial begin
    for (int i = 0; i < 65536; i++) begin
      tb_mem[i] = 32'hC0DE_0000 + i;
    end
  end

  assign wrap_off64  = burst_addr_q[5:3] + burst_beat_q[2:0];
  assign line_base   = burst_addr_q[17:6] * 16;
  assign word_lo_idx = {1'b0, line_base} + {12'b0, wrap_off64, 1'b0};
  assign word_hi_idx = word_lo_idx + 16'd1;

  always_comb begin
    axi_rsp = '{default: '0};
    axi_rsp.ar_ready = ~burst_pending_q;
    axi_rsp.r_valid  = burst_pending_q;
    axi_rsp.r.data   = {tb_mem[word_hi_idx], tb_mem[word_lo_idx]};
    axi_rsp.r.last   = burst_pending_q & (burst_beat_q == 4'd7);
    axi_rsp.r.resp   = 2'b00;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      burst_pending_q <= 1'b0;
      burst_beat_q    <= 4'd0;
      burst_addr_q    <= 64'd0;
    end else begin
      if (axi_req.ar_valid & axi_rsp.ar_ready) begin
        burst_pending_q <= 1'b1;
        burst_beat_q    <= 4'd0;
        burst_addr_q    <= axi_req.ar.addr;
      end else if (axi_req.r_ready & axi_rsp.r_valid) begin
        if (axi_rsp.r.last) begin
          burst_pending_q <= 1'b0;
          burst_beat_q    <= 4'd0;
        end else begin
          burst_beat_q <= burst_beat_q + 4'd1;
        end
      end
    end
  end

  // Wait helper — drive s0_valid_i on the requested address, hold it until
  // the cache asserts s0_ready_o (req-and-ready handshake), then wait for
  // s2_enq_valid_o with a watchdog.  Returns the cycle count between the
  // accepted handshake and the s2 fire, which is what CWF / hit-latency
  // checks care about.
  task automatic issue_fetch(input logic [63:0] addr64,
                             input integer max_cycles,
                             output integer cycles_observed,
                             output logic timed_out);
    integer ready_wait;
    cycles_observed = 0;
    timed_out       = 1'b0;
    ready_wait      = 0;
    @(negedge clk);
    s0_valid = 1'b1;
    s0_addr  = addr64;
    s0_pc    = addr64[31:0];
    // Wait for the cache to accept the request (s0_ready_o high at posedge).
    while (!s0_ready && ready_wait < 30) begin
      @(posedge clk);
      ready_wait++;
    end
    if (!s0_ready) begin
      timed_out = 1'b1;
      return;
    end
    // Accepted — deassert and watch for s2 output.
    @(negedge clk);
    s0_valid = 1'b0;
    while (!s2_valid && cycles_observed < max_cycles) begin
      @(posedge clk);
      cycles_observed++;
    end
    if (!s2_valid) timed_out = 1'b1;
  endtask

  initial begin
    s0_valid           = 1'b0;
    s0_addr            = 64'd0;
    s0_pc              = 32'd0;
    s1_kill            = 1'b0;
    s2_kill            = 1'b0;
    confirmed_redirect = 1'b0;
    flush              = 1'b0;
    s2_ready           = 1'b1;        // FB always ready
    #12 rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---- 1. Cold miss + first-fill data ------------------------------------
    // Drive s0 valid for the cold address; expect a miss_pulse, then CWF
    // bypass should land s2_valid within ~8 cycles (refill window).
    begin : test_cold_miss
      integer c0;
      logic   to0;
      issue_fetch(64'h0, 30, c0, to0);
      if (to0) begin
        $fatal(1, "cold miss: s2_valid never fired (timed out)");
      end
      if (s2_data !== 32'hC0DE_0000) begin
        $fatal(1, "cold miss: data mismatch — got %h expected C0DE_0000", s2_data);
      end
      if (s2_pc !== 32'h0) begin
        $fatal(1, "cold miss: pc mismatch — got %h expected 0", s2_pc);
      end
      // Allow the rest of the refill to drain.
      repeat (12) @(posedge clk);
    end

    // ---- 2. Hit-after-refill -----------------------------------------------
    // Re-issue the same line; should hit through the S0→S1→S2 pipeline in a
    // small handful of cycles.  Tighter bound than a miss.
    begin : test_hit_after_refill
      integer c1;
      logic   to1;
      issue_fetch(64'h0, 8, c1, to1);
      if (to1) $fatal(1, "expected hit on second access (timed out)");
      if (s2_data !== 32'hC0DE_0000) begin
        $fatal(1, "hit: data mismatch — got %h expected C0DE_0000", s2_data);
      end
      repeat (3) @(posedge clk);
    end

    // ---- 3. CWF bypass on a fresh line -------------------------------------
    // A new line (different set) should expose CWF: s2_valid fires on the
    // critical-word beat, well before the burst's 8th beat.  Bound at ~10
    // cycles to give the AR handshake one cycle of slack on top of CWF.
    begin : test_cwf_bypass
      integer c2;
      logic   to2;
      issue_fetch(64'h100, 12, c2, to2);
      if (to2) $fatal(1, "CWF: s2_valid never fired within the bypass window");
      if (c2 > 10) begin
        $fatal(1, "CWF should bypass within ~10 cycles, got %0d", c2);
      end
      repeat (12) @(posedge clk);     // let refill drain
    end

    // ---- 4. Tree-PLRU way-victim preservation ------------------------------
    // Two distinct tags mapping to set 0 must land in different ways under
    // Tree-PLRU.  Re-accessing the first must still hit; with a hardcoded
    // way-0 victim, addr1 would have evicted addr0.
    begin : test_plru
      integer c3, c4, c5;
      logic   to3, to4, to5;
      plru_addr0 = 64'h1_0000;        // tag 4, set 0
      plru_addr1 = 64'h2_0000;        // tag 8, set 0

      issue_fetch(plru_addr0, 30, c3, to3);
      if (to3) $fatal(1, "PLRU fill addr0: timed out");
      repeat (12) @(posedge clk);

      issue_fetch(plru_addr1, 30, c4, to4);
      if (to4) $fatal(1, "PLRU fill addr1: timed out");
      repeat (12) @(posedge clk);

      issue_fetch(plru_addr0, 8, c5, to5);
      if (to5) begin
        $fatal(1, "PLRU: addr0 should still be cached after addr1 fill (timed out)");
      end
    end

    // ---- 5. FENCE.I invalidates the entire cache ---------------------------
    // After a hit on 0x0, pulse flush_i.  The next access to 0x0 must miss
    // again — observed via miss_pulse_o firing on the cold path.
    begin : test_fence_i
      integer c6;
      logic   to6;
      issue_fetch(64'h0, 8, c6, to6);
      if (to6) $fatal(1, "pre-fence hit on 0x0: timed out");
      repeat (3) @(posedge clk);

      @(negedge clk); flush = 1'b1;
      @(negedge clk); flush = 1'b0;
      repeat (3) @(posedge clk);

      // Drive a fresh access; assert miss_pulse_o fires (cold-path indicator).
      // miss_pulse is a one-cycle pulse, so capture it via a watcher.
      begin : test_fence_i_watcher
        bit saw_miss;
        saw_miss = 1'b0;
        fork
          begin : driver
            integer c7;
            logic   to7;
            issue_fetch(64'h0, 30, c7, to7);
            if (to7) $fatal(1, "post-fence access timed out");
          end
          begin : watcher
            repeat (15) begin
              @(posedge clk);
              if (miss_pulse) saw_miss = 1'b1;
            end
          end
        join
        if (!saw_miss) begin
          $fatal(1, "FENCE.I should have invalidated; expected miss_pulse on re-access");
        end
      end
      repeat (15) @(posedge clk);
    end

    $display("tb_icache PASS");
    $finish;
  end
endmodule
