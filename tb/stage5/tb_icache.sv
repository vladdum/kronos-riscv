// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Unit testbench for kronos_icache (Stage 5e).
// Drives the cache standalone with a TB-side AXI memory model.
module tb_icache;
  import kronos_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // Stimulus
  logic        req;
  logic [63:0] addr;
  logic        flush;
  logic        data_valid;
  logic [31:0] data;
  logic        stall;
  logic        miss_pulse;

  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  kronos_icache u_dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .req_i        (req),
    .addr_i       (addr),
    .flush_i      (flush),
    .data_valid_o (data_valid),
    .data_o       (data),
    .stall_o      (stall),
    .axi_req_o    (axi_req),
    .axi_rsp_i    (axi_rsp),
    .miss_pulse_o (miss_pulse)
  );

  // TB-side AXI memory model with multi-beat read support (64-bit data bus).
  // Word i contains 32'hC0DE_0000 + i so word 0 = 32'hC0DE_0000.
  // 64-bit beat = {tb_mem[idx*2+1], tb_mem[idx*2]}.
  logic [31:0] tb_mem [0:65535];     // 256 KB × 32-bit words
  logic [63:0] burst_addr_q;
  logic [3:0]  burst_beat_q;   // 4 bits for 0..7 (8 beats per refill)
  logic        burst_pending_q;

  initial begin
    for (int i = 0; i < 65536; i++) begin
      tb_mem[i] = 32'hC0DE_0000 + i;
    end
  end

  // WRAP-burst memory model (64-bit beats): beat N is at 64-bit word
  // (crit_beat_idx + N) mod 8 within the 64-byte line.
  // 64-bit word index within line = addr[5:3] (3 bits for 8 beats).
  // 32-bit word pair: lo = tb_mem[line_base + wrap_beat*2],
  //                   hi = tb_mem[line_base + wrap_beat*2 + 1].
  logic [2:0]  wrap_off64;
  logic [14:0] line_base;    // 64-byte line base in 32-bit word units
  logic [15:0] word_lo_idx;
  logic [15:0] word_hi_idx;
  assign wrap_off64  = burst_addr_q[5:3] + burst_beat_q[2:0];
  assign line_base   = burst_addr_q[17:6] * 16;  // 64 bytes / 4 = 16 words per line
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

  initial begin
    req = 0; addr = 0; flush = 0;
    #12 rst_n = 1;
    repeat (5) @(posedge clk);

    // Cold miss
    @(negedge clk); req = 1; addr = 64'h0;
    @(posedge clk) #1;
    if (!stall)      $fatal(1, "stall_o should be 1 on cold miss");
    if (!miss_pulse) $fatal(1, "miss_pulse_o should fire on cold miss");
    if (data_valid)  $fatal(1, "data_valid_o must NOT fire on miss yet");
    @(negedge clk); req = 0;

    // Wait for refill to finish (8 beats + slack)
    repeat (15) @(posedge clk);

    // Re-issue: should hit
    @(negedge clk); req = 1; addr = 64'h0;
    @(posedge clk) #1;
    if (!data_valid) $fatal(1, "expected hit on second access");
    if (stall)       $fatal(1, "expected no stall on hit");
    if (data !== 32'hC0DE_0000)
      $fatal(1, "data mismatch on hit: got %h expected C0DE_0000", data);
    @(negedge clk); req = 0;

    // CWF: a fresh cold miss should produce data_valid_o on the first r_valid
    // beat (~1 cycle later), NOT after all 16 beats.
    @(negedge clk); req = 1; addr = 64'h100;     // new line, set 4
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
    repeat (12) @(posedge clk);     // let refill finish

    // Tree-PLRU: fill two distinct lines mapping to set 0 with different tags.
    // With Tree-PLRU, addr0 goes to way 0, addr1 goes to way 2 (tree steers
    // away from recently-used way 0).  Re-accessing addr0 must be a hit.
    // With hardcoded way-0 victim, addr1 would overwrite addr0 → re-access miss.
    begin
      bit [63:0] plru_addr0;
      bit [63:0] plru_addr1;
      plru_addr0 = 64'h1_0000;   // tag 4, set 0
      plru_addr1 = 64'h2_0000;   // tag 8, set 0

      // Fill plru_addr0 — waits for CWF bypass or stall clear.
      @(negedge clk); req = 1; addr = plru_addr0;
      @(posedge clk);
      while (!data_valid) @(posedge clk);
      @(negedge clk); req = 0;
      repeat (12) @(posedge clk);     // let refill finish

      // Fill plru_addr1 — with PLRU goes to a different way than addr0.
      @(negedge clk); req = 1; addr = plru_addr1;
      @(posedge clk);
      while (!data_valid) @(posedge clk);
      @(negedge clk); req = 0;
      repeat (12) @(posedge clk);     // let refill finish

      // Re-access plru_addr0 — must be a HIT (PLRU preserved it in a different way).
      @(negedge clk); req = 1; addr = plru_addr0;
      @(posedge clk) #1;
      if (!data_valid || miss_pulse)
        $fatal(1, "PLRU: addr0 should still be cached after addr1 fill (got miss)");
      @(negedge clk); req = 0;
      repeat (5) @(posedge clk);
    end

    // FENCE.I invalidates entire cache.
    @(negedge clk); req = 1; addr = 64'h0;
    while (stall || !data_valid) @(posedge clk);
    @(negedge clk); req = 0;
    // Line at 0x0 is now cached.
    @(negedge clk); flush = 1;
    @(negedge clk); flush = 0;
    repeat (3) @(posedge clk);
    @(negedge clk); req = 1; addr = 64'h0;
    @(posedge clk) #1;
    if (!miss_pulse)
      $fatal(1, "FENCE.I should have invalidated; expected miss on re-access");
    @(negedge clk); req = 0;
    repeat (20) @(posedge clk);   // let refill finish

    $display("tb_icache PASS");
    $finish;
  end
endmodule
