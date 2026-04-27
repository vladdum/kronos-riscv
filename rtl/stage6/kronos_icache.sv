// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_icache.sv — Stage 5e instruction cache.
//
// 16 KB, 4-way set-associative, 64-byte lines, Tree-PLRU replacement,
// critical-word-first refill via AXI WRAP8 burst (8 × 64-bit beats).
// See docs/superpowers/specs/2026-04-26-icache-design.md.
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

  // Upstream — fetch request from kronos_top
  input  logic                   req_i,
  input  logic [PHYS_ADDR_W-1:0] addr_i,
  input  logic                   flush_i,
  input  logic                   pmp_fault_i,
  output logic                   data_valid_o,
  output logic [31:0]            data_o,
  output logic                   stall_o,

  // Downstream AXI4 read master
  output kronos_axi_req_t        axi_req_o,
  input  kronos_axi_resp_t       axi_rsp_i,

  // Performance counter pulse
  output logic                   miss_pulse_o
);

  // ---- Derived parameters ----------------------------------------------------
  localparam int unsigned NUM_SETS    = CACHE_BYTES / (NUM_WAYS * LINE_BYTES);
  localparam int unsigned SET_IDX_W   = $clog2(NUM_SETS);
  localparam int unsigned OFFSET_W    = $clog2(LINE_BYTES);
  localparam int unsigned WORD_IDX_W  = OFFSET_W - 2;              // 32-bit words/line
  localparam int unsigned TAG_W       = PHYS_ADDR_W - SET_IDX_W - OFFSET_W;
  localparam int unsigned WORDS       = LINE_BYTES / 4;             // 32-bit words/line = 16
  localparam int unsigned BEATS       = LINE_BYTES / 8;             // 64-bit beats/line = 8
  localparam int unsigned BEAT_CNT_W  = $clog2(BEATS);             // 3 bits

  // ---- Storage ---------------------------------------------------------------
  logic [31:0]   data_q  [NUM_WAYS][NUM_SETS][WORDS];
  logic [TAG_W-1:0] tag_q  [NUM_SETS][NUM_WAYS];
  logic             valid_q [NUM_SETS][NUM_WAYS];
  logic [2:0]       plru_q  [NUM_SETS];

  // ---- Address breakdown -----------------------------------------------------
  logic [SET_IDX_W-1:0]  set_idx;
  logic [TAG_W-1:0]      tag_in;
  logic [WORD_IDX_W-1:0] word_idx;
  assign set_idx  = addr_i[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign tag_in   = addr_i[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign word_idx = addr_i[OFFSET_W-1 : 2];

  // ---- Hit logic -------------------------------------------------------------
  logic [NUM_WAYS-1:0] hit_way_oh;
  logic                hit;
  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh[w] = req_i & valid_q[set_idx][w] & (tag_q[set_idx][w] == tag_in);
    end
    hit = |hit_way_oh;
  end

  // ---- State machine ---------------------------------------------------------
  typedef enum logic [1:0] {
    ICACHE_IDLE       = 2'b00,
    ICACHE_REFILL_AR  = 2'b01,
    ICACHE_REFILL_R   = 2'b10
  } icache_state_e;

  icache_state_e state_q;

  // State registers
  logic miss_pulse_q;
  logic miss_event;
  logic [SET_IDX_W-1:0]        miss_set_q;
  logic [TAG_W-1:0]            miss_tag_q;
  logic [WORD_IDX_W-1:0]       miss_word_q;
  logic [$clog2(NUM_WAYS)-1:0] victim_q;
  logic [BEAT_CNT_W-1:0]       beat_cnt_q;  // 3 bits: 0..7
  logic                        miss_addr2_q; // addr[2] within the critical 64-bit beat
  logic                        bypass_valid_q;
  logic [31:0]                 bypass_data_q;

  // Combinational signals
  logic [$clog2(NUM_WAYS)-1:0] victim_pick;

  assign miss_event = req_i & ~hit & (state_q == ICACHE_IDLE);

  // Tree-PLRU victim selection.
  //      bit[2] (root)
  //      /          \
  //   bit[1]        bit[0]
  //   /    \        /    \
  // way0  way1   way2   way3
  always_comb begin
    unique case (plru_q[set_idx][2])
      1'b0: victim_pick = plru_q[set_idx][1] ? 2'd1 : 2'd0;   // left subtree
      1'b1: victim_pick = plru_q[set_idx][0] ? 2'd3 : 2'd2;   // right subtree
      default: victim_pick = '0;
    endcase
  end

  // PLRU update function: flip bits along the path away from the accessed way.
  function automatic logic [2:0] plru_update(
    input logic [2:0] cur,
    input logic [$clog2(NUM_WAYS)-1:0] way
  );
    logic [2:0] nxt;
    nxt = cur;
    unique case (way)
      2'd0: begin nxt[2] = 1'b1; nxt[1] = 1'b1; end
      2'd1: begin nxt[2] = 1'b1; nxt[1] = 1'b0; end
      2'd2: begin nxt[2] = 1'b0; nxt[0] = 1'b1; end
      2'd3: begin nxt[2] = 1'b0; nxt[0] = 1'b0; end
      default: ;
    endcase
    return nxt;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ICACHE_IDLE;
      miss_pulse_q <= 1'b0;
      miss_set_q   <= '0;
      miss_tag_q   <= '0;
      miss_word_q  <= '0;
      victim_q     <= '0;
      beat_cnt_q     <= '0;
      miss_addr2_q   <= '0;
      bypass_valid_q <= 1'b0;
      bypass_data_q  <= 32'b0;
      for (int s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= 3'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          valid_q[s][w] <= 1'b0;
          tag_q[s][w]   <= '0;
        end
      end
      // Explicit reset of data_q. Mirrors the dcache fix.
      for (int w = 0; w < NUM_WAYS; w++) begin
        for (int s = 0; s < NUM_SETS; s++) begin
          for (int wd = 0; wd < WORDS; wd++) begin
            data_q[w][s][wd] <= '0;
          end
        end
      end
    end else begin
      miss_pulse_q   <= miss_event;
      bypass_valid_q <= 1'b0;        // default: clear bypass each cycle
      unique case (state_q)
        ICACHE_IDLE: begin
          // On hit, mark hit way as MRU.
          if (hit) begin
            for (int w = 0; w < NUM_WAYS; w++) begin
              if (hit_way_oh[w]) plru_q[set_idx] <= plru_update(plru_q[set_idx], w[1:0]);
            end
          end
          if (miss_event) begin
            miss_set_q  <= set_idx;
            miss_tag_q  <= tag_in;
            miss_word_q <= word_idx;
            victim_q    <= victim_pick;
            beat_cnt_q  <= '0;
            state_q     <= ICACHE_REFILL_AR;
          end
        end
        ICACHE_REFILL_AR: begin
          if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) begin
            state_q      <= ICACHE_REFILL_R;
            miss_addr2_q <= miss_word_q[0];  // addr[2] within the critical 64-bit beat
          end
        end
        ICACHE_REFILL_R: begin
          if (axi_req_o.r_ready & axi_rsp_i.r_valid) begin
            // WRAP burst: beat N fills 64-bit word (miss_beat + N) mod BEATS.
            // miss_beat = miss_word_q[WORD_IDX_W-1:1] (upper bits, beat-aligned).
            // Each beat covers two 32-bit words: indices beat*2 and beat*2+1.
            // The WRAP offset is a beat index; we compute the 32-bit word addresses.
            begin
              automatic logic [WORD_IDX_W-1:0] beat_base_word;
              automatic logic [BEAT_CNT_W-1:0] beat_idx;
              beat_idx       = miss_word_q[WORD_IDX_W-1:1] + beat_cnt_q[BEAT_CNT_W-1:0];
              beat_base_word = {beat_idx, 1'b0};
              data_q[victim_q][miss_set_q][beat_base_word]     <= axi_rsp_i.r.data[31:0];
              data_q[victim_q][miss_set_q][beat_base_word + 1] <= axi_rsp_i.r.data[63:32];
              beat_cnt_q <= beat_cnt_q + 1'b1;
              // CWF bypass: expose the correct 32-bit half of the first beat.
              if (beat_cnt_q == '0) begin
                bypass_valid_q <= 1'b1;
                bypass_data_q  <= miss_addr2_q ? axi_rsp_i.r.data[63:32]
                                                   : axi_rsp_i.r.data[31:0];
              end
              if (axi_rsp_i.r.last) begin
                tag_q[miss_set_q][victim_q]   <= miss_tag_q;
                valid_q[miss_set_q][victim_q] <= 1'b1;
                plru_q[miss_set_q]            <= plru_update(plru_q[miss_set_q], victim_q);
                state_q <= ICACHE_IDLE;
              end
            end
          end
        end
        default: state_q <= ICACHE_IDLE;
      endcase
      // FENCE.I: clear all valid bits.  An in-flight refill still completes;
      // any other lines lose their valid bits.
      if (flush_i) begin
        for (int s = 0; s < NUM_SETS; s++) begin
          for (int w = 0; w < NUM_WAYS; w++) begin
            valid_q[s][w] <= 1'b0;
          end
        end
      end
    end
  end

  // ---- AXI request driver (combinational) ------------------------------------
  always_comb begin
    axi_req_o = '0;
    // CWF: ar_addr is the critical-beat's 8-byte-aligned address.  WRAP burst
    // wraps at line boundary, so the first beat contains the critical word.
    axi_req_o.ar.addr  = {miss_tag_q[TAG_W-1:0],
                          miss_set_q, miss_word_q[WORD_IDX_W-1:1], 3'b000};
    axi_req_o.ar.size  = 3'b011;                // 8 bytes per beat
    axi_req_o.ar.len   = 8'd7;                  // 8 beats
    axi_req_o.ar.burst = axi_pkg::BURST_WRAP;
    axi_req_o.ar.id    = '0;
    axi_req_o.ar_valid = (state_q == ICACHE_REFILL_AR) & ~pmp_fault_i;
    axi_req_o.r_ready  = (state_q == ICACHE_REFILL_R);
  end

  // ---- Hit data path (way-select mux on data_q) ------------------------------
  logic [31:0] hit_word;
  always_comb begin
    hit_word = '0;
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh[w]) hit_word = data_q[w][set_idx][word_idx];
    end
  end

  // ---- Outputs ---------------------------------------------------------------
  assign data_valid_o = hit | bypass_valid_q;
  assign data_o       = bypass_valid_q ? bypass_data_q : hit_word;
  assign stall_o      = (state_q != ICACHE_IDLE);
  assign miss_pulse_o = miss_pulse_q;

  // word_idx is used only in the hit data path (combinational), not in any
  // always block; XOR it to suppress potential UNUSED lint noise.
  logic _unused;
  assign _unused = ^{word_idx};

endmodule
