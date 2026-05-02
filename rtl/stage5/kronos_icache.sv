// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_icache.sv — Stage 5 instruction cache, BOOM-style v3 rewrite.
//
// Mirrors the Stage 6 icache structurally (S0/S1/S2 pipeline, kill inputs,
// FB-side enq handshake, refill bypass) without the PMP/TLB suppression
// inputs — Stage 5 has no privileged-mode fault sources on the fetch path.
// Bare 32/64/8 widths are used in place of kronos_pkg::INST_W /
// XLEN / XLEN_BYTES so the file matches the existing Stage 5 convention.
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

  // S0 input
  input  logic                   s0_valid_i,
  input  logic [PHYS_ADDR_W-1:0] s0_addr_i,
  input  logic [31:0]            s0_pc_i,
  output logic                   s0_ready_o,

  // Combinational kill inputs
  input  logic                   s1_kill_i,
  input  logic                   s2_kill_i,
  // Asserted only on confirmed (EX/MEM) redirects — drives the bypass-squash
  // latch.  Speculative predicted-taken redirects must NOT enter this signal,
  // otherwise a transient BTB false-hit on a sequential PC during a refill
  // window would suppress the legitimate critical-word bypass and the line's
  // first word would be lost from the FB.
  input  logic                   confirmed_redirect_i,

  // FENCE.I
  input  logic                   flush_i,

  // S2 output to FetchBuffer
  output logic                   s2_enq_valid_o,
  output logic [31:0]            s2_enq_pc_o,
  output logic [31:0]            s2_enq_data_o,
  input  logic                   s2_enq_ready_i,

  // Miss-event resync hook for kronos_top (see stage 6 doc; same semantics).
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
  localparam int unsigned WORD_IDX_W  = OFFSET_W - 2;
  localparam int unsigned TAG_W       = PHYS_ADDR_W - SET_IDX_W - OFFSET_W;
  localparam int unsigned WORDS       = LINE_BYTES / 4;
  localparam int unsigned BEATS       = LINE_BYTES / 8;
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
  logic [TAG_W-1:0]            tag_q   [NUM_SETS][NUM_WAYS];
  logic                        valid_q [NUM_SETS][NUM_WAYS];
  logic [2:0]                  plru_q  [NUM_SETS];

  // ---- Pipeline registers --------------------------------------------------
  logic                        s1_valid_q;
  logic [PHYS_ADDR_W-1:0]      s1_addr_q;
  logic [31:0]                 s1_pc_q;

  logic                        s2_valid_q;
  logic                        s2_hit_q;
  logic [PHYS_ADDR_W-1:0]      s2_addr_q;
  logic [31:0]                 s2_pc_q;
  logic [31:0]                 s2_data_q;

  // ---- Refill FSM and bookkeeping ------------------------------------------
  icache_state_e               state_q;
  logic                        miss_pulse_q;
  logic [SET_IDX_W-1:0]        miss_set_q;
  logic [TAG_W-1:0]            miss_tag_q;
  logic [WORD_IDX_W-1:0]       miss_word_q;
  logic [31:0]                 miss_pc_q;
  logic                        miss_addr2_q;
  logic [$clog2(NUM_WAYS)-1:0] victim_q;
  logic [BEAT_CNT_W-1:0]       beat_cnt_q;
  logic                        refill_phase_q;
  logic [31:0]                 refill_high_data_q;
  // Tracks an outstanding AXI read burst.  See stage 6 mirror for full
  // rationale — gates ar_valid so a flush-induced state reset cannot retrigger
  // an AR before the prior burst's R-beats drain.
  logic                        axi_outstanding_q;
  // Set when a redirect (s1_kill_i / s2_kill_i pulse) lands during a refill.
  // The line still completes — AXI cannot abort — but the critical-word bypass
  // is suppressed because the consumer has already been redirected away from
  // miss_pc.  Without this, the bypass would push a wrong-path (miss_pc, data)
  // tuple into the FB after the redirect's flush, corrupting the instruction
  // stream once the consumer re-engages.
  logic                        refill_squashed_q;

  // ---- Combinational signals -----------------------------------------------
  logic [SET_IDX_W-1:0]        s0_set_idx;
  logic [WORD_IDX_W-1:0]       s0_word_idx;
  logic [RAM_ADDR_W-1:0]       s0_ram_raddr;

  logic [SET_IDX_W-1:0]        s1_set_idx;
  logic [TAG_W-1:0]            s1_tag;
  logic [WORD_IDX_W-1:0]       s1_word_idx;
  logic [NUM_WAYS-1:0]         hit_way_oh_s1;
  logic                        hit_s1;
  logic [31:0]                 hit_word_s1;

  logic [SET_IDX_W-1:0]        s2_set_idx;
  logic [TAG_W-1:0]            s2_tag;
  logic [WORD_IDX_W-1:0]       s2_word_idx;
  logic [NUM_WAYS-1:0]         hit_way_oh_s2;
  logic [$clog2(NUM_WAYS)-1:0] hit_way_s2;

  logic                        s2_held_hit;
  logic                        s2_stall;
  logic                        s1_advance;
  logic                        s0_accept;
  logic                        miss_event;
  logic [$clog2(NUM_WAYS)-1:0] victim_pick;

  logic [WORD_IDX_W-1:0]       beat_base_word;
  logic [BEAT_CNT_W-1:0]       beat_idx;
  logic [31:0]                 refill_lo_word;
  logic [31:0]                 refill_hi_word;
  logic                        refill_lo_handshake;
  logic                        refill_hi_handshake;
  logic                        refill_last_done;

  logic                        bypass_pulse;
  logic [31:0]                 bypass_data;
  // 1-deep holding register for the bypass critical-word.  See stage 6
  // companion file for the full rationale — drops would otherwise occur when
  // the FB happens to be full at the cycle bypass_pulse fires.
  logic                        bypass_pending_q;
  logic [31:0]                 bypass_pending_pc_q;
  logic [31:0]                 bypass_pending_data_q;
  logic                        bypass_drive;
  logic [31:0]                 bypass_drive_pc;
  logic [31:0]                 bypass_drive_data;

  logic                        ram_re;
  logic [NUM_WAYS-1:0]         ram_we;
  logic [RAM_ADDR_W-1:0]       ram_waddr;
  logic [31:0]                 ram_wdata;
  logic [31:0]                 ram_rdata [NUM_WAYS];

  logic                        _unused;

  // ---- Functions ------------------------------------------------------------
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
  assign s0_word_idx  = s0_addr_i[OFFSET_W-1 : 2];
  assign s0_ram_raddr = {s0_set_idx, s0_word_idx};

  assign s1_set_idx   = s1_addr_q[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign s1_tag       = s1_addr_q[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign s1_word_idx  = s1_addr_q[OFFSET_W-1 : 2];

  assign s2_set_idx   = s2_addr_q[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign s2_tag       = s2_addr_q[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign s2_word_idx  = s2_addr_q[OFFSET_W-1 : 2];

  // ---- S1 hit logic ---------------------------------------------------------
  always_comb begin
    hit_way_oh_s1 = {NUM_WAYS{1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh_s1[w] = s1_valid_q & valid_q[s1_set_idx][w] &
                         (tag_q[s1_set_idx][w] == s1_tag);
    end
    hit_s1 = |hit_way_oh_s1;
  end

  always_comb begin
    hit_word_s1 = 32'h0;
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh_s1[w]) hit_word_s1 = ram_rdata[w];
    end
  end

  always_comb begin
    hit_way_oh_s2 = {NUM_WAYS{1'b0}};
    hit_way_s2    = {$clog2(NUM_WAYS){1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh_s2[w] = s2_valid_q & valid_q[s2_set_idx][w] &
                         (tag_q[s2_set_idx][w] == s2_tag);
    end
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh_s2[w]) hit_way_s2 = w[$clog2(NUM_WAYS)-1:0];
    end
  end

  always_comb begin
    victim_pick = {$clog2(NUM_WAYS){1'b0}};
    unique case (plru_q[s2_set_idx][2])
      1'b0: victim_pick = plru_q[s2_set_idx][1] ? 2'd1 : 2'd0;
      1'b1: victim_pick = plru_q[s2_set_idx][0] ? 2'd3 : 2'd2;
      default: victim_pick = {$clog2(NUM_WAYS){1'b0}};
    endcase
  end

  // ---- Pipeline back-pressure ----------------------------------------------
  assign s2_held_hit = s2_valid_q & s2_hit_q & ~s2_kill_i;
  assign s2_stall    = s2_held_hit & ~s2_enq_ready_i;
  assign s1_advance  = s1_valid_q & ~s2_stall & (state_q == ICACHE_IDLE);
  assign s0_ready_o  = (state_q == ICACHE_IDLE) & ~s2_stall;
  assign s0_accept   = s0_valid_i & s0_ready_o;

  // ---- Refill helpers -------------------------------------------------------
  always_comb begin
    beat_idx       = miss_word_q[WORD_IDX_W-1:1] + beat_cnt_q[BEAT_CNT_W-1:0];
    beat_base_word = {beat_idx, 1'b0};
  end

  assign refill_lo_word = axi_rsp_i.r.data[31:0];
  assign refill_hi_word = axi_rsp_i.r.data[63:32];

  assign refill_lo_handshake = (state_q == ICACHE_REFILL_R) &
                               axi_rsp_i.r_valid & axi_req_o.r_ready &
                               ~refill_phase_q;
  assign refill_hi_handshake = (state_q == ICACHE_REFILL_R) & refill_phase_q;
  assign refill_last_done    = refill_hi_handshake &
                               (beat_cnt_q == BEAT_CNT_W'(BEATS-1));

  always_comb begin
    if (refill_phase_q) begin
      ram_waddr = {miss_set_q, beat_base_word + WORD_IDX_W'(1)};
      ram_wdata = refill_high_data_q;
    end else begin
      ram_waddr = {miss_set_q, beat_base_word};
      ram_wdata = refill_lo_word;
    end
  end

  always_comb begin
    ram_we = {NUM_WAYS{1'b0}};
    if (refill_lo_handshake | refill_hi_handshake) begin
      ram_we[victim_q] = 1'b1;
    end
  end

  assign ram_re = s0_accept;

  // ---- Miss / bypass --------------------------------------------------------
  assign miss_event = s2_valid_q & ~s2_hit_q & ~s2_kill_i &
                      (state_q == ICACHE_IDLE);

  // Suppressed when the refill was squashed by a mid-flight redirect — the
  // (miss_pc, data) tuple is no longer on the consumer's path.
  assign bypass_pulse = refill_lo_handshake & (beat_cnt_q == {BEAT_CNT_W{1'b0}}) &
                        ~refill_squashed_q;
  assign bypass_data  = miss_addr2_q ? refill_hi_word : refill_lo_word;

  // ---- Pipeline registers (S1, S2) -----------------------------------------
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
      s1_valid_q <= s1_valid_q & ~s1_kill_i;
    end else begin
      s1_valid_q <= s0_accept & ~s1_kill_i;
      if (s0_accept) begin
        s1_addr_q <= s0_addr_i;
        s1_pc_q   <= s0_pc_i;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid_q <= 1'b0;
      s2_hit_q   <= 1'b0;
      s2_addr_q  <= {PHYS_ADDR_W{1'b0}};
      s2_pc_q    <= 32'h0;
      s2_data_q  <= 32'h0;
    end else if (flush_i) begin
      s2_valid_q <= 1'b0;
    end else if (miss_event) begin
      s2_valid_q <= 1'b0;
    end else if (s2_stall) begin
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
      refill_high_data_q <= 32'h0;
      refill_squashed_q  <= 1'b0;
      for (int s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= 3'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          valid_q[s][w] <= 1'b0;
          tag_q[s][w]   <= {TAG_W{1'b0}};
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
            refill_high_data_q <= refill_hi_word;
            refill_phase_q     <= 1'b1;
          end else if (refill_hi_handshake) begin
            refill_phase_q <= 1'b0;
            beat_cnt_q     <= beat_cnt_q + BEAT_CNT_W'(1);
            if (refill_last_done) begin
              tag_q[miss_set_q][victim_q]   <= miss_tag_q;
              valid_q[miss_set_q][victim_q] <= 1'b1;
              plru_q[miss_set_q]            <= plru_update(plru_q[miss_set_q], victim_q);
              refill_squashed_q             <= 1'b0;
              state_q <= ICACHE_IDLE;
            end
          end
        end
        default: state_q <= ICACHE_IDLE;
      endcase

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
    axi_req_o.ar.size  = 3'b011;
    axi_req_o.ar.len   = 8'd7;
    axi_req_o.ar.burst = axi_pkg::BURST_WRAP;
    axi_req_o.ar.id    = {$bits(axi_req_o.ar.id){1'b0}};
    // Block AR while a previous burst is still outstanding (FENCE.I can force
    // the FSM back to IDLE before the prior R-beats drain).
    axi_req_o.ar_valid = (state_q == ICACHE_REFILL_AR) & ~axi_outstanding_q;
    // Drain R beats whenever a burst is outstanding.  Outside REFILL_R the
    // BRAM write enables are off, so accepting drains-and-discards.
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
        .WIDTH      (32),
        .BYTE_WIDTH (8)
      ) u_ram (
        .clk_i   (clk_i),
        .we_i    (ram_we[gi]),
        .waddr_i (ram_waddr),
        .wdata_i (ram_wdata),
        .wmask_i (4'b1111),
        .re_i    (ram_re),
        .raddr_i (s0_ram_raddr),
        .rdata_o (ram_rdata[gi])
      );
    end
  endgenerate

  // ---- Bypass holding register ---------------------------------------------
  assign bypass_drive      = bypass_pulse | bypass_pending_q;
  assign bypass_drive_pc   = bypass_pending_q ? bypass_pending_pc_q : miss_pc_q;
  assign bypass_drive_data = bypass_pending_q ? bypass_pending_data_q : bypass_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bypass_pending_q      <= 1'b0;
      bypass_pending_pc_q   <= 32'h0;
      bypass_pending_data_q <= 32'h0;
    end else if (flush_i | s1_kill_i | s2_kill_i) begin
      // FENCE.I or any upstream redirect invalidates a held bypass — see
      // stage 6 mirror for the full rationale.
      bypass_pending_q      <= 1'b0;
    end else if (bypass_drive & s2_enq_ready_i) begin
      bypass_pending_q      <= 1'b0;
    end else if (bypass_pulse & ~s2_enq_ready_i) begin
      bypass_pending_q      <= 1'b1;
      bypass_pending_pc_q   <= miss_pc_q;
      bypass_pending_data_q <= bypass_data;
    end
  end

  // ---- Outputs --------------------------------------------------------------
  assign s2_enq_valid_o = s2_held_hit | bypass_drive;
  assign s2_enq_pc_o    = bypass_drive ? bypass_drive_pc   : s2_pc_q;
  assign s2_enq_data_o  = bypass_drive ? bypass_drive_data : s2_data_q;

  assign miss_pulse_o = miss_pulse_q;

  // Miss-event resync (combinational): same semantics as the stage-6 mirror.
  assign miss_event_o     = miss_event;
  assign miss_resync_pc_o = s2_pc_q + 32'd4;

  assign _unused = ^{s1_word_idx, s2_word_idx};

endmodule
