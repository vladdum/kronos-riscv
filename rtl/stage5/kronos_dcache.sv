// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_dcache.sv — Stage 5f data cache.
//
// 16 KB, 4-way set-associative, 64-byte lines, Tree-PLRU replacement,
// write-back / write-allocate, critical-word-first refill via AXI WRAP
// burst, dirty-line writeback via AXI INCR burst.  AMO RMW and LR/SC
// reservation tracking live inside the cache.
//
// See docs/superpowers/specs/2026-04-27-dcache-design.md.
module kronos_dcache
  import kronos_pkg::*;
#(
  parameter int unsigned CACHE_BYTES = 16*1024,
  parameter int unsigned NUM_WAYS    = 4,
  parameter int unsigned LINE_BYTES  = 64,
  parameter int unsigned PHYS_ADDR_W = 64
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // LSU side
  input  logic                   req_i,
  input  logic [PHYS_ADDR_W-1:0] addr_i,
  input  logic [2:0]             size_i,
  input  logic                   we_i,
  input  logic [63:0]            wdata_i,
  input  logic                   amo_req_i,
  input  logic [4:0]             amo_op_i,
  input  logic                   rsrv_clear_i,
  output logic                   data_valid_o,
  output logic [63:0]            rdata_o,
  output logic                   sc_success_o,
  output logic                   stall_o,

  // FENCE.I full flush: writeback every dirty line and invalidate.  Hold
  // flush_i high until flush_done_o pulses for one cycle.
  input  logic                   flush_i,
  output logic                   flush_done_o,
  output logic                   dirty_pending_o,

  // AXI4 master (read + write)
  output kronos_axi_req_t        axi_req_o,
  input  kronos_axi_resp_t       axi_rsp_i,

  // Performance counter pulse — wired to event_bus[0x11]
  output logic                   miss_pulse_o
);

  // ---- Derived parameters ---------------------------------------------------
  localparam int unsigned NUM_SETS    = CACHE_BYTES / (NUM_WAYS * LINE_BYTES);
  localparam int unsigned SET_IDX_W   = $clog2(NUM_SETS);
  localparam int unsigned OFFSET_W    = $clog2(LINE_BYTES);
  localparam int unsigned BEAT_IDX_W  = OFFSET_W - 3;
  localparam int unsigned TAG_W       = PHYS_ADDR_W - SET_IDX_W - OFFSET_W;
  localparam int unsigned BEATS       = LINE_BYTES / 8;

  // ---- Storage --------------------------------------------------------------
  logic [TAG_W-1:0] tag_q   [NUM_SETS][NUM_WAYS];
  logic             valid_q [NUM_SETS][NUM_WAYS];
  logic             dirty_q [NUM_SETS][NUM_WAYS];
  logic [2:0]       plru_q  [NUM_SETS];
  logic [63:0]      data_q  [NUM_WAYS][NUM_SETS][BEATS];

  // ---- Address breakdown ----------------------------------------------------
  logic [SET_IDX_W-1:0]  set_idx;
  logic [TAG_W-1:0]      tag_in;
  logic [BEAT_IDX_W-1:0] beat_idx;
  assign set_idx  = addr_i[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign tag_in   = addr_i[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign beat_idx = addr_i[OFFSET_W-1 : 3];

  // ---- Hit logic ------------------------------------------------------------
  logic [NUM_WAYS-1:0] hit_way_oh;
  logic                hit;
  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh[w] = req_i & valid_q[set_idx][w] & (tag_q[set_idx][w] == tag_in);
    end
    hit = |hit_way_oh;
  end

  // ---- State machine --------------------------------------------------------
  // Subsequent tasks will add WB_AW, WB_W, AMO_RMW states.  For Task 2 we
  // only have IDLE / REFILL_AR / REFILL_R.
  typedef enum logic [3:0] {
    DC_IDLE       = 4'b0000,
    DC_REFILL_AR  = 4'b0001,
    DC_REFILL_R   = 4'b0010,
    DC_WB_AW      = 4'b0011,
    DC_WB_W       = 4'b0100,
    DC_AMO_RMW    = 4'b0101,
    DC_FLUSH_SCAN = 4'b0110,
    DC_FLUSH_AW   = 4'b0111,
    DC_FLUSH_W    = 4'b1000
  } dcache_state_e;

  dcache_state_e state_q;

  logic miss_pulse_q;
  logic miss_event;
  assign miss_event = req_i & ~hit & (state_q == DC_IDLE);

  // Tree-PLRU victim selection (same as I$).
  logic [$clog2(NUM_WAYS)-1:0] victim_pick;
  always_comb begin
    unique case (plru_q[set_idx][2])
      1'b0: victim_pick = plru_q[set_idx][1] ? 2'd1 : 2'd0;
      1'b1: victim_pick = plru_q[set_idx][0] ? 2'd3 : 2'd2;
      default: victim_pick = '0;
    endcase
  end

  function automatic logic [7:0] store_strobes(input logic [2:0] sz, input logic [2:0] off);
    case (sz)
      3'd0: return 8'b00000001 << off;
      3'd1: return 8'b00000011 << {off[2:1], 1'b0};
      3'd2: return 8'b00001111 << {off[2], 2'b00};
      3'd3: return 8'b11111111;
      default: return 8'b0;
    endcase
  endfunction

  function automatic logic [63:0] store_data_aligned(
    input logic [2:0]  sz,
    input logic [2:0]  off,
    input logic [63:0] data
  );
    logic [63:0] r;
    case (sz)
      3'd0: r = {8{data[7:0]}};
      3'd1: r = {4{data[15:0]}};
      3'd2: r = {2{data[31:0]}};
      default: r = data;
    endcase
    return r;
  endfunction

  // funct5 → AMO operation (RISC-V A-extension).  is_word=1 for AMO.W
  // (treat as 32-bit signed/unsigned, sign-extend the result).
  function automatic logic [63:0] amo_compute(
    input logic [4:0]  funct5,
    input logic [63:0] old_val,
    input logic [63:0] src_val,
    input logic        is_word
  );
    logic [63:0] a;
    logic [63:0] b;
    logic [63:0] r;
    a = is_word ? {{32{old_val[31]}}, old_val[31:0]} : old_val;
    b = is_word ? {{32{src_val[31]}}, src_val[31:0]} : src_val;
    unique case (funct5)
      5'b00001: r = b;                                       // AMOSWAP
      5'b00000: r = a + b;                                   // AMOADD
      5'b00100: r = a ^ b;                                   // AMOXOR
      5'b01100: r = a & b;                                   // AMOAND
      5'b01000: r = a | b;                                   // AMOOR
      5'b10000: r = ($signed(a) < $signed(b)) ? a : b;       // AMOMIN
      5'b10100: r = ($signed(a) > $signed(b)) ? a : b;       // AMOMAX
      5'b11000: r = (a < b) ? a : b;                         // AMOMINU
      5'b11100: r = (a > b) ? a : b;                         // AMOMAXU
      default:  r = a;
    endcase
    return r;
  endfunction

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

  // Vivado synthesis (IEEE 1800 grammar) rejects bit-selects on function-call
  // returns — e.g. `store_strobes(...)[b]`. Hoist the per-cycle results into
  // combinational nets so the per-byte loops can index into them directly.
  logic [ 7:0] store_strobes_in;
  logic [63:0] store_data_aligned_in;
  assign store_strobes_in      = store_strobes(size_i, addr_i[2:0]);
  assign store_data_aligned_in = store_data_aligned(size_i, addr_i[2:0], wdata_i);

  logic [SET_IDX_W-1:0]            miss_set_q;
  logic [TAG_W-1:0]                miss_tag_q;
  logic [BEAT_IDX_W-1:0]           miss_beat_q;
  logic [$clog2(NUM_WAYS)-1:0]     victim_q;
  logic [3:0]                      beat_cnt_q;
  logic                            bypass_valid_q;
  logic [63:0]                     bypass_data_q;
  logic                            miss_was_store_q;
  logic [63:0]                     miss_store_data_q;
  logic [7:0]                      miss_store_strobes_q;
  logic [2:0]                      miss_store_off_q;
  logic                            store_done_q;
  logic [3:0]                      wb_beat_cnt_q;
  logic [TAG_W-1:0]                evict_tag_q;

  // AMO state registers
  logic        amo_pending_q;
  logic [4:0]  amo_op_q;
  logic [63:0] amo_src_q;
  logic [63:0] amo_old_val_q;
  logic        amo_done_q;
  logic        amo_is_word_q;     // size_i == 3'd2
  logic [2:0]  amo_addr_off_q;    // addr_i[2:0] captured at AMO issue

  // LR/SC reservation registers
  logic [PHYS_ADDR_W-1:0] rsrv_addr_q;
  logic                   rsrv_valid_q;
  logic                   sc_success_q;

  // Flush state (FENCE.I full writeback + invalidate walk)
  logic [SET_IDX_W-1:0]              flush_set_q;
  logic [$clog2(NUM_WAYS)-1:0]       flush_way_q;
  logic                              flush_done_q;

  // dirty_pending_o: 1 if any (set, way) has valid && dirty.  Used by the
  // top to short-circuit FENCE.I when no writeback is required.
  logic dirty_pending;
  always_comb begin
    dirty_pending = 1'b0;
    for (int s = 0; s < NUM_SETS; s++)
      for (int w = 0; w < NUM_WAYS; w++)
        dirty_pending |= valid_q[s][w] & dirty_q[s][w];
  end
  assign dirty_pending_o = dirty_pending;
  assign flush_done_o    = flush_done_q;

  // AMO intermediate signals for DC_AMO_RMW
  logic [63:0] amo_cur_beat;
  logic [63:0] amo_result;
  logic [7:0]  amo_be;
  logic [63:0] amo_aligned;

  // hit_way_idx: binary encoding of hit way for AMO/SC use
  logic [$clog2(NUM_WAYS)-1:0] hit_way_idx;
  always_comb begin
    hit_way_idx = '0;
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh[w]) hit_way_idx = w[$clog2(NUM_WAYS)-1:0];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= DC_IDLE;
      miss_pulse_q   <= 1'b0;
      miss_set_q     <= '0;
      miss_tag_q     <= '0;
      miss_beat_q    <= '0;
      victim_q       <= '0;
      beat_cnt_q     <= 4'd0;
      bypass_valid_q       <= 1'b0;
      bypass_data_q        <= 64'b0;
      miss_was_store_q     <= 1'b0;
      miss_store_data_q    <= 64'b0;
      miss_store_strobes_q <= 8'b0;
      miss_store_off_q     <= 3'b0;
      store_done_q         <= 1'b0;
      wb_beat_cnt_q        <= 4'd0;
      evict_tag_q          <= '0;
      amo_pending_q        <= 1'b0;
      amo_op_q             <= 5'b0;
      amo_src_q            <= 64'b0;
      amo_old_val_q        <= 64'b0;
      amo_done_q           <= 1'b0;
      amo_is_word_q        <= 1'b0;
      amo_addr_off_q       <= 3'b0;
      rsrv_addr_q          <= '0;
      rsrv_valid_q         <= 1'b0;
      sc_success_q         <= 1'b0;
      flush_set_q          <= '0;
      flush_way_q          <= '0;
      flush_done_q         <= 1'b0;
      for (int s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= 3'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          valid_q[s][w] <= 1'b0;
          dirty_q[s][w] <= 1'b0;
          tag_q[s][w]   <= '0;
        end
      end
    end else begin
      miss_pulse_q   <= miss_event;
      bypass_valid_q <= 1'b0;
      store_done_q   <= 1'b0;
      amo_done_q     <= 1'b0;
      sc_success_q   <= 1'b0;
      flush_done_q   <= 1'b0;     // default: one-cycle pulse
      // Reservation tracking.
      // - LR sets it.
      // - SC clears it (regardless of success).
      // - Plain store to the SAME line clears it.
      // - rsrv_clear_i (trap) clears it.
      if (rsrv_clear_i) begin
        rsrv_valid_q <= 1'b0;
      end else if (req_i & amo_req_i & (amo_op_i == 5'b00010)) begin
        // LR: set reservation on the LR request.
        rsrv_addr_q  <= addr_i;
        rsrv_valid_q <= 1'b1;
      end else if (req_i & amo_req_i & (amo_op_i == 5'b00011)) begin
        // SC: clear reservation regardless of success.
        rsrv_valid_q <= 1'b0;
      end else if (req_i & we_i & ~amo_req_i & rsrv_valid_q
                   & (rsrv_addr_q[PHYS_ADDR_W-1:OFFSET_W] == addr_i[PHYS_ADDR_W-1:OFFSET_W])) begin
        // Plain store to the same cache line clears reservation.
        rsrv_valid_q <= 1'b0;
      end
      unique case (state_q)
        DC_IDLE: begin
          // flush_done_q pulse-cycle: parent's flush_i may still be asserted
          // for one more cycle while it tears down its hold; ignore the new
          // request so we don't restart a second flush walk.
          if (flush_i & ~flush_done_q) begin
            // FENCE.I full writeback + invalidate walk.
            flush_set_q <= '0;
            flush_way_q <= '0;
            state_q     <= DC_FLUSH_SCAN;
          end else if (req_i & amo_req_i & ~amo_pending_q & ~amo_done_q) begin
            if (amo_op_i == 5'b00011) begin
              // SC: check reservation; if matched, write; else no-op.
              if (rsrv_valid_q & (rsrv_addr_q == addr_i) & hit) begin
                // SC success on cached line: write, set dirty.
                for (int w = 0; w < NUM_WAYS; w++) begin
                  if (hit_way_oh[w]) begin
                    for (int b = 0; b < 8; b++) begin
                      if (store_strobes_in[b])
                        data_q[w][set_idx][beat_idx][b*8 +: 8]
                          <= store_data_aligned_in[b*8 +: 8];
                    end
                    dirty_q[set_idx][w] <= 1'b1;
                  end
                end
                plru_q[set_idx] <= plru_update(plru_q[set_idx], hit_way_idx);
                sc_success_q    <= 1'b1;
                store_done_q    <= 1'b1;
              end else if (rsrv_valid_q & (rsrv_addr_q == addr_i) & ~hit) begin
                // SC miss + match: write-allocate.
                miss_set_q           <= set_idx;
                miss_tag_q           <= tag_in;
                miss_beat_q          <= beat_idx;
                victim_q             <= victim_pick;
                beat_cnt_q           <= 4'd0;
                miss_was_store_q     <= 1'b1;
                miss_store_data_q    <= store_data_aligned(size_i, addr_i[2:0], wdata_i);
                miss_store_strobes_q <= store_strobes(size_i, addr_i[2:0]);
                miss_store_off_q     <= addr_i[2:0];
                evict_tag_q          <= tag_q[set_idx][victim_pick];
                wb_beat_cnt_q        <= 4'd0;
                sc_success_q         <= 1'b1;
                if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                  state_q <= DC_WB_AW;
                end else begin
                  state_q <= DC_REFILL_AR;
                end
              end else begin
                // SC fail: don't write; ack via store_done.
                store_done_q <= 1'b1;
              end
            end else if (amo_op_i == 5'b00010) begin
              // LR: treat as a plain load.  Reservation set by tracking above.
              // Just ack via hit or let a miss refill.
              if (hit) begin
                // Hit: data_valid fires naturally from hit; nothing extra to do.
              end else begin
                // LR miss: refill.
                miss_set_q     <= set_idx;
                miss_tag_q     <= tag_in;
                miss_beat_q    <= beat_idx;
                victim_q       <= victim_pick;
                beat_cnt_q     <= 4'd0;
                evict_tag_q    <= tag_q[set_idx][victim_pick];
                wb_beat_cnt_q  <= 4'd0;
                if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                  state_q <= DC_WB_AW;
                end else begin
                  state_q <= DC_REFILL_AR;
                end
              end
            end else begin
              // Non-LR/SC AMO: hit → RMW state; miss → refill then RMW.
              if (hit) begin
                // Capture for the AMO RMW state.
                amo_pending_q  <= 1'b1;
                amo_op_q       <= amo_op_i;
                amo_src_q      <= wdata_i;
                amo_old_val_q  <= hit_beat;
                amo_is_word_q  <= (size_i == 3'd2);
                amo_addr_off_q <= addr_i[2:0];
                miss_set_q     <= set_idx;
                miss_beat_q    <= beat_idx;
                victim_q       <= hit_way_idx;
                // Update PLRU on the AMO access.
                plru_q[set_idx] <= plru_update(plru_q[set_idx], hit_way_idx);
                state_q <= DC_AMO_RMW;
              end else begin
                // AMO miss: do a normal load-style refill, then transition
                // to RMW after refill completes.
                miss_set_q     <= set_idx;
                miss_tag_q     <= tag_in;
                miss_beat_q    <= beat_idx;
                victim_q       <= victim_pick;
                beat_cnt_q     <= 4'd0;
                amo_pending_q  <= 1'b1;
                amo_op_q       <= amo_op_i;
                amo_src_q      <= wdata_i;
                amo_is_word_q  <= (size_i == 3'd2);
                amo_addr_off_q <= addr_i[2:0];
                evict_tag_q    <= tag_q[set_idx][victim_pick];
                wb_beat_cnt_q  <= 4'd0;
                if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                  state_q <= DC_WB_AW;
                end else begin
                  state_q <= DC_REFILL_AR;
                end
              end
            end
          end else begin
            // Store hit: write into RAM, set dirty.
            if (hit & we_i & req_i) begin
              for (int w = 0; w < NUM_WAYS; w++) begin
                if (hit_way_oh[w]) begin
                  for (int b = 0; b < 8; b++) begin
                    if (store_strobes_in[b])
                      data_q[w][set_idx][beat_idx][b*8 +: 8]
                        <= store_data_aligned_in[b*8 +: 8];
                  end
                  dirty_q[set_idx][w] <= 1'b1;
                end
              end
            end
            // Hit (load or store): update PLRU.
            if (hit) begin
              for (int w = 0; w < NUM_WAYS; w++) begin
                if (hit_way_oh[w]) plru_q[set_idx] <= plru_update(plru_q[set_idx], w[1:0]);
              end
            end
            // Miss (load or store): start refill.  Capture store info for merge.
            if (miss_event) begin
              miss_set_q           <= set_idx;
              miss_tag_q           <= tag_in;
              miss_beat_q          <= beat_idx;
              victim_q             <= victim_pick;
              beat_cnt_q           <= 4'd0;
              miss_was_store_q     <= we_i;
              miss_store_data_q    <= store_data_aligned(size_i, addr_i[2:0], wdata_i);
              miss_store_strobes_q <= store_strobes(size_i, addr_i[2:0]);
              miss_store_off_q     <= addr_i[2:0];
              evict_tag_q          <= tag_q[set_idx][victim_pick];
              wb_beat_cnt_q        <= 4'd0;
              if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                state_q <= DC_WB_AW;
              end else begin
                state_q <= DC_REFILL_AR;
              end
            end
          end
        end
        DC_REFILL_AR: begin
          if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) state_q <= DC_REFILL_R;
        end
        DC_REFILL_R: begin
          if (axi_req_o.r_ready & axi_rsp_i.r_valid) begin
            // On the critical beat of a store-miss, merge store bytes.
            for (int b = 0; b < 8; b++) begin
              if ((beat_cnt_q == 4'd0) & miss_was_store_q & miss_store_strobes_q[b])
                data_q[victim_q][miss_set_q][miss_beat_q + beat_cnt_q[BEAT_IDX_W-1:0]][b*8 +: 8]
                  <= miss_store_data_q[b*8 +: 8];
              else
                data_q[victim_q][miss_set_q][miss_beat_q + beat_cnt_q[BEAT_IDX_W-1:0]][b*8 +: 8]
                  <= axi_rsp_i.r.data[b*8 +: 8];
            end
            // CWF: bypass first beat ONLY for loads (not store-miss).
            if ((beat_cnt_q == 4'd0) & ~miss_was_store_q) begin
              bypass_valid_q <= 1'b1;
              bypass_data_q  <= axi_rsp_i.r.data;
            end
            beat_cnt_q <= beat_cnt_q + 4'd1;
            if (axi_rsp_i.r.last) begin
              tag_q[miss_set_q][victim_q]   <= miss_tag_q;
              valid_q[miss_set_q][victim_q] <= 1'b1;
              dirty_q[miss_set_q][victim_q] <= miss_was_store_q;
              plru_q[miss_set_q]            <= plru_update(plru_q[miss_set_q], victim_q);
              if (miss_was_store_q) store_done_q <= 1'b1;
              miss_was_store_q <= 1'b0;
              if (amo_pending_q) begin
                // Capture the refilled critical-word beat as the AMO old value.
                amo_old_val_q <= bypass_data_q;
                state_q       <= DC_AMO_RMW;
              end else begin
                state_q <= DC_IDLE;
              end
            end
          end
        end
        DC_WB_AW: begin
          if (axi_req_o.aw_valid & axi_rsp_i.aw_ready) state_q <= DC_WB_W;
        end
        DC_WB_W: begin
          if (axi_req_o.w_valid & axi_rsp_i.w_ready) begin
            wb_beat_cnt_q <= wb_beat_cnt_q + 4'd1;
            if (axi_req_o.w.last) begin
              state_q <= DC_REFILL_AR;
            end
          end
        end
        DC_AMO_RMW: begin
          // Compute new value, write to RAM with byte strobes, set dirty,
          // capture old value, return to IDLE.
          for (int w = 0; w < NUM_WAYS; w++) begin
            if (w[$clog2(NUM_WAYS)-1:0] == victim_q) begin
              for (int b = 0; b < 8; b++) begin
                data_q[w][miss_set_q][miss_beat_q][b*8 +: 8] <=
                  amo_be[b] ? amo_aligned[b*8 +: 8]
                            : amo_cur_beat[b*8 +: 8];
              end
            end
          end
          dirty_q[miss_set_q][victim_q] <= 1'b1;
          amo_done_q     <= 1'b1;
          amo_pending_q  <= 1'b0;
          state_q        <= DC_IDLE;
        end
        DC_FLUSH_SCAN: begin
          // Walk (set, way).  Dirty → writeback path; clean → just
          // invalidate and advance.  When the walk completes, pulse
          // flush_done_q for one cycle and return to DC_IDLE.
          if (valid_q[flush_set_q][flush_way_q] &
              dirty_q[flush_set_q][flush_way_q]) begin
            // Reuse the writeback registers — no other transaction is
            // active during a flush walk.
            miss_set_q    <= flush_set_q;
            victim_q      <= flush_way_q;
            evict_tag_q   <= tag_q[flush_set_q][flush_way_q];
            wb_beat_cnt_q <= 4'd0;
            state_q       <= DC_FLUSH_AW;
          end else begin
            // Clean or invalid line: just invalidate and advance.
            valid_q[flush_set_q][flush_way_q] <= 1'b0;
            if (flush_way_q == ($clog2(NUM_WAYS))'(NUM_WAYS - 1)) begin
              flush_way_q <= '0;
              if (flush_set_q == SET_IDX_W'(NUM_SETS - 1)) begin
                flush_done_q <= 1'b1;
                state_q      <= DC_IDLE;
              end else begin
                flush_set_q <= flush_set_q + 1'b1;
              end
            end else begin
              flush_way_q <= flush_way_q + 1'b1;
            end
          end
        end
        DC_FLUSH_AW: begin
          if (axi_req_o.aw_valid & axi_rsp_i.aw_ready) state_q <= DC_FLUSH_W;
        end
        DC_FLUSH_W: begin
          if (axi_req_o.w_valid & axi_rsp_i.w_ready) begin
            wb_beat_cnt_q <= wb_beat_cnt_q + 4'd1;
            if (axi_req_o.w.last) begin
              // Done writing this dirty line.  Invalidate + clear dirty,
              // then advance the (set, way) walk.
              dirty_q[flush_set_q][flush_way_q] <= 1'b0;
              valid_q[flush_set_q][flush_way_q] <= 1'b0;
              if (flush_way_q == ($clog2(NUM_WAYS))'(NUM_WAYS - 1)) begin
                flush_way_q <= '0;
                if (flush_set_q == SET_IDX_W'(NUM_SETS - 1)) begin
                  flush_done_q <= 1'b1;
                  state_q      <= DC_IDLE;
                end else begin
                  flush_set_q <= flush_set_q + 1'b1;
                  state_q     <= DC_FLUSH_SCAN;
                end
              end else begin
                flush_way_q <= flush_way_q + 1'b1;
                state_q     <= DC_FLUSH_SCAN;
              end
            end
          end
        end
        default: state_q <= DC_IDLE;
      endcase
    end
  end

  // ---- AXI request driver (combinational) -----------------------------------
  always_comb begin
    axi_req_o = '0;
    // Read channel: refill AR/R
    axi_req_o.ar.addr  = {miss_tag_q, miss_set_q, miss_beat_q, 3'b000};
    axi_req_o.ar.size  = 3'b011;
    axi_req_o.ar.len   = 8'd7;
    axi_req_o.ar.burst = axi_pkg::BURST_WRAP;
    axi_req_o.ar.id    = '0;
    axi_req_o.ar_valid = (state_q == DC_REFILL_AR);
    axi_req_o.r_ready  = (state_q == DC_REFILL_R);

    // Write channel: dirty-eviction AW/W/B (line-aligned address)
    axi_req_o.aw.addr  = {{(PHYS_ADDR_W - TAG_W - SET_IDX_W - OFFSET_W){1'b0}},
                          evict_tag_q, miss_set_q, {OFFSET_W{1'b0}}};
    axi_req_o.aw.size  = 3'b011;
    axi_req_o.aw.len   = 8'd7;
    axi_req_o.aw.burst = axi_pkg::BURST_INCR;
    axi_req_o.aw.id    = '0;
    axi_req_o.aw_valid = (state_q == DC_WB_AW) | (state_q == DC_FLUSH_AW);

    axi_req_o.w.data   = data_q[victim_q][miss_set_q][wb_beat_cnt_q[BEAT_IDX_W-1:0]];
    axi_req_o.w.strb   = 8'hFF;
    axi_req_o.w.last   = (wb_beat_cnt_q == 4'd7);
    axi_req_o.w_valid  = (state_q == DC_WB_W) | (state_q == DC_FLUSH_W);

    axi_req_o.b_ready  = 1'b1;     // always accept B response
  end

  // ---- AMO combinational datapath -------------------------------------------
  always_comb begin
    amo_cur_beat = data_q[victim_q][miss_set_q][miss_beat_q];
    amo_result   = amo_compute(amo_op_q, amo_old_val_q, amo_src_q, amo_is_word_q);
    amo_be       = amo_is_word_q
                     ? store_strobes(3'd2, amo_addr_off_q)
                     : 8'hFF;
    amo_aligned  = amo_is_word_q
                     ? store_data_aligned(3'd2, amo_addr_off_q, amo_result)
                     : amo_result;
  end

  // ---- Hit data path (way-select, full 64-bit beat) -------------------------
  logic [63:0] hit_beat;
  logic [63:0] beat_for_load;
  always_comb begin
    hit_beat = '0;
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh[w]) hit_beat = data_q[w][set_idx][beat_idx];
    end
    beat_for_load = bypass_valid_q ? bypass_data_q : hit_beat;
  end

  // ---- Size/sign extension on loads ----------------------------------------
  logic [63:0] load_data_full;
  always_comb begin
    load_data_full = beat_for_load;
    unique case (size_i)
      3'd0: begin     // byte (zero-extended)
        unique case (addr_i[2:0])
          3'd0: load_data_full = {56'b0, beat_for_load[ 7: 0]};
          3'd1: load_data_full = {56'b0, beat_for_load[15: 8]};
          3'd2: load_data_full = {56'b0, beat_for_load[23:16]};
          3'd3: load_data_full = {56'b0, beat_for_load[31:24]};
          3'd4: load_data_full = {56'b0, beat_for_load[39:32]};
          3'd5: load_data_full = {56'b0, beat_for_load[47:40]};
          3'd6: load_data_full = {56'b0, beat_for_load[55:48]};
          3'd7: load_data_full = {56'b0, beat_for_load[63:56]};
          default: load_data_full = beat_for_load;
        endcase
      end
      3'd1: begin     // halfword (zero-extended)
        unique case (addr_i[2:1])
          2'd0: load_data_full = {48'b0, beat_for_load[15: 0]};
          2'd1: load_data_full = {48'b0, beat_for_load[31:16]};
          2'd2: load_data_full = {48'b0, beat_for_load[47:32]};
          2'd3: load_data_full = {48'b0, beat_for_load[63:48]};
          default: load_data_full = beat_for_load;
        endcase
      end
      3'd2: begin     // word (zero-extended)
        load_data_full = addr_i[2] ? {32'b0, beat_for_load[63:32]}
                                    : {32'b0, beat_for_load[31: 0]};
      end
      default: load_data_full = beat_for_load;     // double
    endcase
  end

  // ---- Outputs --------------------------------------------------------------
  assign data_valid_o = hit | bypass_valid_q | store_done_q | amo_done_q;
  assign rdata_o      = amo_done_q ? amo_old_val_q : load_data_full;
  assign sc_success_o = sc_success_q;
  assign stall_o      = (state_q != DC_IDLE);
  assign miss_pulse_o = miss_pulse_q;

  logic _unused;
  assign _unused = ^{miss_store_off_q};

endmodule
