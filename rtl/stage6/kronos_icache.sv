// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_icache.sv — instruction cache, Stage 6f v3 BOOM-style rewrite.
//
// 16 KB, 4-way set-associative, 64-byte lines, Tree-PLRU replacement,
// critical-word-first refill via AXI WRAP8 burst (8 x 64-bit beats).
// Data arrays are now 4 x kronos_ram (one per way); tag/valid/PLRU stay in
// FFs.  The pipeline is structurally split into S0/S1/S2 stages with their
// own valid registers and combinational kill inputs (s1_kill_i, s2_kill_i)
// from the upstream redirect detection in kronos_top.  Each S2 hit pushes a
// (pc, data) tuple into an external kronos_fetch_buffer; back-pressure is
// via valid/ready handshake (s0_ready_o out, s2_enq_ready_i in).
//
// Miss handling:
//   - S2 detects the miss, latches (set, tag, word_idx, pc) and transitions
//     to REFILL_AR.  s1_valid_q and s2_valid_q both clear so that wrong-path
//     entries do not advance into the FB during the refill window.
//   - The refill bypass enqueues (miss_pc, critical_word) into the FB on the
//     first beat lo cycle.
//   - Once the line is cached, subsequent re-fetches hit normally via
//     S0/S1/S2.  kronos_top is responsible for re-issuing s0 with the right
//     PC after the refill (s0_pc_q stops advancing while s0_ready_o is low).
//
// See docs/superpowers/specs/2026-05-02-stage6f-icache-boom-frontend-v3-design.md
// section 5 for the full design.
module kronos_icache
  import kronos_pkg::*;
#(
  parameter int unsigned CACHE_BYTES = 16*1024,
  parameter int unsigned NUM_WAYS    = 4,
  parameter int unsigned LINE_BYTES  = 64,
  parameter int unsigned PHYS_ADDR_W = 64
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // S0 input (kronos_top drives)
  input  logic                   s0_valid_i,
  input  logic [PHYS_ADDR_W-1:0] s0_addr_i,
  input  logic [31:0]            s0_pc_i,
  output logic                   s0_ready_o,

  // Combinational kill inputs from upstream redirect detection
  input  logic                   s1_kill_i,
  input  logic                   s2_kill_i,
  // Asserted only on confirmed (EX/MEM) redirects — drives the bypass-squash
  // latch.  Speculative predicted-taken redirects must NOT enter this signal,
  // otherwise a transient BTB false-hit on a sequential PC during a refill
  // window would suppress the legitimate critical-word bypass and the line's
  // first word would be lost from the FB.
  input  logic                   confirmed_redirect_i,

  // FENCE.I — invalidates valid_q
  input  logic                   flush_i,

  // PMP / TLB suppression (stage 6 only)
  input  logic                   pmp_fault_i,
  input  logic                   tlb_miss_i,

  // S2 output to FetchBuffer
  output logic                   s2_enq_valid_o,
  output logic [31:0]            s2_enq_pc_o,
  output logic [31:0]            s2_enq_data_o,
  input  logic                   s2_enq_ready_i,

  // Miss-event resync hook for kronos_top.  When the icache detects a real S2
  // miss it kills any in-flight S1/S2 entries so wrong-path words don't reach
  // the FB.  But s0_pc_q (in kronos_top) has typically already advanced past
  // the missed line by 1–2 words, so after refill the IFU would skip those
  // words.  miss_event_o pulses combinationally on the miss-detect cycle and
  // miss_resync_pc_o presents the PC to resume from (= the missed S2 PC + 4,
  // since the bypass owns delivery of the missed word itself).
  output logic                   miss_event_o,
  output logic [31:0]            miss_resync_pc_o,

  // AXI4 read master
  output kronos_axi_req_t        axi_req_o,
  input  kronos_axi_resp_t       axi_rsp_i,

  // Performance counter pulse
  output logic                   miss_pulse_o
);

  // ---- Derived parameters ---------------------------------------------------
  localparam int unsigned NUM_SETS    = CACHE_BYTES / (NUM_WAYS * LINE_BYTES);
  localparam int unsigned SET_IDX_W   = $clog2(NUM_SETS);
  localparam int unsigned OFFSET_W    = $clog2(LINE_BYTES);
  localparam int unsigned WORD_IDX_W  = OFFSET_W - $clog2(kronos_pkg::INST_W/8);
  localparam int unsigned TAG_W       = PHYS_ADDR_W - SET_IDX_W - OFFSET_W;
  localparam int unsigned WORDS       = LINE_BYTES / (kronos_pkg::INST_W/8); // 16
  localparam int unsigned BEATS       = LINE_BYTES / kronos_pkg::XLEN_BYTES;  // 8
  localparam int unsigned BEAT_CNT_W  = $clog2(BEATS);
  localparam int unsigned RAM_DEPTH   = NUM_SETS * WORDS;
  localparam int unsigned RAM_ADDR_W  = $clog2(RAM_DEPTH);

  // ---- Types ----------------------------------------------------------------
  typedef enum logic [1:0] {
    ICACHE_IDLE       = 2'b00,
    ICACHE_REFILL_AR  = 2'b01,
    ICACHE_REFILL_R   = 2'b10
  } icache_state_e;

  // ---- Tag / valid / PLRU arrays -------------------------------------------
  // Tag arrays are wrapped in per-way kronos_ram instances (see gen_tag_ram
  // below).  valid_q stays in flops to preserve the single-cycle FENCE.I
  // flash-clear; PLRU stays in flops because it is rewritten every hit.
  logic                          valid_q [NUM_SETS][NUM_WAYS];
  logic [2:0]                    plru_q  [NUM_SETS];

  // ---- Pipeline registers --------------------------------------------------
  logic                          s1_valid_q;
  logic [PHYS_ADDR_W-1:0]        s1_addr_q;
  logic [31:0]                   s1_pc_q;

  logic                          s2_valid_q;
  logic                          s2_hit_q;
  logic [PHYS_ADDR_W-1:0]        s2_addr_q;
  logic [31:0]                   s2_pc_q;
  logic [kronos_pkg::INST_W-1:0] s2_data_q;

  // ---- Refill FSM and bookkeeping ------------------------------------------
  icache_state_e                 state_q;
  logic                          miss_pulse_q;
  logic [SET_IDX_W-1:0]          miss_set_q;
  logic [TAG_W-1:0]              miss_tag_q;
  logic [WORD_IDX_W-1:0]         miss_word_q;
  logic [31:0]                   miss_pc_q;
  logic                          miss_addr2_q;
  logic [$clog2(NUM_WAYS)-1:0]   victim_q;
  logic [BEAT_CNT_W-1:0]         beat_cnt_q;
  logic                          refill_phase_q;
  logic [kronos_pkg::INST_W-1:0] refill_high_data_q;
  // Set when a redirect (s1_kill_i / s2_kill_i pulse) lands during a refill.
  // The line still completes — AXI cannot abort — but the critical-word bypass
  // is suppressed because the consumer has already been redirected away from
  // miss_pc.  Without this, the bypass would push a wrong-path (miss_pc, data)
  // tuple into the FB after the redirect's flush, corrupting the instruction
  // stream once the consumer re-engages.
  logic                          refill_squashed_q;
  // Tracks an outstanding AXI read burst.  Set on AR handshake, cleared on the
  // last R-beat handshake.  Gates ar_valid so a flush-induced state reset
  // mid-burst (FENCE.I or similar) cannot issue a second AR before the first
  // burst's R-beats have drained — that would trip the AXI single-outstanding
  // contract on the instruction port.  r_ready stays high while the burst is
  // outstanding so the beats drain even after state has returned to IDLE.
  logic                          axi_outstanding_q;

  // ---- Combinational signals -----------------------------------------------
  // S0 address breakdown (drives BRAM raddr).
  logic [SET_IDX_W-1:0]          s0_set_idx;
  logic [WORD_IDX_W-1:0]         s0_word_idx;
  logic [RAM_ADDR_W-1:0]         s0_ram_raddr;

  // S1 address breakdown (drives tag compare).
  logic [SET_IDX_W-1:0]          s1_set_idx;
  logic [TAG_W-1:0]              s1_tag;
  logic [WORD_IDX_W-1:0]         s1_word_idx;
  logic [NUM_WAYS-1:0]           hit_way_oh_s1;
  logic                          hit_s1;
  logic [kronos_pkg::INST_W-1:0] hit_word_s1;

  // S2 address breakdown for miss handling.
  logic [SET_IDX_W-1:0]          s2_set_idx;
  logic [TAG_W-1:0]              s2_tag;
  logic [WORD_IDX_W-1:0]         s2_word_idx;
  logic [NUM_WAYS-1:0]           hit_way_oh_s2;
  logic [$clog2(NUM_WAYS)-1:0]   hit_way_s2;

  // Pipeline back-pressure
  logic                          s2_held_hit;       // hit waiting on FB
  logic                          s2_stall;          // FB full while S2 holds
  logic                          s1_advance;        // S1 -> S2 fires
  logic                          s0_accept;         // S0 -> S1 fires
  logic                          miss_event;        // S2 sees a real miss
  logic [$clog2(NUM_WAYS)-1:0]   victim_pick;

  // Refill helpers
  logic [WORD_IDX_W-1:0]         beat_base_word;
  logic [BEAT_CNT_W-1:0]         beat_idx;
  logic [kronos_pkg::INST_W-1:0] refill_lo_word;
  logic [kronos_pkg::INST_W-1:0] refill_hi_word;
  logic                          refill_lo_handshake;
  logic                          refill_hi_handshake;
  logic                          refill_last_done;

  // Refill bypass into FB
  logic                          bypass_pulse;
  logic [kronos_pkg::INST_W-1:0] bypass_data;
  // 1-deep holding register for the bypass critical-word.  When bypass_pulse
  // fires and the FB is full (s2_enq_ready_i=0), the (pc,data) tuple is
  // latched here and re-presented to the FB on every subsequent cycle until
  // it accepts.  Without this, the bypass push would be silently dropped:
  // during a downstream stall (e.g. multi-cycle FPU op) the FB fills to DEPTH
  // while s0 is still fetching ahead, the next line miss bypasses into a
  // full FB, and the line's first word is lost — predecode then skips that
  // word and emits the next sequential PC, scrambling the instruction stream.
  logic                          bypass_pending_q;
  logic [31:0]                   bypass_pending_pc_q;
  logic [kronos_pkg::INST_W-1:0] bypass_pending_data_q;
  logic                          bypass_drive;
  logic [31:0]                   bypass_drive_pc;
  logic [kronos_pkg::INST_W-1:0] bypass_drive_data;

  // BRAM port signals (per way)
  logic                          ram_re;
  logic [NUM_WAYS-1:0]           ram_we;
  logic [RAM_ADDR_W-1:0]         ram_waddr;
  logic [kronos_pkg::INST_W-1:0] ram_wdata;
  logic [kronos_pkg::INST_W-1:0] ram_rdata [NUM_WAYS];

  // ---- Per-way TAG-RAM interface signals (driven combinationally) ----------
  // TAG_W = 52, padded to a multiple of BYTE_WIDTH (8) so xpm_memory_sdpram
  // accepts the byte-write geometry.  The 4 unused MSBs are tied to zero on
  // write and stripped on read.
  localparam int unsigned TAG_RAM_W = ((TAG_W + 7) / 8) * 8;   // 56

  logic [NUM_WAYS-1:0]           tag_we;
  logic [SET_IDX_W-1:0]          tag_waddr;
  logic [TAG_RAM_W-1:0]          tag_wdata;
  logic                          tag_re;
  logic [SET_IDX_W-1:0]          tag_raddr;
  logic [TAG_RAM_W-1:0]          tag_rdata        [NUM_WAYS];
  logic [TAG_W-1:0]              tag_rdata_eff_s1 [NUM_WAYS];   // S1, post-bypass
  logic [TAG_W-1:0]              s2_tag_data_q    [NUM_WAYS];   // S2 holdover

  // 1-deep RAW bypass for refill→read collision (BRAM port-B is "no_change",
  // so a load reading the just-written tag would otherwise see stale data).
  logic                          prev_tag_write_q;
  logic [SET_IDX_W-1:0]          prev_tag_set_q;
  logic [NUM_WAYS-1:0]           prev_tag_way_oh_q;
  logic [TAG_W-1:0]              prev_tag_data_q;

  // One-cycle pulse: refill commit cycle (replaces the in-FSM tag_q write).
  logic                          refill_tag_write_fire;

  // Lint suppression
  logic                          _unused;

  // ---- Functions (declared up-front so always_ff bodies stay decl-free) ----
  function automatic logic [2:0] plru_update(
    input logic [2:0] cur,
    input logic [$clog2(NUM_WAYS)-1:0] way
  );
    logic [2:0] nxt;
    nxt = cur;
    case (way)
      2'd0: begin nxt[2] = 1'b1; nxt[1] = 1'b1; end
      2'd1: begin nxt[2] = 1'b1; nxt[1] = 1'b0; end
      2'd2: begin nxt[2] = 1'b0; nxt[0] = 1'b1; end
      2'd3: begin nxt[2] = 1'b0; nxt[0] = 1'b0; end
      default: ;
    endcase
    return nxt;
  endfunction

  // ---- Address slicing ------------------------------------------------------
  assign s0_set_idx   = s0_addr_i[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign s0_word_idx  = s0_addr_i[OFFSET_W-1 : $clog2(kronos_pkg::INST_W/8)];
  assign s0_ram_raddr = {s0_set_idx, s0_word_idx};

  assign s1_set_idx   = s1_addr_q[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign s1_tag       = s1_addr_q[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign s1_word_idx  = s1_addr_q[OFFSET_W-1 : $clog2(kronos_pkg::INST_W/8)];

  assign s2_set_idx   = s2_addr_q[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign s2_tag       = s2_addr_q[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign s2_word_idx  = s2_addr_q[OFFSET_W-1 : $clog2(kronos_pkg::INST_W/8)];

  // ---- S1 hit logic ---------------------------------------------------------
  always_comb begin
    hit_way_oh_s1 = {NUM_WAYS{1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh_s1[w] = s1_valid_q & valid_q[s1_set_idx][w] &
                         (tag_rdata_eff_s1[w] == s1_tag);
    end
    hit_s1 = |hit_way_oh_s1;
  end

  // S1 way-select mux on freshly registered BRAM read data.
  always_comb begin
    hit_word_s1 = {kronos_pkg::INST_W{1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh_s1[w]) hit_word_s1 = ram_rdata[w];
    end
  end

  // ---- S2 hit-way recompute (used for PLRU MRU update) ---------------------
  always_comb begin
    hit_way_oh_s2 = {NUM_WAYS{1'b0}};
    hit_way_s2    = {$clog2(NUM_WAYS){1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh_s2[w] = s2_valid_q & valid_q[s2_set_idx][w] &
                         (s2_tag_data_q[w] == s2_tag);
    end
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh_s2[w]) hit_way_s2 = w[$clog2(NUM_WAYS)-1:0];
    end
  end

  // ---- Tree-PLRU victim pick -----------------------------------------------
  always_comb begin
    victim_pick = {$clog2(NUM_WAYS){1'b0}};
    unique case (plru_q[s2_set_idx][2])
      1'b0: victim_pick = plru_q[s2_set_idx][1] ? 2'd1 : 2'd0;
      1'b1: victim_pick = plru_q[s2_set_idx][0] ? 2'd3 : 2'd2;
      default: victim_pick = {$clog2(NUM_WAYS){1'b0}};
    endcase
  end

  // ---- Pipeline back-pressure ----------------------------------------------
  // S2 holds a hit that has not yet been drained into the FB.
  assign s2_held_hit = s2_valid_q & s2_hit_q & ~s2_kill_i;
  // bypass_drive overrides the s2_enq_pc_o / s2_enq_data_o mux when active,
  // so a same-cycle s2-hit-push would silently lose its tuple — the FB only
  // accepts one entry per cycle and the bypass wins the priority mux. Stall
  // s2 while the bypass is taking the FB slot so the held hit pushes next
  // cycle (after bypass_pending_q clears).
  assign s2_stall    = s2_held_hit & (~s2_enq_ready_i | bypass_drive);

  // S1 may advance to S2 only when S2 has slack and we're idle (not in
  // refill).  During refill the BRAM is being written, no read happens.
  assign s1_advance = s1_valid_q & ~s2_stall & (state_q == ICACHE_IDLE);

  // S0 ready: idle, no S2 stall.
  assign s0_ready_o = (state_q == ICACHE_IDLE) & ~s2_stall;
  assign s0_accept  = s0_valid_i & s0_ready_o;

  // ---- Refill helpers -------------------------------------------------------
  always_comb begin
    beat_idx       = miss_word_q[WORD_IDX_W-1:1] + beat_cnt_q[BEAT_CNT_W-1:0];
    beat_base_word = {beat_idx, 1'b0};
  end

  assign refill_lo_word = axi_rsp_i.r.data[kronos_pkg::INST_W-1:0];
  assign refill_hi_word = axi_rsp_i.r.data[kronos_pkg::XLEN-1:kronos_pkg::INST_W];

  // Hi-handshake test refill_phase_q FIRST so the high write fires even when
  // AXI dropped r_valid after the lo handshake.
  assign refill_lo_handshake = (state_q == ICACHE_REFILL_R) &
                               axi_rsp_i.r_valid & axi_req_o.r_ready &
                               ~refill_phase_q;
  assign refill_hi_handshake = (state_q == ICACHE_REFILL_R) & refill_phase_q;
  assign refill_last_done    = refill_hi_handshake &
                               (beat_cnt_q == BEAT_CNT_W'(BEATS-1));

  // RAM write address: lo cycle → beat_base_word; hi cycle → beat_base_word+1.
  always_comb begin
    if (refill_phase_q) begin
      ram_waddr = {miss_set_q, beat_base_word + WORD_IDX_W'(1)};
      ram_wdata = refill_high_data_q;
    end else begin
      ram_waddr = {miss_set_q, beat_base_word};
      ram_wdata = refill_lo_word;
    end
  end

  // Per-way write enables — only the victim way of this miss is written.
  always_comb begin
    ram_we = {NUM_WAYS{1'b0}};
    if (refill_lo_handshake | refill_hi_handshake) begin
      ram_we[victim_q] = 1'b1;
    end
  end

  // BRAM read enable: every accepted S0 (no read while refilling).
  assign ram_re = s0_accept;

  // ---- Miss / bypass --------------------------------------------------------
  // miss_event: S2 sees a real miss (not killed by upstream).  pmp/tlb faults
  // suppress the miss so we don't issue memory traffic for non-cacheable or
  // un-translated requests.
  assign miss_event = s2_valid_q & ~s2_hit_q & ~s2_kill_i &
                      (state_q == ICACHE_IDLE) & ~pmp_fault_i & ~tlb_miss_i;

  // Bypass pulse: first beat lo cycle delivers the critical word straight to
  // the FB enq port so consumers don't wait for the whole line.  Suppressed
  // when the refill was squashed by a mid-flight redirect — the (miss_pc,
  // data) tuple is no longer on the consumer's path.
  assign bypass_pulse = refill_lo_handshake & (beat_cnt_q == {BEAT_CNT_W{1'b0}}) &
                        ~refill_squashed_q;
  assign bypass_data  = miss_addr2_q ? refill_hi_word : refill_lo_word;

  // ---- Pipeline registers (S1, S2) -----------------------------------------
  // S1 update.  Killed by miss_event (BOOM-style: a miss in S2 kills the
  // younger entry in S1; kronos_top knows to re-fetch from s0_pc_q after
  // refill).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_addr_q  <= {PHYS_ADDR_W{1'b0}};
      s1_pc_q    <= 32'h0;
    end else if (flush_i) begin
      s1_valid_q <= 1'b0;
    end else if (miss_event) begin
      s1_valid_q <= 1'b0;
    end else if (s2_stall) begin
      // FB-full back-pressure: hold S1 (still subject to kill).
      s1_valid_q <= s1_valid_q & ~s1_kill_i;
    end else begin
      s1_valid_q <= s0_accept & ~s1_kill_i;
      if (s0_accept) begin
        s1_addr_q <= s0_addr_i;
        s1_pc_q   <= s0_pc_i;
      end
    end
  end

  // S2 update.  miss_event clears s2_valid_q so that the bypass owns the
  // delivery of the missed word.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid_q <= 1'b0;
      s2_hit_q   <= 1'b0;
      s2_addr_q  <= {PHYS_ADDR_W{1'b0}};
      s2_pc_q    <= 32'h0;
      s2_data_q  <= {kronos_pkg::INST_W{1'b0}};
    end else if (flush_i) begin
      s2_valid_q <= 1'b0;
    end else if (miss_event) begin
      s2_valid_q <= 1'b0;
    end else if (s2_stall) begin
      // Hold S2 entry while FB full.
      s2_valid_q <= s2_valid_q & ~s2_kill_i;
    end else begin
      s2_valid_q <= s1_valid_q & ~s2_kill_i & (state_q == ICACHE_IDLE);
      if (s1_advance) begin
        s2_hit_q  <= hit_s1;
        s2_addr_q <= s1_addr_q;
        s2_pc_q   <= s1_pc_q;
        s2_data_q <= hit_word_s1;
      end
    end
  end

  // ---- Refill FSM and array updates ----------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= ICACHE_IDLE;
      miss_pulse_q       <= 1'b0;
      miss_set_q         <= {SET_IDX_W{1'b0}};
      miss_tag_q         <= {TAG_W{1'b0}};
      miss_word_q        <= {WORD_IDX_W{1'b0}};
      miss_pc_q          <= 32'h0;
      miss_addr2_q       <= 1'b0;
      victim_q           <= {$clog2(NUM_WAYS){1'b0}};
      beat_cnt_q         <= {BEAT_CNT_W{1'b0}};
      refill_phase_q     <= 1'b0;
      refill_high_data_q <= {kronos_pkg::INST_W{1'b0}};
      refill_squashed_q  <= 1'b0;
      for (int s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= 3'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          valid_q[s][w] <= 1'b0;
        end
      end
    end else begin
      miss_pulse_q <= miss_event;

      // Latch a squash if a CONFIRMED redirect cascades while the refill is
      // in flight.  Speculative pred_taken kills do NOT count — those can fire
      // spuriously from BTB false-hits on sequential PCs and would otherwise
      // suppress legitimate critical-word bypass pushes.  When EX/MEM later
      // resolves the speculation as a no-op, the line is still useful on the
      // restored sequential path.
      if ((state_q != ICACHE_IDLE) & confirmed_redirect_i) begin
        refill_squashed_q <= 1'b1;
      end

      unique case (state_q)
        ICACHE_IDLE: begin
          // PLRU MRU update on hit reaching S2 (drains this cycle).
          if (s2_valid_q & s2_hit_q & ~s2_kill_i & ~s2_stall) begin
            plru_q[s2_set_idx] <= plru_update(plru_q[s2_set_idx], hit_way_s2);
          end
          if (miss_event) begin
            miss_set_q     <= s2_set_idx;
            miss_tag_q     <= s2_tag;
            miss_word_q    <= s2_word_idx;
            miss_pc_q      <= s2_pc_q;
            miss_addr2_q   <= s2_word_idx[0];
            victim_q       <= victim_pick;
            beat_cnt_q     <= {BEAT_CNT_W{1'b0}};
            refill_phase_q <= 1'b0;
            refill_squashed_q <= 1'b0;
            state_q        <= ICACHE_REFILL_AR;
          end
        end
        ICACHE_REFILL_AR: begin
          if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) begin
            state_q <= ICACHE_REFILL_R;
          end
        end
        ICACHE_REFILL_R: begin
          if (refill_lo_handshake) begin
            // lo half written this cycle (RAM port driven by always_comb).
            refill_high_data_q <= refill_hi_word;
            refill_phase_q     <= 1'b1;
          end else if (refill_hi_handshake) begin
            // hi half written; advance beat / finish line.
            refill_phase_q <= 1'b0;
            beat_cnt_q     <= beat_cnt_q + BEAT_CNT_W'(1);
            if (refill_last_done) begin
              // Tag write is handled by refill_tag_write_fire → tag RAM port.
              valid_q[miss_set_q][victim_q] <= 1'b1;
              plru_q[miss_set_q]            <= plru_update(plru_q[miss_set_q], victim_q);
              refill_squashed_q             <= 1'b0;
              state_q <= ICACHE_IDLE;
            end
          end
        end
        default: state_q <= ICACHE_IDLE;
      endcase

      // FENCE.I: drop all valid bits and reset refill bookkeeping.
      if (flush_i) begin
        for (int s = 0; s < NUM_SETS; s++) begin
          for (int w = 0; w < NUM_WAYS; w++) begin
            valid_q[s][w] <= 1'b0;
          end
        end
        state_q        <= ICACHE_IDLE;
        refill_phase_q <= 1'b0;
        beat_cnt_q     <= {BEAT_CNT_W{1'b0}};
      end
    end
  end

  // ---- AXI request driver --------------------------------------------------
  always_comb begin
    axi_req_o = kronos_axi_req_t'({$bits(kronos_axi_req_t){1'b0}});
    axi_req_o.ar.addr  = {miss_tag_q[TAG_W-1:0],
                          miss_set_q, miss_word_q[WORD_IDX_W-1:1], 3'b000};
    axi_req_o.ar.size  = 3'b011;       // 8 bytes per beat
    axi_req_o.ar.len   = 8'd7;
    axi_req_o.ar.burst = axi_pkg::BURST_WRAP;
    axi_req_o.ar.id    = {$bits(axi_req_o.ar.id){1'b0}};
    // Block AR while a previous burst is still outstanding (e.g. FENCE.I
    // forced the FSM back to IDLE before the prior R beats drained).
    axi_req_o.ar_valid = (state_q == ICACHE_REFILL_AR) & ~pmp_fault_i &
                         ~tlb_miss_i & ~axi_outstanding_q;
    // Drain R beats whenever a burst is outstanding, even after a flush has
    // forced the FSM out of REFILL_R.  refill_phase_q only matters during the
    // active write phase; outside REFILL_R the BRAM write enables are off
    // anyway, so accepting the beats simply discards them.
    axi_req_o.r_ready  = axi_outstanding_q &
                         ~((state_q == ICACHE_REFILL_R) & refill_phase_q);
  end

  // ---- Outstanding AXI burst tracker --------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      axi_outstanding_q <= 1'b0;
    end else if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) begin
      axi_outstanding_q <= 1'b1;
    end else if (axi_outstanding_q & axi_rsp_i.r_valid & axi_req_o.r_ready &
                 axi_rsp_i.r.last) begin
      axi_outstanding_q <= 1'b0;
    end
  end

  // ---- BRAM instantiation (one per way) ------------------------------------
  generate
    for (genvar gi = 0; gi < NUM_WAYS; gi++) begin : gen_data_ram
      kronos_ram #(
        .DEPTH      (RAM_DEPTH),
        .WIDTH      (kronos_pkg::INST_W),
        .BYTE_WIDTH (8)
      ) u_ram (
        .clk_i   (clk_i),
        .we_i    (ram_we[gi]),
        .waddr_i (ram_waddr),
        .wdata_i (ram_wdata),
        .wmask_i ({(kronos_pkg::INST_W/8){1'b1}}),
        .re_i    (ram_re),
        .raddr_i (s0_ram_raddr),
        .rdata_o (ram_rdata[gi])
      );
    end
  endgenerate

  // ==========================================================================
  // Tag RAM — one kronos_ram per way (port-A write, port-B read).
  // Per-way DEPTH=NUM_SETS, WIDTH=TAG_RAM_W (TAG_W zero-padded to 8b multiple).
  // WRITE_MODE_B="no_change" matches the data RAM; refill→read same-set
  // collision handled by the 1-deep prev_tag_*_q bypass.
  // ==========================================================================
  generate
    for (genvar gi = 0; gi < NUM_WAYS; gi++) begin : gen_tag_ram
      kronos_ram #(
        .DEPTH        (NUM_SETS),
        .WIDTH        (TAG_RAM_W),
        .BYTE_WIDTH   (8),
        .WRITE_MODE_B ("no_change")
      ) u_tag_ram (
        .clk_i   (clk_i),
        .we_i    (tag_we[gi]),
        .waddr_i (tag_waddr),
        .wdata_i (tag_wdata),
        .wmask_i ({(TAG_RAM_W/8){1'b1}}),
        .re_i    (tag_re),
        .raddr_i (tag_raddr),
        .rdata_o (tag_rdata[gi])
      );
    end
  endgenerate

  // ---- Tag RAM read mux ----------------------------------------------------
  // Tag read launches at S0 alongside the data-RAM read; output lands at S1
  // for the hit comparator.  Holds across S1 stalls because s0_ready_o gates
  // s0_accept (no new launch ⇒ BRAM port-B holds the previous output).
  always_comb begin
    tag_re    = s0_accept;
    tag_raddr = s0_set_idx;
  end

  // ---- Tag RAM write side --------------------------------------------------
  // Write fires for exactly one cycle on the refill-complete edge — same
  // predicate that previously drove `tag_q[miss_set_q][victim_q] <= miss_tag_q`
  // inside the FSM.
  assign refill_tag_write_fire = (state_q == ICACHE_REFILL_R) & refill_last_done;

  always_comb begin
    tag_we    = {NUM_WAYS{1'b0}};
    tag_waddr = miss_set_q;
    tag_wdata = {{(TAG_RAM_W - TAG_W){1'b0}}, miss_tag_q};

    if (refill_tag_write_fire) begin
      for (int w = 0; w < NUM_WAYS; w++) begin
        if (w == int'(victim_q)) tag_we[w] = 1'b1;
      end
    end
  end

  // ---- 1-deep RAW-bypass register ------------------------------------------
  // After a refill writes the tag at cycle N, an S0 read launched at cycle N
  // (same set) would see the OLD tag at S1 because port-B is "no_change".
  // The bypass tracks the most recent tag write and overrides the per-way
  // S1 tag compare.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_tag_write_q  <= 1'b0;
      prev_tag_set_q    <= {SET_IDX_W{1'b0}};
      prev_tag_way_oh_q <= {NUM_WAYS{1'b0}};
      prev_tag_data_q   <= {TAG_W{1'b0}};
    end else begin
      prev_tag_write_q <= refill_tag_write_fire;
      if (refill_tag_write_fire) begin
        prev_tag_set_q    <= miss_set_q;
        prev_tag_way_oh_q <= {NUM_WAYS{1'b0}};
        for (int w = 0; w < NUM_WAYS; w++) begin
          if (w == int'(victim_q)) prev_tag_way_oh_q[w] <= 1'b1;
        end
        prev_tag_data_q <= miss_tag_q;
      end
    end
  end

  // ---- S1 effective tag (post-RAW-bypass) ----------------------------------
  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      tag_rdata_eff_s1[w] = tag_rdata[w][TAG_W-1:0];
      if (prev_tag_write_q & (s1_set_idx == prev_tag_set_q) &
          prev_tag_way_oh_q[w]) begin
        tag_rdata_eff_s1[w] = prev_tag_data_q;
      end
    end
  end

  // ---- S1 → S2 tag holdover register ---------------------------------------
  // S2 hit detection runs against the registered tag.  Latched on s1_advance
  // (the same predicate that promotes the rest of the S1 entry into S2).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int w = 0; w < NUM_WAYS; w++) s2_tag_data_q[w] <= {TAG_W{1'b0}};
    end else if (s1_advance) begin
      for (int w = 0; w < NUM_WAYS; w++) s2_tag_data_q[w] <= tag_rdata_eff_s1[w];
    end
  end

  // ---- Bypass holding register ---------------------------------------------
  // bypass_drive presents the bypass tuple to the FB whenever a fresh
  // bypass_pulse fires OR a previously-held bypass is still waiting for FB
  // room.  The pending register clears when the FB accepts our enq and is
  // (re)loaded if a new bypass_pulse fires while the FB is still full.
  assign bypass_drive      = bypass_pulse | bypass_pending_q;
  assign bypass_drive_pc   = bypass_pending_q ? bypass_pending_pc_q : miss_pc_q;
  assign bypass_drive_data = bypass_pending_q ? bypass_pending_data_q : bypass_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bypass_pending_q      <= 1'b0;
      bypass_pending_pc_q   <= 32'h0;
      bypass_pending_data_q <= {kronos_pkg::INST_W{1'b0}};
    end else if (flush_i | s1_kill_i | s2_kill_i) begin
      // FENCE.I or any upstream redirect invalidates an in-flight held bypass.
      // After a redirect the FB is flushed and the IFU may be steered to a
      // different path; replaying the previous miss_pc word would push a
      // wrong-path tuple into the freshly cleared FB and predecode would emit
      // it on top of the new-path stream.
      bypass_pending_q      <= 1'b0;
    end else if (bypass_drive & s2_enq_ready_i) begin
      // FB took it (whether the fresh pulse or the held copy) — clear.
      bypass_pending_q      <= 1'b0;
    end else if (bypass_pulse & ~s2_enq_ready_i) begin
      // FB rejected this cycle's bypass — latch for retry.
      bypass_pending_q      <= 1'b1;
      bypass_pending_pc_q   <= miss_pc_q;
      bypass_pending_data_q <= bypass_data;
    end
  end

  // ---- Outputs --------------------------------------------------------------
  // S2 emits the registered (pc, data) tuple to FB.  On a bypass cycle the
  // critical-word tuple wins (either the fresh pulse or the held retry).  S2
  // hits cannot fire concurrently because s2_valid_q is cleared on miss_event,
  // so prioritising bypass is unambiguous.
  assign s2_enq_valid_o = s2_held_hit | bypass_drive;
  assign s2_enq_pc_o    = bypass_drive ? bypass_drive_pc   : s2_pc_q;
  assign s2_enq_data_o  = bypass_drive ? bypass_drive_data : s2_data_q;

  assign miss_pulse_o = miss_pulse_q;

  // Miss-event resync: combinational pulse + the PC that S0 must resume from
  // after the refill bypass has delivered the missed word into the FB.
  assign miss_event_o     = miss_event;
  assign miss_resync_pc_o = s2_pc_q + 32'd4;

  // Stash unused bit-slice tags so lint stays clean.  s2_addr_q[1:0] are
  // word-internal byte offsets (the cache feeds 32-bit words to predecode).
  // miss_word_q[0] is the doubleword-pair LSB; the AXI refill burst uses
  // miss_word_q[WORD_IDX_W-1:1] to address beats, so the LSB does not
  // gate the FSM.  The AXI response struct carries b_resp/r_user/r.id/etc.
  // that the read-only icache leg ignores; the OR-reduce over the whole
  // resp catches every dropped bit.
  assign _unused = ^{s1_word_idx, s2_word_idx,
                     s2_addr_q[1:0],
                     miss_word_q[0],
                     axi_rsp_i};

endmodule
