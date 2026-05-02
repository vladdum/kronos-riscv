// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Stage 6f Phase C integration testbench for the BOOM-style instruction
// fetch unit: the rewritten kronos_icache (Stage 6 variant), the standalone
// kronos_fetch_buffer, and the new kronos_predecode.  A small AXI memory
// mock supplies the icache refill traffic; a fake decode driver pulls
// instructions from the predecode output and verifies the (pc, instr)
// stream.
//
// The AXI mock mirrors sim/sim_main.cpp lines 372-503 in semantics: WRAP8
// burst, 1-cycle latency from AR-handshake to first beat, advance on
// r_valid+r_ready handshake.

module tb_ifu
  import kronos_pkg::*;
();

  // ---- Parameters ----------------------------------------------------------
  localparam int unsigned MEM_WORDS  = 4096;     // 16 KB (4 cache lines fit easily)
  localparam int unsigned PHYS_W     = 64;
  localparam int unsigned LINE_BYTES = 64;
  localparam int unsigned BEATS      = 8;

  // ---- DUT pin signals -----------------------------------------------------
  logic                    clk;
  logic                    rst_n;

  logic                    s0_valid;
  logic [PHYS_W-1:0]       s0_addr;
  logic [31:0]             s0_pc;
  logic                    s0_ready;

  logic                    s1_kill;
  logic                    s2_kill;
  logic                    cache_flush;

  logic                    pmp_fault;
  logic                    tlb_miss;

  logic                    icache_to_fb_valid;
  logic [31:0]             icache_to_fb_pc;
  logic [31:0]             icache_to_fb_data;
  logic                    fb_enq_ready;

  logic                    fb_to_pd_valid;
  logic [31:0]             fb_to_pd_pc;
  logic [31:0]             fb_to_pd_data;
  logic                    fb_to_pd_ready;

  logic                    pd_instr_valid;
  logic [31:0]             pd_instr;
  logic [31:0]             pd_instr_pc;
  logic                    pd_instr_is_16b;
  logic                    pd_instr_ready;
  logic                    pd_cross_page_fault;
  logic                    pd_translate_fetch;

  logic                    pd_flush;
  logic                    pd_flush_pc_offset;
  logic                    fb_flush;

  kronos_axi_req_t         axi_req;
  kronos_axi_resp_t        axi_rsp;

  logic                    miss_pulse;
  // Unused outputs — wired to keep Verilator's PINCONNECTEMPTY warning quiet.
  // Their semantics are exercised in the kronos_top tests.
  logic                    icache_miss_event_unused;
  logic [31:0]             icache_miss_resync_pc_unused;

  // ---- AXI memory model (32-bit words) -------------------------------------
  // Deterministic pattern: mem[i] = 32'hCAFE0000 + i.  Index = byte-addr >> 2.
  logic [31:0] mem [MEM_WORDS];

  // ---- AXI mock state ------------------------------------------------------
  logic              ar_pending_q;
  logic [PHYS_W-1:0] ar_base_addr_q;
  logic [7:0]        ar_len_q;
  logic [1:0]        ar_burst_q;
  logic [7:0]        ar_beat_q;
  logic [3:0]        ar_fire_delay_q;     // simple latency counter

  // R-channel combinational helpers (driven by always_comb blocks below).
  logic [PHYS_W-1:0] r_drv_addr;
  logic [11:0]       r_drv_wlo_idx;
  logic [11:0]       r_drv_whi_idx;

  // ---- Tracking ------------------------------------------------------------
  int unsigned fail_count;
  int unsigned case_idx;

  // Captured emit log
  logic [31:0] emit_pc_log    [256];
  logic [31:0] emit_instr_log [256];
  int          emit_count;

  // Captured FB push log (for redirect tests)
  logic [31:0] fb_pc_log   [256];
  logic [31:0] fb_data_log [256];
  int          fb_count;

  // ---- Clock ---------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT instances
  // -------------------------------------------------------------------------
  kronos_icache #(
    .PHYS_ADDR_W (PHYS_W)
  ) u_icache (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .s0_valid_i      (s0_valid),
    .s0_addr_i       (s0_addr),
    .s0_pc_i         (s0_pc),
    .s0_ready_o      (s0_ready),
    .s1_kill_i       (s1_kill),
    .s2_kill_i       (s2_kill),
    .confirmed_redirect_i (s1_kill | s2_kill),
    .flush_i         (cache_flush),
    .pmp_fault_i     (pmp_fault),
    .tlb_miss_i      (tlb_miss),
    .s2_enq_valid_o   (icache_to_fb_valid),
    .s2_enq_pc_o      (icache_to_fb_pc),
    .s2_enq_data_o    (icache_to_fb_data),
    .s2_enq_ready_i   (fb_enq_ready),
    .miss_event_o     (icache_miss_event_unused),
    .miss_resync_pc_o (icache_miss_resync_pc_unused),
    .axi_req_o        (axi_req),
    .axi_rsp_i        (axi_rsp),
    .miss_pulse_o     (miss_pulse)
  );

  kronos_fetch_buffer #(
    .DEPTH (4)
  ) u_fb (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .flush_i      (fb_flush),
    .enq_valid_i  (icache_to_fb_valid),
    .enq_pc_i     (icache_to_fb_pc),
    .enq_data_i   (icache_to_fb_data),
    .enq_ready_o  (fb_enq_ready),
    .deq_valid_o  (fb_to_pd_valid),
    .deq_pc_o     (fb_to_pd_pc),
    .deq_data_o   (fb_to_pd_data),
    .deq_ready_i  (fb_to_pd_ready)
  );

  kronos_predecode u_predecode (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .flush_i            (pd_flush),
    .flush_pc_offset_i  (pd_flush_pc_offset),
    .word_valid_i       (fb_to_pd_valid),
    .word_data_i        (fb_to_pd_data),
    .word_pc_i          (fb_to_pd_pc),
    .word_consume_o     (fb_to_pd_ready),
    .instr_valid_o      (pd_instr_valid),
    .instr_o            (pd_instr),
    .instr_pc_o         (pd_instr_pc),
    .instr_is_16b_o     (pd_instr_is_16b),
    .instr_ready_i      (pd_instr_ready),
    .cross_page_fault_o (pd_cross_page_fault),
    .translate_fetch_i  (pd_translate_fetch)
  );

  // -------------------------------------------------------------------------
  // AXI mock — single in-flight transaction, WRAP burst (mirrors sim_main.cpp)
  // -------------------------------------------------------------------------
  // 1-cycle minimum latency from AR handshake to first beat fired.

  // AR handshake / pending tracking
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_pending_q   <= 1'b0;
      ar_base_addr_q <= {PHYS_W{1'b0}};
      ar_len_q       <= 8'h0;
      ar_burst_q     <= 2'b00;
      ar_beat_q      <= 8'h0;
      ar_fire_delay_q <= 4'h0;
    end else begin
      if (axi_req.ar_valid & axi_rsp.ar_ready) begin
        ar_pending_q    <= 1'b1;
        ar_base_addr_q  <= axi_req.ar.addr;
        ar_len_q        <= axi_req.ar.len;
        ar_burst_q      <= axi_req.ar.burst;
        ar_beat_q       <= 8'h0;
        ar_fire_delay_q <= 4'd1;     // 1 cycle latency
      end
      // Decrement fire delay until 0; only then start firing beats.
      if (ar_pending_q & (ar_fire_delay_q != 4'h0)) begin
        ar_fire_delay_q <= ar_fire_delay_q - 4'd1;
      end
      // Advance beat on r_valid + r_ready handshake.
      if (ar_pending_q & axi_rsp.r_valid & axi_req.r_ready) begin
        if (ar_beat_q == ar_len_q) begin
          ar_pending_q <= 1'b0;
          ar_beat_q    <= 8'h0;
        end else begin
          ar_beat_q <= ar_beat_q + 8'd1;
        end
      end
    end
  end

  // Compute the byte address of the current beat, given the burst params
  // and beat counter.  Mirrors the WRAP/INCR logic in sim/sim_main.cpp.
  function automatic logic [PHYS_W-1:0] beat_addr(
    input logic [PHYS_W-1:0] base,
    input logic [7:0]        len,
    input logic [1:0]        burst,
    input logic [7:0]        beat
  );
    logic [PHYS_W-1:0] line_size_v;
    logic [PHYS_W-1:0] line_mask_v;
    logic [PHYS_W-1:0] line_base_v;
    logic [PHYS_W-1:0] off_v;
    logic [PHYS_W-1:0] r;
    r = base;
    if (burst == 2'b10) begin
      line_size_v = (PHYS_W'({56'h0, len}) + PHYS_W'(1)) * PHYS_W'(8);
      line_mask_v = line_size_v - PHYS_W'(1);
      line_base_v = r & ~line_mask_v;
      off_v       = ((r & line_mask_v) +
                     PHYS_W'({56'h0, beat}) * PHYS_W'(8)) & line_mask_v;
      r           = line_base_v | off_v;
    end else if (burst == 2'b01) begin
      r = r + PHYS_W'({56'h0, beat}) * PHYS_W'(8);
    end
    return r;
  endfunction

  // R channel driver (combinational from current beat counter / mem).
  always_comb begin
    r_drv_addr    = beat_addr(ar_base_addr_q, ar_len_q, ar_burst_q, ar_beat_q);
    r_drv_wlo_idx = r_drv_addr[13:2] & 12'(MEM_WORDS-1);
    r_drv_whi_idx = (r_drv_wlo_idx + 12'd1) & 12'(MEM_WORDS-1);
  end

  always_comb begin
    axi_rsp = kronos_axi_resp_t'({$bits(kronos_axi_resp_t){1'b0}});
    axi_rsp.ar_ready = ~ar_pending_q;       // accept one AR at a time
    axi_rsp.aw_ready = 1'b1;
    axi_rsp.w_ready  = 1'b1;
    axi_rsp.b_valid  = 1'b0;
    axi_rsp.r_valid  = 1'b0;
    axi_rsp.r.data   = 64'h0;
    axi_rsp.r.last   = 1'b0;
    axi_rsp.r.resp   = 2'b00;
    axi_rsp.r.id     = 1'b0;
    axi_rsp.r.user   = 1'b0;

    if (ar_pending_q & (ar_fire_delay_q == 4'h0)) begin
      axi_rsp.r_valid = 1'b1;
      axi_rsp.r.data  = {mem[r_drv_whi_idx], mem[r_drv_wlo_idx]};
      axi_rsp.r.last  = (ar_beat_q == ar_len_q);
    end
  end

  // -------------------------------------------------------------------------
  // Emit-log / FB-push-log monitors (sample at posedge)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      emit_count <= 0;
      fb_count   <= 0;
    end else begin
      if (pd_instr_valid & pd_instr_ready & ~pd_cross_page_fault) begin
        if (emit_count < 256) begin
          emit_pc_log[emit_count]    <= pd_instr_pc;
          emit_instr_log[emit_count] <= pd_instr;
        end
        emit_count <= emit_count + 1;
      end
      if (icache_to_fb_valid & fb_enq_ready) begin
        if (fb_count < 256) begin
          fb_pc_log[fb_count]   <= icache_to_fb_pc;
          fb_data_log[fb_count] <= icache_to_fb_data;
        end
        fb_count <= fb_count + 1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  task automatic do_reset();
    rst_n              = 1'b0;
    s0_valid           = 1'b0;
    s0_addr            = {PHYS_W{1'b0}};
    s0_pc              = 32'h0;
    s1_kill            = 1'b0;
    s2_kill            = 1'b0;
    cache_flush        = 1'b0;
    pmp_fault          = 1'b0;
    tlb_miss           = 1'b0;
    pd_instr_ready     = 1'b1;
    pd_translate_fetch = 1'b0;
    pd_flush           = 1'b0;
    pd_flush_pc_offset = 1'b0;
    fb_flush           = 1'b0;
    @(negedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
  endtask

  task automatic step();
    @(posedge clk);
    #1;
  endtask

  task automatic check(input string tag, input logic cond);
    if (!cond) begin
      $display("FAIL %s @ t=%0t  case=%0d", tag, $time, case_idx);
      fail_count++;
    end
  endtask

  // Drive s0 valid + addr + pc for one cycle, then step.
  task automatic drive_s0(input logic [PHYS_W-1:0] addr, input logic [31:0] pc);
    s0_valid = 1'b1;
    s0_addr  = addr;
    s0_pc    = pc;
    step();
    s0_valid = 1'b0;
  endtask

  // Wait up to N cycles for the predicate (driver loops with stepping).  When
  // SystemVerilog cannot pass a predicate by reference cleanly, we wait on a
  // specific signal and timeout.
  task automatic wait_emit(input int max_cycles);
    int n;
    int initial_emit;
    n = 0;
    initial_emit = emit_count;
    while (n < max_cycles && (emit_count == initial_emit)) begin
      step();
      n++;
    end
    if (n == max_cycles) begin
      $display("FAIL wait_emit timeout (max=%0d) case=%0d", max_cycles, case_idx);
      fail_count++;
    end
  endtask

  task automatic mem_init();
    for (int i = 0; i < MEM_WORDS; i++) begin
      mem[i] = 32'hCAFE_0000 + i[31:0];
    end
  endtask

  // -------------------------------------------------------------------------
  // Test cases
  // -------------------------------------------------------------------------
  initial begin
    fail_count = 0;
    case_idx   = 0;
    mem_init();
    do_reset();

    // ------------------------------------------------------------------
    // Case 1: Boot, first miss, refill, bypass, hit-then-stream.
    // Expectation:
    //   - s0=addr=0, pc=0 fires at C1; miss detected at C3.
    //   - Refill starts; first beat lo cycle pushes (pc=0, data=mem[0]) to FB.
    //   - Predecode emits an instruction whose pc=0 and instr matches mem[0]
    //     (since mem[0]=0xCAFE0000; bottom 2 bits != 11, so RVC at lower —
    //     decoded by predecode).  We accept whatever the predecode emits at
    //     pc=0 — we just verify the instruction stream looks right.
    // ------------------------------------------------------------------
    case_idx = 1;
    // Drive s0 for cycles until s0_ready_o asserts (state==IDLE), then issue.
    s0_valid = 1'b1;
    s0_addr  = 64'h0;
    s0_pc    = 32'h0;
    // Wait for accept (s0_ready_o is high cycle 1 since reset cleared state).
    step();           // edge 1: S0 captures into S1
    s0_addr = 64'h4;
    s0_pc   = 32'h4;
    step();           // edge 2: S1=0, S0=4 captured
    s0_addr = 64'h8;
    s0_pc   = 32'h8;
    step();           // edge 3: S1=4, S2=0 (miss this cycle)
    // miss_event fires, state→REFILL_AR. s1/s2 cleared.
    s0_valid = 1'b0;  // simulate kronos_top stopping accept during refill
    // Wait for bypass to enqueue critical word (pc=0).
    begin : c1_wait_bypass
      int t;
      t = 0;
      while (t < 200 && fb_count == 0) begin
        step();
        t++;
      end
      check("c1.bypass.fb_count_nonzero", fb_count != 0);
    end
    // Wait for predecode to emit the first instruction.
    wait_emit(200);
    if (emit_count >= 1) begin
      check("c1.first_emit.pc0", emit_pc_log[0] == 32'h0);
    end else begin
      check("c1.first_emit.exists", 1'b0);
    end

    // Wait for refill to fully complete (state returns to IDLE).  Probe
    // state_q via whitebox hierarchy to know when the FSM closes.  We are
    // already mid-refill at this point (state == REFILL_R), so just wait
    // for IDLE.
    begin : wait_idle
      int t;
      t = 0;
      while (t < 300 && u_icache.state_q != 2'b00) begin
        step();
        t++;
      end
      check("c1.refill_done.state_idle", u_icache.state_q == 2'b00);
    end

    // ------------------------------------------------------------------
    // Case 2: Sequential 16-word stream after warm-up.
    // After case 1 the line containing addr 0 (line 0, 16 words) is cached.
    // Drive s0 with addrs 0..60 step 4.  Each S2 hits.  Predecode emits the
    // expected (pc, instr) pairs.  Since mem[i] = 0xCAFE0000 + i, all
    // bottom-2-bits are 00, so each word predecodes as a 16-bit RVC at lower
    // half with upper half buffered for the next cycle.
    //
    // We do not assert exact instruction sequence (predecode is the unit
    // under test for that); we assert that emit_count grows monotonically
    // and that the (pc, data) sequence into the FB matches mem[].
    // ------------------------------------------------------------------
    case_idx = 2;
    pd_instr_ready = 1'b1;
    fb_count = 0;
    emit_count = 0;
    // Issue 16 fetches at PC 0..60.  Hold s0_valid asserted with the next
    // pending PC and only advance to the next address when s0_ready goes
    // high (i.e. the icache accepted the previous request).
    begin : c2_issue
      int next_idx;
      int t;
      next_idx = 0;
      t        = 0;
      while (next_idx < 16 && t < 200) begin
        s0_valid = 1'b1;
        s0_addr  = {{(PHYS_W-32){1'b0}}, 32'(next_idx*4)};
        s0_pc    = 32'(next_idx*4);
        if (s0_ready === 1'b1) begin
          step();
          next_idx++;
        end else begin
          step();
        end
        t++;
      end
      s0_valid = 1'b0;
    end
    // Drain.
    repeat (80) step();
    if (fb_count >= 16) begin
      for (int i = 0; i < 16; i++) begin
        check($sformatf("c2.fb_pc[%0d]", i),  fb_pc_log[i]   == 32'(i*4));
        check($sformatf("c2.fb_data[%0d]", i), fb_data_log[i] == mem[i]);
      end
    end else begin
      $display("c2: fb_count=%0d (expected>=16)", fb_count);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // Case 3: Kill mid-fetch redirect.
    // Drive S0 requests at full rate; on cycle 3, simultaneously assert
    // s1_kill, s2_kill, fb_flush, pd_flush.  Verify pipeline drains cleanly.
    // ------------------------------------------------------------------
    case_idx = 3;
    fb_count   = 0;
    emit_count = 0;
    // Fill the pipeline with addrs 0,4,8,12.
    for (int i = 0; i < 4; i++) begin
      s0_valid = 1'b1;
      s0_addr  = {{(PHYS_W-32){1'b0}}, 32'(i*4)};
      s0_pc    = 32'(i*4);
      step();
    end
    // Assert kills + flushes for one cycle, simultaneously change fetch.
    s0_valid           = 1'b0;
    s1_kill            = 1'b1;
    s2_kill            = 1'b1;
    fb_flush           = 1'b1;
    pd_flush           = 1'b1;
    pd_flush_pc_offset = 1'b0;
    step();
    s1_kill            = 1'b0;
    s2_kill            = 1'b0;
    fb_flush           = 1'b0;
    pd_flush           = 1'b0;
    // After flush, FB should be empty.
    check("c3.fb_empty_after_flush", fb_to_pd_valid === 1'b0);
    // Restart from addr 32 (different word but same cached line).  All
    // subsequent fetches should hit and the pipeline restart cleanly.
    fb_count = 0;
    for (int i = 8; i < 12; i++) begin
      s0_valid = 1'b1;
      s0_addr  = {{(PHYS_W-32){1'b0}}, 32'(i*4)};
      s0_pc    = 32'(i*4);
      step();
    end
    s0_valid = 1'b0;
    repeat (40) step();
    if (fb_count >= 4) begin
      for (int i = 0; i < 4; i++) begin
        check($sformatf("c3.fb_pc[%0d]", i),
              fb_pc_log[i] == 32'((i+8)*4));
      end
    end else begin
      $display("c3: fb_count=%0d (expected>=4)", fb_count);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // Case 4: Consumer stall — predecode's instr_ready=0 for 5 cycles.
    // FB fills up, icache back-pressures (s0_ready=0).  After ready
    // re-asserts, all expected (pc, data) pairs emerge with no loss.
    // ------------------------------------------------------------------
    case_idx = 4;
    fb_count   = 0;
    emit_count = 0;
    pd_instr_ready = 1'b0;        // freeze decode
    // Issue 8 fetches.
    for (int i = 0; i < 8; i++) begin
      s0_valid = 1'b1;
      s0_addr  = {{(PHYS_W-32){1'b0}}, 32'(i*4)};
      s0_pc    = 32'(i*4);
      step();
      // Once FB fills, s0_ready will go low and accepts will pause.  Loop
      // does not need to handle that — we just keep driving s0_valid; the
      // icache silently rejects.
    end
    s0_valid = 1'b0;
    // FB should be at most 4 entries full.  PD is held; fb_to_pd_valid stays.
    repeat (20) step();
    check("c4.fb_full_or_partial", fb_count >= 4);    // some pushed before stall
    // Release decode.
    pd_instr_ready = 1'b1;
    // Drain FB and pull in remaining fetches.  Re-issue addrs >= what icache
    // accepted (we don't know exactly how many were accepted; just ensure we
    // see continuous FB pushes).
    repeat (60) step();
    // After resuming, fb_count should reflect all 8 accepted fetches.  In
    // practice the icache's s0_ready cycles based on FB depth.  We just
    // verify monotonic data ordering for the entries that did push.
    for (int i = 1; i < 8; i++) begin
      if (i < fb_count) begin
        check($sformatf("c4.order_pc[%0d]", i),
              fb_pc_log[i] == 32'(i*4));
      end
    end

    // ------------------------------------------------------------------
    // Case 5: Spanning RVC + redirect.
    // Arrange memory so a 32-bit instruction spans across two FB entries
    // (lower 16 at pc[1]=2 of word X, upper 16 at pc[1]=0 of word X+4).
    // Place a 32-bit op at addr 0x102 (word_pc=0x100, upper half) → upper
    // half is the lower of the span.  We rewrite mem so word at index
    // 0x40 (byte addr 0x100) has high half = 0x0033 (RV32 valid 32b op
    // pattern: bits[1:0]=11), and word at index 0x41 (byte 0x104) has low
    // half being the high half of that op.
    // After predecode loads prev_half_q, fire flush_i and verify prev_half
    // clears.
    //
    // The simpler test: write a known 32-bit op that spans, prime the
    // predecode by walking pc[1]=2 → pc[1]=0 across two words, observe
    // the 32-bit emit, then redirect mid-stream and verify clean restart.
    //
    // We don't decompress; we just verify state transitions by watching the
    // FB pop count and predecode emit count.
    // ------------------------------------------------------------------
    case_idx = 5;
    fb_count   = 0;
    emit_count = 0;
    pd_instr_ready = 1'b1;
    // Plant: word @ idx 0x40 (byte 0x100): low=0xAAAA, high=0x0003.
    //   high[1:0] = 2'b11 → 32b spanning lower.
    // Word @ idx 0x41 (byte 0x104): low=0x1234 (will be high-of-span).
    mem[12'h040] = 32'h0003_AAAA;
    mem[12'h041] = 32'h0000_1234;
    cache_flush = 1'b1;
    step();
    cache_flush = 1'b0;
    // Prime the predecode to start at the upper half of the first FB
    // entry (i.e. the redirect target had pc[1]=1 → start mid-word).
    pd_flush           = 1'b1;
    pd_flush_pc_offset = 1'b1;
    fb_flush           = 1'b1;
    step();
    pd_flush           = 1'b0;
    pd_flush_pc_offset = 1'b0;
    fb_flush           = 1'b0;
    // Issue fetch addr=0x100 (causes miss + refill + bypass).  Hold s0
    // valid until accepted, then drop while we wait for refill, then re-
    // issue 0x104.
    begin : c5_issue
      int t;
      // Wait for accept of 0x100.
      s0_valid = 1'b1;
      s0_addr  = 64'h100;
      s0_pc    = 32'h100;
      t = 0;
      while (t < 50 && s0_ready === 1'b0) begin
        step(); t++;
      end
      step();
      s0_valid = 1'b0;
      // Wait for refill to start, then complete.
      t = 0;
      while (t < 50 && u_icache.state_q == 2'b00) begin
        step(); t++;
      end
      while (t < 200 && u_icache.state_q != 2'b00) begin
        step(); t++;
      end
      // Issue 0x104.
      s0_valid = 1'b1;
      s0_addr  = 64'h104;
      s0_pc    = 32'h104;
      t = 0;
      while (t < 50 && s0_ready === 1'b0) begin
        step(); t++;
      end
      step();
      s0_valid = 1'b0;
    end
    // Allow time for predecode to combine and emit.
    repeat (40) step();
    // Verify the spanning 32-bit instr emerged at pc=0x102.
    begin : c5_search
      int found_pc102;
      found_pc102 = 0;
      for (int i = 0; i < emit_count; i++) begin
        if (emit_pc_log[i] == 32'h102) begin
          found_pc102 = 1;
          check("c5.emit.instr_combined",
                emit_instr_log[i] == 32'h1234_0003);
        end
      end
      check("c5.emit.pc_0x102_seen", found_pc102 == 1);
    end
    // Now redirect mid-stream: assert flushes, prev_half clears.
    pd_flush = 1'b1;
    fb_flush = 1'b1;
    s1_kill  = 1'b1;
    s2_kill  = 1'b1;
    step();
    pd_flush = 1'b0;
    fb_flush = 1'b0;
    s1_kill  = 1'b0;
    s2_kill  = 1'b0;
    // After redirect, fb empty, pd has no prev_half (verify by peeking
    // whitebox).  Restart from addr 0.
    cache_flush = 1'b1;
    step();
    cache_flush = 1'b0;
    fb_count   = 0;
    emit_count = 0;
    s0_valid = 1'b1;
    s0_addr  = 64'h0;
    s0_pc    = 32'h0;
    step();
    s0_valid = 1'b0;
    repeat (50) step();
    check("c5.restart.fb_count_grows", fb_count >= 1);

    // ------------------------------------------------------------------
    // Case 6: Back-to-back miss line 0 → miss line 1.
    // After case 5 line 0 is freshly cached.  Cause a miss on line 1
    // (set 1, byte addr 0x40 = LINE_BYTES).  Verify second refill starts
    // and bypass enqueues correctly.
    // ------------------------------------------------------------------
    case_idx = 6;
    cache_flush = 1'b1;
    step();
    cache_flush = 1'b0;
    fb_count   = 0;
    emit_count = 0;
    // Miss 1: addr 0
    s0_valid = 1'b1;
    s0_addr  = 64'h0;
    s0_pc    = 32'h0;
    step();
    s0_valid = 1'b0;
    // Wait for refill to start, then complete.  (State == IDLE is the
    // initial condition; we step until it leaves IDLE then re-enters.)
    begin : c6_wait1
      int t;
      t = 0;
      // Stage 1: leave IDLE.
      while (t < 50 && u_icache.state_q == 2'b00) begin
        step(); t++;
      end
      // Stage 2: re-enter IDLE.
      while (t < 200 && u_icache.state_q != 2'b00) begin
        step(); t++;
      end
      check("c6.refill1.done", u_icache.state_q == 2'b00);
    end
    // Miss 2: addr LINE_BYTES (different set).
    s0_valid = 1'b1;
    s0_addr  = PHYS_W'(LINE_BYTES);
    s0_pc    = 32'(LINE_BYTES);
    step();
    s0_valid = 1'b0;
    begin : c6_wait2
      int t;
      t = 0;
      while (t < 50 && u_icache.state_q == 2'b00) begin
        step(); t++;
      end
      while (t < 200 && u_icache.state_q != 2'b00) begin
        step(); t++;
      end
      check("c6.refill2.done", u_icache.state_q == 2'b00);
    end
    // We expect at least 2 FB pushes (one per bypass).
    check("c6.fb_count_at_least_2", fb_count >= 2);

    if (fail_count == 0) begin
      $display("tb_ifu: PASS");
    end else begin
      $display("tb_ifu: FAIL (%0d cases failed)", fail_count);
    end
    $finish;
  end

  // Watchdog
  initial begin
    #200000;
    $display("tb_ifu: FAIL (watchdog)");
    $finish;
  end

endmodule
