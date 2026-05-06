// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_dcache.sv — data cache.
//
// 16 KB, 4-way set-associative, 64-byte lines, Tree-PLRU replacement,
// write-back / write-allocate, critical-word-first refill via AXI WRAP
// burst, dirty-line writeback via AXI INCR burst.  AMO RMW and LR/SC
// reservation tracking live inside the cache.
//
// Per-way data arrays are 4 x kronos_ram (one per way); tag/valid/dirty/
// PLRU/FSM state stay in flops.  The LSU's same-cycle hit response is
// preserved by pre-launching the BRAM read in EX with the dTLB-translated
// PA via the early_req_valid_i / early_addr_i ports.
//
// See docs/superpowers/specs/2026-04-27-dcache-design.md and
//     docs/superpowers/specs/2026-05-01-stage6g-dcache-bram-design.md.
module kronos_dcache
  import kronos_pkg::*;
#(
  parameter int unsigned CACHE_BYTES = 16*1024,
  parameter int unsigned NUM_WAYS    = 4,
  parameter int unsigned LINE_BYTES  = 64,
  parameter int unsigned PHYS_ADDR_W = 64,
  // PMA: non-cacheable region list. Default matches issue #67 (0x4000_0000-0x4FFF_FFFF).
  parameter int unsigned NUM_NC_REGIONS = 1,
  parameter logic [kronos_pkg::XLEN-1:0] NC_REGION_BASE  [NUM_NC_REGIONS] = '{kronos_pkg::MMIO_BASE},
  parameter logic [kronos_pkg::XLEN-1:0] NC_REGION_LIMIT [NUM_NC_REGIONS] = '{64'h0000_0000_4FFF_FFFF}
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // LSU side
  input  logic                   req_i,
  input  logic [PHYS_ADDR_W-1:0] addr_i,
  input  logic [2:0]             size_i,
  input  logic                   we_i,
  input  logic [kronos_pkg::XLEN-1:0]        wdata_i,
  input  logic                   amo_req_i,
  input  logic [4:0]             amo_op_i,
  input  logic                   rsrv_clear_i,
  output logic                   data_valid_o,
  output logic [kronos_pkg::XLEN-1:0]        rdata_o,
  output logic                   sc_success_o,
  output logic                   stall_o,

  // EX-stage pre-launch port. The dTLB exposes the translated PA
  // combinationally in EX; this port lets the dcache fire the BRAM read
  // one cycle ahead of the MEM-stage req_i so ram_rdata is registered
  // exactly when the MEM stage consumes it.
  input  logic                   early_req_valid_i,
  input  logic [PHYS_ADDR_W-1:0] early_addr_i,

  // PTW priority request port (preempts LSU when ptw_req_valid_i=1)
  input  logic                   ptw_req_valid_i,
  input  logic [55:0]            ptw_req_addr_i,
  input  logic                   ptw_req_we_i,
  input  logic [kronos_pkg::XLEN-1:0]        ptw_req_wdata_i,
  input  logic                   ptw_req_is_lr_i,
  input  logic                   ptw_req_is_sc_i,
  output logic                   ptw_rsp_valid_o,
  output logic [kronos_pkg::XLEN-1:0]        ptw_rsp_rdata_o,
  output logic                   ptw_rsp_sc_ok_o,

  // FENCE.I full flush: writeback every dirty line and invalidate.  Hold
  // flush_i high until flush_done_o pulses for one cycle.
  input  logic                   flush_i,
  output logic                   flush_done_o,
  output logic                   dirty_pending_o,

  // AXI4 master (read + write)
  output kronos_axi_req_t        axi_req_o,
  input  kronos_axi_resp_t       axi_rsp_i,

  // PMA fault outputs — routed to access-fault trap path in kronos_top.
  output logic                   amo_nc_fault_o,
  output logic                   bus_err_fault_o,
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
  localparam int unsigned RAM_DEPTH   = NUM_SETS * BEATS;
  localparam int unsigned RAM_ADDR_W  = $clog2(RAM_DEPTH);

  // ---- Types ---------------------------------------------------------------
  typedef enum logic [3:0] {
    DC_IDLE       = 4'b0000,
    DC_REFILL_AR  = 4'b0001,
    DC_REFILL_R   = 4'b0010,
    DC_WB_AW      = 4'b0011,
    DC_WB_W       = 4'b0100,
    DC_AMO_RMW    = 4'b0101,
    DC_FLUSH_SCAN = 4'b0110,
    DC_FLUSH_AW   = 4'b0111,
    DC_FLUSH_W    = 4'b1000,
    // non-cacheable bypass path
    DC_NC_AR      = 4'b1001,
    DC_NC_R       = 4'b1010,
    DC_NC_AW      = 4'b1011,
    DC_NC_W       = 4'b1100,
    DC_NC_B       = 4'b1101,
    // PTW hit lookup wait cycle (BRAM read latency)
    DC_PTW_LOOKUP = 4'b1110
  } dcache_state_e;

  // ---- State registers (driven by always_ff) -------------------------------
  // Storage arrays. data_q lives in 4 x kronos_ram (gen_data_ram below) and
  // tag_q lives in 4 x kronos_ram (gen_tag_ram below); valid/dirty/PLRU stay
  // in flops to preserve single-cycle FENCE.I and store-hit dirty updates.
  logic             valid_q [NUM_SETS][NUM_WAYS];
  logic             dirty_q [NUM_SETS][NUM_WAYS];
  logic [2:0]       plru_q  [NUM_SETS];

  // Top-level FSM state
  dcache_state_e state_q;

  // Miss-pulse pipeline register (perf counter event)
  logic miss_pulse_q;

  // Miss FSM state regs
  logic [SET_IDX_W-1:0]            miss_set_q;
  logic [TAG_W-1:0]                miss_tag_q;
  logic [BEAT_IDX_W-1:0]           miss_beat_q;
  logic [$clog2(NUM_WAYS)-1:0]     victim_q;
  logic [3:0]                      beat_cnt_q;
  logic                            bypass_valid_q;
  logic [kronos_pkg::XLEN-1:0]                 bypass_data_q;
  logic                            miss_was_store_q;
  logic [kronos_pkg::XLEN-1:0]                 miss_store_data_q;
  logic [kronos_pkg::XLEN_BYTES-1:0]           miss_store_strobes_q;
  logic [2:0]                      miss_store_off_q;
  logic                            store_done_q;
  logic [3:0]                      wb_beat_cnt_q;
  logic [TAG_W-1:0]                evict_tag_q;

  // NC bypass — captured at IDLE entry; used to drive AR/AW/W and
  // the load extension on R.
  logic [PHYS_ADDR_W-1:0] nc_addr_q;
  logic [2:0]             nc_size_q;
  logic                   nc_we_q;
  logic [kronos_pkg::XLEN-1:0]        nc_wdata_q;
  logic                   nc_is_ptw_q;     // routes the response back to PTW

  // NC read response — captured one cycle in DC_NC_R; used by the
  // load-extension mux for one cycle.
  logic            nc_rsp_valid_q;
  logic [kronos_pkg::XLEN-1:0] nc_rsp_data_q;
  logic         nc_rsp_err_q;     // r.resp != OKAY captured at the same time

  // NC write completion — pulses for one cycle when B arrives.
  logic nc_b_done_q;
  logic nc_b_err_q;

  // AMO state registers
  logic            amo_pending_q;
  logic [4:0]      amo_op_q;
  logic [kronos_pkg::XLEN-1:0] amo_src_q;
  logic [kronos_pkg::XLEN-1:0] amo_old_val_q;
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
  // flush_tag_settled_q: 1 iff tag_rdata_eff currently reflects flush_set_q.
  // Cleared on every entry to DC_FLUSH_SCAN and on every flush_set_q change;
  // set on the next cycle, after the BRAM read launched at flush_set_q has
  // landed. Used to stall the FLUSH_SCAN body for one bubble cycle per set.
  logic                              flush_tag_settled_q;

  // track which port owns the in-flight (multi-cycle) request so
  // responses produced after the request cycle (refill bypass, store_done,
  // amo_done, sc_success) can be routed back to the originator.  For
  // same-cycle hits the response routing uses ptw_active directly; for
  // delayed responses (state_q != IDLE during request acceptance) we use
  // the latched bit.
  logic in_flight_is_ptw_q;

  // 1-deep RAW bypass: tracks the previous cycle's BRAM port-A write so
  // that a same-line / same-beat / same-way load presented this cycle can
  // merge in the just-written bytes — port B's "no_change" mode (the only
  // collision mode RAMB36/RAMB18 SDP supports) leaves rdata stale on
  // same-address write+read collisions. Covers two paths: store-hit→load
  // back-to-back, and last-refill-beat→load on the cycle after refill
  // completes.
  logic [NUM_WAYS-1:0]                       prev_write_way_oh_q;
  logic [RAM_ADDR_W-1:0]                     prev_write_addr_q;
  logic [kronos_pkg::XLEN-1:0]               prev_write_data_q;
  logic [kronos_pkg::XLEN_BYTES-1:0]         prev_write_mask_q;
  logic                                      prev_write_active_q;
  // 2-deep RAW bypass tier — needed in the MEM1/MEM2 split because the LD's
  // pre-launch ram_re fires the same cycle the SD's ram_we commits. With
  // WRITE_MODE_B="no_change" the LD's ram_rdata captures stale data and the
  // 1-deep tier is consumed by the next instruction's pre-launch before the
  // LD reaches MEM2. Keeping a 2-cycle history covers the SD-NOP-LD case.
  logic [NUM_WAYS-1:0]                       prev2_write_way_oh_q;
  logic [RAM_ADDR_W-1:0]                     prev2_write_addr_q;
  logic [kronos_pkg::XLEN-1:0]               prev2_write_data_q;
  logic [kronos_pkg::XLEN_BYTES-1:0]         prev2_write_mask_q;
  logic                                      prev2_write_active_q;

  // PTW hit lookup state — captured at DC_IDLE entry on a PTW hit so that
  // DC_PTW_LOOKUP can way-mux ram_rdata[ptw_lookup_way_q] as the response.
  // ram_rdata itself was registered the cycle before from the PTW PA's
  // pre-launch in DC_IDLE, so no extra raddr capture is needed.
  logic [$clog2(NUM_WAYS)-1:0]     ptw_lookup_way_q;

  // ---- Combinational signals ------------------------------------------------
  // PTW vs LSU arbitration (effective request signals)
  logic                   eff_req_valid;
  logic [PHYS_ADDR_W-1:0] eff_req_addr;
  logic                   eff_req_we;
  logic [kronos_pkg::XLEN-1:0]        eff_req_wdata;
  logic                   eff_req_is_lr;
  logic                   eff_req_is_sc;
  logic [2:0]             eff_req_size;
  logic                   eff_amo_req;
  logic [4:0]             eff_amo_op;
  logic                   ptw_active;

  // PMA classification of the effective request address
  logic is_uncacheable;

  // Address slicing of the effective request address
  logic [SET_IDX_W-1:0]  set_idx;
  logic [TAG_W-1:0]      tag_in;
  logic [BEAT_IDX_W-1:0] beat_idx;

  // Hit detection
  logic [NUM_WAYS-1:0] hit_way_oh;
  logic                hit;

  // Miss-event (combinational predicate driving miss_pulse_q)
  logic miss_event;

  // Tree-PLRU victim selection
  logic [$clog2(NUM_WAYS)-1:0] victim_pick;

  // dirty_pending_o aggregation
  logic dirty_pending;

  // AMO intermediate signals for DC_AMO_RMW
  logic [kronos_pkg::XLEN-1:0]       amo_result;
  logic [kronos_pkg::XLEN_BYTES-1:0] amo_be;
  logic [kronos_pkg::XLEN-1:0]       amo_aligned;

  // hit_way_idx: binary encoding of hit way for AMO/SC use
  logic [$clog2(NUM_WAYS)-1:0] hit_way_idx;

  // hit_beat: full kronos_pkg::XLEN-wide beat from the hit way (way-mux on
  // ram_rdata).  Consumed both by the load-extension mux below and by the
  // AMO old-value capture inside the FSM.
  logic [kronos_pkg::XLEN-1:0] hit_beat;

  // Pre-computed strobes/aligned-data for store-hit and SC-success write
  // paths.
  logic [kronos_pkg::XLEN_BYTES-1:0] st_strobes;
  logic [kronos_pkg::XLEN-1:0]       st_aligned;
  logic [kronos_pkg::XLEN_BYTES-1:0] sc_strobes;
  logic [kronos_pkg::XLEN-1:0]       sc_aligned;

  // Hit data path: select between cache hit and refill bypass
  logic [kronos_pkg::XLEN-1:0] beat_for_load;

  // Inputs to load_data_full: prefer the in-flight NC request when active.
  logic [2:0] eff_size_for_load;
  logic [2:0] eff_off_for_load;

  // Size/sign extension on loads
  logic [kronos_pkg::XLEN-1:0] load_data_full;

  // Aggregate response signal (before LSU/PTW demux)
  logic            rsp_valid_int;
  logic [kronos_pkg::XLEN-1:0] rsp_rdata_int;
  logic            sc_success_int;

  // route the response to either LSU or PTW
  logic rsp_to_ptw;

  // ---- Per-way RAM interface signals (driven combinationally) --------------
  logic [NUM_WAYS-1:0]                       ram_we;
  logic [RAM_ADDR_W-1:0]                     ram_waddr;
  logic [kronos_pkg::XLEN-1:0]               ram_wdata;
  logic [kronos_pkg::XLEN_BYTES-1:0]         ram_wmask;
  logic                                      ram_re;
  logic [RAM_ADDR_W-1:0]                     ram_raddr;
  logic [kronos_pkg::XLEN-1:0]               ram_rdata [NUM_WAYS];

  // ---- Per-way TAG-RAM interface signals (driven combinationally) ----------
  // TAG_RAM_W is TAG_W zero-padded up to a byte multiple so kronos_ram's
  // BYTE_WIDTH=8 byte-write geometry is satisfied.
  localparam int unsigned TAG_RAM_W = ((TAG_W + 7) / 8) * 8;

  logic [NUM_WAYS-1:0]               tag_we;
  logic [SET_IDX_W-1:0]              tag_waddr;
  logic [TAG_RAM_W-1:0]              tag_wdata;
  logic                              tag_re;
  logic [SET_IDX_W-1:0]              tag_raddr;
  logic [TAG_RAM_W-1:0]              tag_rdata     [NUM_WAYS];
  logic [TAG_W-1:0]                  tag_rdata_eff [NUM_WAYS];   // post-RAW-bypass

  // 1-deep RAW bypass for refill-tag-write -> same-set read collision.
  // kronos_ram port-B "no_change" mode leaves rdata stale on a same-cycle
  // write+read at the same address; this register catches the just-written
  // tag for one cycle so the post-refill tag-compare sees the new value.
  logic                              prev_tag_write_q;
  logic [SET_IDX_W-1:0]              prev_tag_set_q;
  logic [NUM_WAYS-1:0]               prev_tag_way_oh_q;
  logic [TAG_W-1:0]                  prev_tag_data_q;

  // True for exactly one cycle on the refill-completion edge: the cycle on
  // which the new tag/valid/dirty bookkeeping commits.
  logic refill_complete_fire;

  // Refill beat-in-burst pointer (CWF wrap inside the line).
  logic [BEAT_IDX_W-1:0] refill_beat_in_burst;

  // Store-hit / SC-success / refill / AMO RMW write predicates (mutually
  // exclusive by FSM state).
  logic store_hit_fire;
  logic sc_hit_write_fire;
  logic refill_beat_write;
  logic amo_rmw_write_fire;

  // AXI W handshake / wb-last helpers used by the WB read pre-launch.
  logic axi_w_handshake;
  logic wb_last_beat;

  // Lint-only: tie off intentionally-read register
  logic _unused;

  // ==========================================================================
  // Functions (kept in-module so they can use parameters)
  // ==========================================================================
  function automatic logic [kronos_pkg::XLEN_BYTES-1:0] store_strobes(input logic [2:0] sz, input logic [2:0] off);
    case (sz)
      3'd0: return 8'b00000001 << off;
      3'd1: return 8'b00000011 << {off[2:1], 1'b0};
      3'd2: return 8'b00001111 << {off[2], 2'b00};
      3'd3: return 8'b11111111;
      default: return 8'b0;
    endcase
  endfunction

  function automatic logic [kronos_pkg::XLEN-1:0] store_data_aligned(
    input logic [2:0]      sz,
    input logic [2:0]      off,
    input logic [kronos_pkg::XLEN-1:0] data
  );
    logic [kronos_pkg::XLEN-1:0] r;
    logic _unused_off;
    // store_strobes() consumes off; store_data_aligned() replicates the
    // payload across all byte lanes so the strobes select the right one.
    _unused_off = ^off;
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
  function automatic logic [kronos_pkg::XLEN-1:0] amo_compute(
    input logic [4:0]      funct5,
    input logic [kronos_pkg::XLEN-1:0] old_val,
    input logic [kronos_pkg::XLEN-1:0] src_val,
    input logic            is_word
  );
    logic [kronos_pkg::XLEN-1:0] a;
    logic [kronos_pkg::XLEN-1:0] b;
    logic [kronos_pkg::XLEN-1:0] r;
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

  // ==========================================================================
  // PTW vs LSU request arbitration
  // ==========================================================================
  // PTW always wins.  When ptw_req_valid_i is high, the dcache services the
  // PTW request; otherwise it falls through to the LSU port unchanged.  The
  // FSM, hit logic, and reservation tracking all read eff_* signals instead
  // of the raw LSU inputs.  PTW issues 8B accesses (size=3'd3) and uses
  // is_lr/is_sc for atomic A/D updates; non-LR/SC PTW requests go through
  // the normal load/store path (amo_req=0).
  assign ptw_active = ptw_req_valid_i;

  always_comb begin
    // Defaults (R7).
    eff_req_valid = 1'b0;
    eff_req_addr  = {PHYS_ADDR_W{1'b0}};
    eff_req_we    = 1'b0;
    eff_req_wdata = {kronos_pkg::XLEN{1'b0}};
    eff_req_is_lr = 1'b0;
    eff_req_is_sc = 1'b0;
    eff_req_size  = 3'd0;
    if (ptw_active) begin
      eff_req_valid = 1'b1;
      // PTW addresses are 56b (Sv39 PA); zero-extend to PHYS_ADDR_W.
      eff_req_addr  = {{(PHYS_ADDR_W-56){1'b0}}, ptw_req_addr_i};
      eff_req_we    = ptw_req_we_i;
      eff_req_wdata = ptw_req_wdata_i;
      eff_req_is_lr = ptw_req_is_lr_i;
      eff_req_is_sc = ptw_req_is_sc_i;
      eff_req_size  = 3'd3;
    end else begin
      eff_req_valid = req_i;
      eff_req_addr  = addr_i;
      eff_req_we    = we_i;
      eff_req_wdata = wdata_i;
      // LSU uses amo_op_i directly; LR=5'b00010, SC=5'b00011.
      eff_req_is_lr = amo_req_i & (amo_op_i == 5'b00010);
      eff_req_is_sc = amo_req_i & (amo_op_i == 5'b00011);
      eff_req_size  = size_i;
    end
  end

  // Synthesise an effective amo_req / amo_op for the FSM.  PTW only issues
  // plain D/W requests or LR/SC; never the wider funct5 AMO ops.  The LSU
  // uses amo_req_i / amo_op_i directly when ptw_active is low.
  always_comb begin
    // Defaults (R7).
    eff_amo_req = 1'b0;
    eff_amo_op  = 5'b0;
    if (ptw_active) begin
      eff_amo_req = ptw_req_is_lr_i | ptw_req_is_sc_i;
      eff_amo_op  = ptw_req_is_lr_i ? 5'b00010
                  : ptw_req_is_sc_i ? 5'b00011
                                    : 5'b0;
    end else begin
      eff_amo_req = amo_req_i;
      eff_amo_op  = amo_op_i;
    end
  end

  // ==========================================================================
  // PMA decoder
  // ==========================================================================
  // Combinational classifier — runs on eff_req_addr so it works for both LSU
  // and PTW paths. Cost: 2 * NUM_NC_REGIONS magnitude compares + OR-tree.
  always_comb begin
    is_uncacheable = 1'b0;
    for (int r = 0; r < NUM_NC_REGIONS; r++) begin
      if ((eff_req_addr >= NC_REGION_BASE[r]) &&
          (eff_req_addr <= NC_REGION_LIMIT[r])) is_uncacheable = 1'b1;
    end
  end

  // ==========================================================================
  // Address breakdown
  // ==========================================================================
  assign set_idx  = eff_req_addr[SET_IDX_W + OFFSET_W - 1 : OFFSET_W];
  assign tag_in   = eff_req_addr[PHYS_ADDR_W-1 : SET_IDX_W + OFFSET_W];
  assign beat_idx = eff_req_addr[OFFSET_W-1 : 3];

  // ==========================================================================
  // Hit logic
  // ==========================================================================
  always_comb begin
    hit_way_oh = {NUM_WAYS{1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      hit_way_oh[w] = eff_req_valid & valid_q[set_idx][w] & (tag_rdata_eff[w] == tag_in);
    end
    hit = |hit_way_oh;
  end

  assign miss_event = eff_req_valid & ~hit & (state_q == DC_IDLE);

  // Tree-PLRU victim selection (same as I$).
  always_comb begin
    victim_pick = {$clog2(NUM_WAYS){1'b0}};
    unique case (plru_q[set_idx][2])
      1'b0: victim_pick = plru_q[set_idx][1] ? 2'd1 : 2'd0;
      1'b1: victim_pick = plru_q[set_idx][0] ? 2'd3 : 2'd2;
      default: victim_pick = {$clog2(NUM_WAYS){1'b0}};
    endcase
  end

  // dirty_pending_o: 1 if any (set, way) has valid && dirty.  Used by the
  // top to short-circuit FENCE.I when no writeback is required.
  always_comb begin
    dirty_pending = 1'b0;
    for (int s = 0; s < NUM_SETS; s++)
      for (int w = 0; w < NUM_WAYS; w++)
        dirty_pending |= valid_q[s][w] & dirty_q[s][w];
  end
  assign dirty_pending_o = dirty_pending;
  assign flush_done_o    = flush_done_q;

  // hit_way_idx: binary encoding of hit way for AMO/SC use
  always_comb begin
    hit_way_idx = {$clog2(NUM_WAYS){1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh[w]) hit_way_idx = w[$clog2(NUM_WAYS)-1:0];
    end
  end

  // hit_beat: full 64-bit beat from the hit way, sourced from the registered
  // ram_rdata array (populated by the EX-stage pre-launch one cycle earlier).
  // Includes the 1-deep RAW bypass: when the previous cycle had a port-A
  // write to the same {way, set, beat}, byte-merge the prev cycle's
  // wdata over ram_rdata for the strobed bytes — port B's "no_change"
  // mode left ram_rdata stale on that collision.
  always_comb begin
    hit_beat = {kronos_pkg::XLEN{1'b0}};
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (hit_way_oh[w]) begin
        hit_beat = ram_rdata[w];
        // Apply older (2-deep) tier first; newer (1-deep) tier overrides
        // per-byte for the freshest value.
        if (prev2_write_active_q & prev2_write_way_oh_q[w] &
            (prev2_write_addr_q == {set_idx, beat_idx})) begin
          for (int b = 0; b < kronos_pkg::XLEN_BYTES; b++) begin
            if (prev2_write_mask_q[b]) begin
              hit_beat[b*8 +: 8] = prev2_write_data_q[b*8 +: 8];
            end
          end
        end
        if (prev_write_active_q & prev_write_way_oh_q[w] &
            (prev_write_addr_q == {set_idx, beat_idx})) begin
          for (int b = 0; b < kronos_pkg::XLEN_BYTES; b++) begin
            if (prev_write_mask_q[b]) begin
              hit_beat[b*8 +: 8] = prev_write_data_q[b*8 +: 8];
            end
          end
        end
      end
    end
  end

  // Pre-computed store/SC strobes and aligned-data — pure functions of the
  // effective request size/offset/wdata.
  always_comb begin
    st_strobes = store_strobes(eff_req_size, eff_req_addr[2:0]);
    st_aligned = store_data_aligned(eff_req_size, eff_req_addr[2:0], eff_req_wdata);
    sc_strobes = st_strobes;
    sc_aligned = st_aligned;
  end

  // ==========================================================================
  // BRAM data array (one kronos_ram per way)
  // ==========================================================================
  generate
    for (genvar gi = 0; gi < NUM_WAYS; gi++) begin : gen_data_ram
      kronos_ram #(
        .DEPTH        (RAM_DEPTH),
        .WIDTH        (kronos_pkg::XLEN),
        .BYTE_WIDTH   (8),
        // Vivado SDP block-RAM only allows "no_change" / "read_first" on
        // port B (RAMB36/RAMB18 hard limitation). Same-cycle store-then-
        // load to the same beat is handled by the 1-deep RAW bypass mux
        // below (prev_write_*_q on the hit-data path) — covers the two
        // collision paths: store-hit→load and last-refill-beat→load.
        .WRITE_MODE_B ("no_change")
      ) u_ram (
        .clk_i   (clk_i),
        .we_i    (ram_we[gi]),
        .waddr_i (ram_waddr),
        .wdata_i (ram_wdata),
        .wmask_i (ram_wmask),
        .re_i    (ram_re),
        .raddr_i (ram_raddr),
        .rdata_o (ram_rdata[gi])
      );
    end
  endgenerate

  // ==========================================================================
  // BRAM tag array (one kronos_ram per way)
  // ==========================================================================
  // Set-indexed tag store. Same WRITE_MODE_B="no_change" as the data RAM —
  // the refill→read collision is covered by the prev_tag_*_q 1-deep bypass.
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

  // tag_rdata_eff: strip the zero-pad and apply the 1-deep RAW bypass for
  // refill→same-set read collisions.
  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      tag_rdata_eff[w] = tag_rdata[w][TAG_W-1:0];
      if (prev_tag_write_q & (set_idx == prev_tag_set_q) & prev_tag_way_oh_q[w]) begin
        tag_rdata_eff[w] = prev_tag_data_q;
      end
    end
  end

  // True for one cycle: the refill-bookkeeping commit (last R beat accepted).
  // Drives the tag RAM write-enable and the prev_tag_*_q capture.
  assign refill_complete_fire = (state_q == DC_REFILL_R)
                              & axi_req_o.r_ready
                              & axi_rsp_i.r_valid
                              & axi_rsp_i.r.last;

  // Tag-RAM write side. Target way is victim_q on refill complete.
  always_comb begin
    tag_we    = {NUM_WAYS{1'b0}};
    tag_waddr = miss_set_q;
    tag_wdata = {{(TAG_RAM_W - TAG_W){1'b0}}, miss_tag_q};

    if (refill_complete_fire) begin
      for (int w = 0; w < NUM_WAYS; w++) begin
        if (w == int'(victim_q)) tag_we[w] = 1'b1;
      end
    end
  end

  // Tag-RAM read mux. Mirrors the data-RAM read priority chain but with
  // set-only addressing (no beat field). Default = LSU pre-launch from
  // EX-stage dTLB PA. Flush-walk states drive flush_set_q so the
  // FLUSH_SCAN body can capture evict_tag_q from tag_rdata_eff[flush_way_q].
  always_comb begin
    tag_re    = early_req_valid_i;
    tag_raddr = early_addr_i[OFFSET_W + SET_IDX_W - 1 : OFFSET_W];

    if ((state_q == DC_REFILL_R) | (state_q == DC_REFILL_AR)
        | (state_q == DC_AMO_RMW)) begin
      tag_re    = 1'b1;
      tag_raddr = eff_req_addr[OFFSET_W + SET_IDX_W - 1 : OFFSET_W];
    end else if ((state_q == DC_IDLE) & ptw_active) begin
      tag_re    = 1'b1;
      tag_raddr = eff_req_addr[OFFSET_W + SET_IDX_W - 1 : OFFSET_W];
    end else if (state_q == DC_FLUSH_SCAN) begin
      // Drive the tag read for the flush walk's current set; the FLUSH_SCAN
      // body captures evict_tag_q <= tag_rdata_eff[flush_way_q] one cycle
      // after the set was last changed (gated by flush_tag_settled_q).
      tag_re    = 1'b1;
      tag_raddr = flush_set_q;
    end else if ((state_q == DC_WB_AW) | (state_q == DC_WB_W)
               | (state_q == DC_FLUSH_AW) | (state_q == DC_FLUSH_W)) begin
      // Writeback walk: tag was already captured into evict_tag_q
      // (in IDLE for normal miss, in FLUSH_SCAN for flush walk); the tag
      // RAM is idle here. Keep tag_re low.
      tag_re    = 1'b0;
      tag_raddr = miss_set_q;
    end
  end

  // ==========================================================================
  // BRAM port-A: per-way write enables / write data / mask
  // ==========================================================================
  // Refill beat-in-burst (CWF wrap).
  assign refill_beat_in_burst = miss_beat_q + beat_cnt_q[BEAT_IDX_W-1:0];

  // Store-hit fires on the same cycle as the hit response, in DC_IDLE,
  // when the request is a plain store hitting a valid line and we are not
  // entering a flush, NC bypass, AMO, LR/SC, or refill path.  These
  // exclusions are captured by ANDing hit & eff_req_we & eff_req_valid &
  // ~eff_amo_req & ~eff_req_is_lr & ~eff_req_is_sc & ~is_uncacheable &
  // ~(flush_i & ~flush_done_q) & (state_q == DC_IDLE).
  always_comb begin
    store_hit_fire = (state_q == DC_IDLE)
                   & ~(flush_i & ~flush_done_q)
                   & eff_req_valid
                   & eff_req_we
                   & ~eff_amo_req
                   & ~eff_req_is_lr
                   & ~eff_req_is_sc
                   & ~is_uncacheable
                   & hit;
  end

  // SC-success write fires on a successful SC: reservation valid, address
  // matches, line hits, in DC_IDLE, not flushing.
  always_comb begin
    sc_hit_write_fire = (state_q == DC_IDLE)
                      & ~(flush_i & ~flush_done_q)
                      & eff_req_valid
                      & eff_amo_req
                      & (eff_amo_op == 5'b00011)
                      & ~is_uncacheable
                      & rsrv_valid_q
                      & (rsrv_addr_q == eff_req_addr)
                      & hit;
  end

  // Refill beat write — once per accepted R beat in DC_REFILL_R.
  assign refill_beat_write = (state_q == DC_REFILL_R)
                           & axi_req_o.r_ready & axi_rsp_i.r_valid;

  // AMO RMW write — single cycle in DC_AMO_RMW state.
  assign amo_rmw_write_fire = (state_q == DC_AMO_RMW);

  always_comb begin
    // Defaults: no write.
    ram_we    = {NUM_WAYS{1'b0}};
    ram_waddr = {RAM_ADDR_W{1'b0}};
    ram_wdata = {kronos_pkg::XLEN{1'b0}};
    ram_wmask = {kronos_pkg::XLEN_BYTES{1'b0}};

    unique case (1'b1)
      // Store-hit (DC_IDLE, same-cycle as req_i)
      store_hit_fire: begin
        for (int w = 0; w < NUM_WAYS; w++) begin
          ram_we[w] = hit_way_oh[w];
        end
        ram_waddr = {set_idx, beat_idx};
        ram_wdata = st_aligned;
        ram_wmask = st_strobes;
      end
      // SC-success (DC_IDLE)
      sc_hit_write_fire: begin
        for (int w = 0; w < NUM_WAYS; w++) begin
          ram_we[w] = hit_way_oh[w];
        end
        ram_waddr = {set_idx, beat_idx};
        ram_wdata = sc_aligned;
        ram_wmask = sc_strobes;
      end
      // Refill beat write (DC_REFILL_R)
      refill_beat_write: begin
        ram_we[victim_q] = 1'b1;
        ram_waddr = {miss_set_q, refill_beat_in_burst};
        // Critical-word merge for store-miss: byte-pick from
        // miss_store_data_q for strobed bytes, AXI data otherwise.
        for (int b = 0; b < kronos_pkg::XLEN_BYTES; b++) begin
          ram_wdata[b*8 +: 8] =
            ((beat_cnt_q == 4'd0) & miss_was_store_q & miss_store_strobes_q[b])
              ? miss_store_data_q[b*8 +: 8]
              : axi_rsp_i.r.data[b*8 +: 8];
        end
        ram_wmask = {kronos_pkg::XLEN_BYTES{1'b1}};
      end
      // AMO RMW (DC_AMO_RMW)
      amo_rmw_write_fire: begin
        ram_we[victim_q] = 1'b1;
        ram_waddr = {miss_set_q, miss_beat_q};
        ram_wdata = amo_aligned;
        ram_wmask = amo_be;
      end
      default: ;   // no write
    endcase
  end

  // ==========================================================================
  // BRAM port-B: pre-launch read address arbitration
  // ==========================================================================
  // Priority: writeback / flush-writeback > PTW lookup launch (in DC_IDLE
  // when ptw_active) > LSU pre-launch (default).  WB and PTW only override
  // during cycles in which the LSU is stalled anyway, so the LSU's
  // pre-launch is wasted with no IPC visible effect.
  assign axi_w_handshake = axi_req_o.w_valid & axi_rsp_i.w_ready;
  assign wb_last_beat    = (wb_beat_cnt_q == 4'd7);

  always_comb begin
    // Default: LSU pre-launch from EX-stage dTLB PA.
    ram_re    = early_req_valid_i;
    ram_raddr = early_addr_i[OFFSET_W + SET_IDX_W - 1 : 3];

    // Writeback / flush-writeback beat-0 pre-launch (free cycle in AW).
    if ((state_q == DC_WB_AW) | (state_q == DC_FLUSH_AW)) begin
      ram_re    = 1'b1;
      ram_raddr = {miss_set_q, {BEAT_IDX_W{1'b0}}};   // beat 0
    end else if ((state_q == DC_WB_W) | (state_q == DC_FLUSH_W)) begin
      // Pre-launch beat N+1 on the cycle beat N's W handshake completes.
      // ram_rdata holds the current beat across w_ready stalls because
      // ram_re stays low until the next handshake fires.
      ram_re    = axi_w_handshake & ~wb_last_beat;
      ram_raddr = {miss_set_q,
                   wb_beat_cnt_q[BEAT_IDX_W-1:0] + {{(BEAT_IDX_W-1){1'b0}}, 1'b1}};
    end else if ((state_q == DC_REFILL_R) | (state_q == DC_REFILL_AR)
               | (state_q == DC_AMO_RMW)) begin
      // Drive the BRAM read from the in-flight request's PA so ram_rdata is
      // populated when the FSM returns to DC_IDLE and the LSU consumes the
      // hit response.  The EX-stage pre-launch only fires for the
      // CURRENTLY-EX instruction; while a miss refill is in progress, the
      // EX-stage instruction is the one BEHIND the missing op (or a non-
      // memory op), so its pre-launch cannot keep ram_rdata fresh for the
      // missing op.  eff_req_addr tracks the current owner of the cache
      // (LSU's addr_i during a load/store miss, PTW's addr during a PTW
      // miss); this signal is stable across the refill because mem_stall
      // freezes ex_mem_q and the PTW latches its own request.
      ram_re    = 1'b1;
      ram_raddr = eff_req_addr[OFFSET_W + SET_IDX_W - 1 : 3];
    end else if ((state_q == DC_IDLE) & ptw_active) begin
      // PTW preempt in DC_IDLE: drive PTW's PA so ram_rdata is registered
      // for DC_PTW_LOOKUP next cycle.  Overrides LSU's pre-launch (LSU
      // is stalled anyway by ptw_active / state transitions).
      ram_re    = 1'b1;
      ram_raddr = eff_req_addr[OFFSET_W + SET_IDX_W - 1 : 3];
    end
  end

  // ==========================================================================
  // State machine — single always_ff drives the entire dcache FSM
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= DC_IDLE;
      miss_pulse_q   <= 1'b0;
      miss_set_q     <= {SET_IDX_W{1'b0}};
      miss_tag_q     <= {TAG_W{1'b0}};
      miss_beat_q    <= {BEAT_IDX_W{1'b0}};
      victim_q       <= {$clog2(NUM_WAYS){1'b0}};
      beat_cnt_q     <= 4'd0;
      bypass_valid_q       <= 1'b0;
      bypass_data_q        <= {kronos_pkg::XLEN{1'b0}};
      miss_was_store_q     <= 1'b0;
      miss_store_data_q    <= {kronos_pkg::XLEN{1'b0}};
      miss_store_strobes_q <= {kronos_pkg::XLEN_BYTES{1'b0}};
      miss_store_off_q     <= 3'b0;
      store_done_q         <= 1'b0;
      wb_beat_cnt_q        <= 4'd0;
      evict_tag_q          <= {TAG_W{1'b0}};
      amo_pending_q        <= 1'b0;
      amo_op_q             <= 5'b0;
      amo_src_q            <= {kronos_pkg::XLEN{1'b0}};
      amo_old_val_q        <= {kronos_pkg::XLEN{1'b0}};
      amo_done_q           <= 1'b0;
      amo_is_word_q        <= 1'b0;
      amo_addr_off_q       <= 3'b0;
      rsrv_addr_q          <= {PHYS_ADDR_W{1'b0}};
      rsrv_valid_q         <= 1'b0;
      sc_success_q         <= 1'b0;
      flush_set_q          <= {SET_IDX_W{1'b0}};
      flush_way_q          <= {$clog2(NUM_WAYS){1'b0}};
      flush_done_q         <= 1'b0;
      flush_tag_settled_q  <= 1'b0;
      in_flight_is_ptw_q   <= 1'b0;
      nc_addr_q            <= {PHYS_ADDR_W{1'b0}};
      nc_size_q            <= 3'b0;
      nc_we_q              <= 1'b0;
      nc_wdata_q           <= {kronos_pkg::XLEN{1'b0}};
      nc_is_ptw_q          <= 1'b0;
      nc_rsp_valid_q       <= 1'b0;
      nc_rsp_data_q        <= {kronos_pkg::XLEN{1'b0}};
      nc_rsp_err_q         <= 1'b0;
      nc_b_done_q          <= 1'b0;
      nc_b_err_q           <= 1'b0;
      ptw_lookup_way_q     <= {$clog2(NUM_WAYS){1'b0}};
      prev_write_way_oh_q  <= {NUM_WAYS{1'b0}};
      prev_write_addr_q    <= {RAM_ADDR_W{1'b0}};
      prev_write_data_q    <= {kronos_pkg::XLEN{1'b0}};
      prev_write_mask_q    <= {kronos_pkg::XLEN_BYTES{1'b0}};
      prev_write_active_q  <= 1'b0;
      prev2_write_way_oh_q <= {NUM_WAYS{1'b0}};
      prev2_write_addr_q   <= {RAM_ADDR_W{1'b0}};
      prev2_write_data_q   <= {kronos_pkg::XLEN{1'b0}};
      prev2_write_mask_q   <= {kronos_pkg::XLEN_BYTES{1'b0}};
      prev2_write_active_q <= 1'b0;
      prev_tag_write_q     <= 1'b0;
      prev_tag_set_q       <= {SET_IDX_W{1'b0}};
      prev_tag_way_oh_q    <= {NUM_WAYS{1'b0}};
      prev_tag_data_q      <= {TAG_W{1'b0}};
      for (int s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= 3'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          valid_q[s][w] <= 1'b0;
          dirty_q[s][w] <= 1'b0;
        end
      end
      // No data_q / tag_q reset — BRAM contents are don't-care at reset;
      // valid_q is the source of truth for "is this address readable".
    end else begin
      miss_pulse_q   <= miss_event;
      bypass_valid_q <= 1'b0;
      store_done_q   <= 1'b0;
      amo_done_q     <= 1'b0;
      sc_success_q   <= 1'b0;
      flush_done_q   <= 1'b0;     // default: one-cycle pulse
      // Capture this cycle's BRAM port-A write for the next cycle's
      // RAW-bypass hit-data mux. ram_we is the per-way OR of every
      // write predicate (store-hit / SC / refill / AMO RMW); when none
      // fire, prev_write_active_q clears.
      prev_write_active_q <= |ram_we;
      prev_write_way_oh_q <= ram_we;
      prev_write_addr_q   <= ram_waddr;
      prev_write_data_q   <= ram_wdata;
      prev_write_mask_q   <= ram_wmask;
      // 2-deep tier: shift the prior cycle's snapshot one stage further so
      // an LD that reaches MEM2 two cycles after an SD's commit still gets
      // the bypassed bytes. Required by the MEM1/MEM2 split — the LD's
      // pre-launch fires the cycle the SD writes BRAM, so ram_rdata is
      // stale by an extra cycle vs. the 7b single-MEM pipeline.
      prev2_write_active_q <= prev_write_active_q;
      prev2_write_way_oh_q <= prev_write_way_oh_q;
      prev2_write_addr_q   <= prev_write_addr_q;
      prev2_write_data_q   <= prev_write_data_q;
      prev2_write_mask_q   <= prev_write_mask_q;
      // 1-deep RAW bypass for the tag RAM: capture the tag write that fires
      // this cycle so the next cycle's tag-compare sees the new value
      // (xpm SDP "no_change" returns the OLD tag on a same-cycle write+read).
      prev_tag_write_q <= refill_complete_fire;
      if (refill_complete_fire) begin
        prev_tag_set_q    <= miss_set_q;
        prev_tag_way_oh_q <= {NUM_WAYS{1'b0}};
        for (int w = 0; w < NUM_WAYS; w++) begin
          if (w == int'(victim_q)) prev_tag_way_oh_q[w] <= 1'b1;
        end
        prev_tag_data_q <= miss_tag_q;
      end
      // NC response/completion pulses — default-clear each cycle.
      nc_rsp_valid_q <= 1'b0;
      nc_b_done_q    <= 1'b0;
      nc_rsp_err_q   <= 1'b0;
      nc_b_err_q     <= 1'b0;
      // Latch the originator of any request that enters service (whether it
      // hits same-cycle or transitions to a multi-cycle path).  The latched
      // value drives delayed responses (refill bypass, store_done, amo_done,
      // sc_success) that fire in cycles after the request was sampled.
      if ((state_q == DC_IDLE) & eff_req_valid & ~(flush_i & ~flush_done_q)) begin
        in_flight_is_ptw_q <= ptw_active;
      end
      // Reservation tracking.
      // - LR sets it.
      // - SC clears it (regardless of success).
      // - Plain store to the SAME line clears it.
      // - rsrv_clear_i (trap) clears it.
      if (rsrv_clear_i) begin
        rsrv_valid_q <= 1'b0;
      end else if (eff_req_valid & eff_amo_req & (eff_amo_op == 5'b00010)) begin
        // LR: set reservation on the LR request.
        rsrv_addr_q  <= eff_req_addr;
        rsrv_valid_q <= 1'b1;
      end else if (eff_req_valid & eff_amo_req & (eff_amo_op == 5'b00011)) begin
        // SC: clear reservation regardless of success.
        rsrv_valid_q <= 1'b0;
      end else if (eff_req_valid & eff_req_we & ~eff_amo_req & rsrv_valid_q
                   & (rsrv_addr_q[PHYS_ADDR_W-1:OFFSET_W]
                      == eff_req_addr[PHYS_ADDR_W-1:OFFSET_W])) begin
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
            flush_set_q         <= {SET_IDX_W{1'b0}};
            flush_way_q         <= {$clog2(NUM_WAYS){1'b0}};
            flush_tag_settled_q <= 1'b0;   // bubble cycle for first BRAM read
            state_q             <= DC_FLUSH_SCAN;
          end else if (eff_req_valid & is_uncacheable) begin
            // PMA bypass — non-cacheable address; single-beat AXI.
            // Important: this arm fully owns the request when is_uncacheable
            // is high. The cacheable hit/miss path below is only reached when
            // ~is_uncacheable; otherwise an NC access whose completion is
            // being drained (nc_rsp_valid_q | nc_b_done_q high) would fall
            // through to the cacheable refill state and incorrectly start an
            // 8-beat WRAP burst against an MMIO address.
            if (~nc_rsp_valid_q & ~nc_b_done_q) begin
              // Fresh NC request: capture and transition.
              nc_addr_q   <= eff_req_addr;
              nc_size_q   <= eff_req_size;
              nc_we_q     <= eff_req_we;
              nc_wdata_q  <= eff_req_wdata;
              nc_is_ptw_q <= ptw_active;
              if (eff_amo_req | eff_req_is_lr | eff_req_is_sc) begin
                // AMO/LR/SC on NC → trap (amo_nc_fault_o fires combinationally).
                state_q <= DC_IDLE;
              end else if (eff_req_we) begin
                state_q <= DC_NC_AW;
              end else begin
                state_q <= DC_NC_AR;
              end
            end
            // else: stay in DC_IDLE while the previous NC completion drains.
          end else if (ptw_active & hit & ~eff_req_is_sc) begin
            // PTW read hit (plain load OR PTW LR) — capture the way and wait
            // one cycle for ram_rdata.  ram_re/ram_raddr were driven by the
            // PTW PA this cycle (see pre-launch arbitration), so the
            // registered ram_rdata holds the beat in DC_PTW_LOOKUP next
            // cycle.  PTW SC is intentionally excluded so it falls through
            // to the SC branch and acks same-cycle via sc_success_q.
            ptw_lookup_way_q  <= hit_way_idx;
            // Update PLRU on the PTW access (mirrors LSU hit behavior).
            plru_q[set_idx]   <= plru_update(plru_q[set_idx], hit_way_idx);
            state_q <= DC_PTW_LOOKUP;
          end else if (eff_req_valid & eff_amo_req & ~amo_pending_q & ~amo_done_q) begin
            if (eff_amo_op == 5'b00011) begin
              // SC: check reservation; if matched, write; else no-op.
              if (rsrv_valid_q & (rsrv_addr_q == eff_req_addr) & hit) begin
                // SC success on cached line.  BRAM write fires
                // combinationally via sc_hit_write_fire; FSM marks dirty
                // and returns the success ack.
                for (int w = 0; w < NUM_WAYS; w++) begin
                  if (hit_way_oh[w]) dirty_q[set_idx][w] <= 1'b1;
                end
                plru_q[set_idx] <= plru_update(plru_q[set_idx], hit_way_idx);
                sc_success_q    <= 1'b1;
                store_done_q    <= 1'b1;
              end else if (rsrv_valid_q & (rsrv_addr_q == eff_req_addr) & ~hit) begin
                // SC miss + match: write-allocate.
                miss_set_q           <= set_idx;
                miss_tag_q           <= tag_in;
                miss_beat_q          <= beat_idx;
                victim_q             <= victim_pick;
                beat_cnt_q           <= 4'd0;
                miss_was_store_q     <= 1'b1;
                miss_store_data_q    <= store_data_aligned(eff_req_size, eff_req_addr[2:0],
                                                           eff_req_wdata);
                miss_store_strobes_q <= store_strobes(eff_req_size, eff_req_addr[2:0]);
                miss_store_off_q     <= eff_req_addr[2:0];
                evict_tag_q          <= tag_rdata_eff[victim_pick];
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
            end else if (eff_amo_op == 5'b00010) begin
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
                evict_tag_q    <= tag_rdata_eff[victim_pick];
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
                // Capture for the AMO RMW state.  hit_beat sources from
                // ram_rdata via the way-mux (populated by the EX pre-launch
                // one cycle earlier).
                amo_pending_q  <= 1'b1;
                amo_op_q       <= eff_amo_op;
                amo_src_q      <= eff_req_wdata;
                amo_old_val_q  <= hit_beat;
                amo_is_word_q  <= (eff_req_size == 3'd2);
                amo_addr_off_q <= eff_req_addr[2:0];
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
                amo_op_q       <= eff_amo_op;
                amo_src_q      <= eff_req_wdata;
                amo_is_word_q  <= (eff_req_size == 3'd2);
                amo_addr_off_q <= eff_req_addr[2:0];
                evict_tag_q    <= tag_rdata_eff[victim_pick];
                wb_beat_cnt_q  <= 4'd0;
                if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                  state_q <= DC_WB_AW;
                end else begin
                  state_q <= DC_REFILL_AR;
                end
              end
            end
          end else begin
            // Plain load/store path.  Store-hit BRAM write fires
            // combinationally via store_hit_fire; the FSM only updates
            // dirty/PLRU here.
            if (hit & eff_req_we & eff_req_valid) begin
              for (int w = 0; w < NUM_WAYS; w++) begin
                if (hit_way_oh[w]) dirty_q[set_idx][w] <= 1'b1;
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
              miss_was_store_q     <= eff_req_we;
              miss_store_data_q    <= store_data_aligned(eff_req_size, eff_req_addr[2:0],
                                                         eff_req_wdata);
              miss_store_strobes_q <= store_strobes(eff_req_size, eff_req_addr[2:0]);
              miss_store_off_q     <= eff_req_addr[2:0];
              evict_tag_q          <= tag_rdata_eff[victim_pick];
              wb_beat_cnt_q        <= 4'd0;
              if (valid_q[set_idx][victim_pick] & dirty_q[set_idx][victim_pick]) begin
                state_q <= DC_WB_AW;
              end else begin
                state_q <= DC_REFILL_AR;
              end
            end
          end
        end
        DC_PTW_LOOKUP: begin
          // ram_rdata holds the PTW's beat (launched when entering this
          // state).  ptw_rsp_valid_o fires combinationally via rsp_valid_int
          // (see Outputs); just return to IDLE.
          state_q <= DC_IDLE;
        end
        DC_REFILL_AR: begin
          if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) state_q <= DC_REFILL_R;
        end
        DC_REFILL_R: begin
          if (axi_req_o.r_ready & axi_rsp_i.r_valid) begin
            // Refill BRAM write fires combinationally via refill_beat_write.
            // CWF: bypass first beat ONLY for loads (not store-miss).
            if ((beat_cnt_q == 4'd0) & ~miss_was_store_q) begin
              bypass_valid_q <= 1'b1;
              bypass_data_q  <= axi_rsp_i.r.data;
            end
            beat_cnt_q <= beat_cnt_q + 4'd1;
            if (axi_rsp_i.r.last) begin
              // tag write fires combinationally via tag_we (refill_complete_fire)
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
          // Combinational BRAM byte-strobed write fires via amo_rmw_write_fire.
          // FSM marks dirty, signals done, and returns to IDLE.
          dirty_q[miss_set_q][victim_q] <= 1'b1;
          amo_done_q     <= 1'b1;
          amo_pending_q  <= 1'b0;
          state_q        <= DC_IDLE;
        end
        DC_FLUSH_SCAN: begin
          // Walk (set, way).  Dirty → writeback path; clean → just
          // invalidate and advance.  When the walk completes, pulse
          // flush_done_q for one cycle and return to DC_IDLE.
          //
          // Tag arrays are BRAM-back: tag_rdata_eff[flush_way_q] is only
          // valid one cycle after flush_set_q became the tag_raddr.
          // flush_tag_settled_q gates the body — when low, stall this cycle
          // (do nothing else) so the BRAM read can settle. The flag is
          // re-armed below on every flush_set_q change.
          if (flush_tag_settled_q) begin
            if (valid_q[flush_set_q][flush_way_q] &
                dirty_q[flush_set_q][flush_way_q]) begin
              // Dirty line: capture the tag (from BRAM via tag_rdata_eff)
              // and start the writeback. Reuse the WB registers — no
              // other transaction is active during a flush walk.
              miss_set_q    <= flush_set_q;
              victim_q      <= flush_way_q;
              evict_tag_q   <= tag_rdata_eff[flush_way_q];
              wb_beat_cnt_q <= 4'd0;
              state_q       <= DC_FLUSH_AW;
            end else begin
              // Clean or invalid line: just invalidate and advance.
              valid_q[flush_set_q][flush_way_q] <= 1'b0;
              if (flush_way_q == ($clog2(NUM_WAYS))'(NUM_WAYS - 1)) begin
                flush_way_q <= {$clog2(NUM_WAYS){1'b0}};
                if (flush_set_q == SET_IDX_W'(NUM_SETS - 1)) begin
                  flush_done_q <= 1'b1;
                  state_q      <= DC_IDLE;
                end else begin
                  flush_set_q         <= flush_set_q + 1'b1;
                  flush_tag_settled_q <= 1'b0;
                end
              end else begin
                flush_way_q <= flush_way_q + 1'b1;
              end
            end
          end else begin
            // Bubble cycle: BRAM read in flight, latch settled for next.
            flush_tag_settled_q <= 1'b1;
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
                flush_way_q <= {$clog2(NUM_WAYS){1'b0}};
                if (flush_set_q == SET_IDX_W'(NUM_SETS - 1)) begin
                  flush_done_q <= 1'b1;
                  state_q      <= DC_IDLE;
                end else begin
                  flush_set_q         <= flush_set_q + 1'b1;
                  flush_tag_settled_q <= 1'b0;   // new set: need a bubble
                  state_q             <= DC_FLUSH_SCAN;
                end
              end else begin
                flush_way_q <= flush_way_q + 1'b1;
                state_q     <= DC_FLUSH_SCAN;
              end
            end
          end
        end
        // NC bypass FSM arms
        DC_NC_AR: begin
          if (axi_req_o.ar_valid & axi_rsp_i.ar_ready) state_q <= DC_NC_R;
        end
        DC_NC_R: begin
          if (axi_rsp_i.r_valid) begin
            nc_rsp_valid_q <= ~|axi_rsp_i.r.resp;        // valid only on OKAY
            nc_rsp_data_q  <= axi_rsp_i.r.data;
            nc_rsp_err_q   <= |axi_rsp_i.r.resp;
            state_q        <= DC_IDLE;
          end
        end
        DC_NC_AW: begin
          if (axi_req_o.aw_valid & axi_rsp_i.aw_ready) state_q <= DC_NC_W;
        end
        DC_NC_W: begin
          if (axi_req_o.w_valid & axi_rsp_i.w_ready) begin
            state_q <= DC_NC_B;
          end
        end
        DC_NC_B: begin
          if (axi_rsp_i.b_valid) begin
            nc_b_done_q <= ~|axi_rsp_i.b.resp;
            nc_b_err_q  <=  |axi_rsp_i.b.resp;
            state_q <= DC_IDLE;
          end
        end
        default: state_q <= DC_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // AXI request driver (combinational)
  // ==========================================================================
  always_comb begin
    axi_req_o = kronos_axi_req_t'({$bits(kronos_axi_req_t){1'b0}});

    // ---- AR channel ----
    // Cacheable refill (default path).
    axi_req_o.ar.addr  = {miss_tag_q, miss_set_q, miss_beat_q, 3'b000};
    axi_req_o.ar.size  = 3'b011;
    axi_req_o.ar.len   = 8'd7;
    axi_req_o.ar.burst = axi_pkg::BURST_WRAP;
    axi_req_o.ar.cache = 4'b1110;          // write-back, R+W allocate
    axi_req_o.ar.id    = {$bits(axi_req_o.ar.id){1'b0}};
    axi_req_o.ar_valid = (state_q == DC_REFILL_AR);
    axi_req_o.r_ready  = (state_q == DC_REFILL_R);

    // NC bypass overrides AR/R when active.
    if (state_q == DC_NC_AR) begin
      axi_req_o.ar.addr  = nc_addr_q;
      axi_req_o.ar.size  = nc_size_q;
      axi_req_o.ar.len   = 8'd0;
      axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      axi_req_o.ar.cache = 4'b0000;
      axi_req_o.ar.id    = {$bits(axi_req_o.ar.id){1'b0}};
      axi_req_o.ar_valid = 1'b1;
      axi_req_o.r_ready  = 1'b0;
    end else if (state_q == DC_NC_R) begin
      axi_req_o.ar_valid = 1'b0;
      axi_req_o.r_ready  = 1'b1;
    end

    // ---- AW / W / B channel ----
    // Write channel: dirty-eviction AW/W/B (line-aligned address)
    // TAG_W + SET_IDX_W + OFFSET_W == PHYS_ADDR_W by construction, so no
    // upper-pad concat is needed (Synth 8-693 zero-replication).
    //
    // evict_tag_q is captured in DC_IDLE for normal misses (from
    // tag_rdata_eff[victim_pick]) and in DC_FLUSH_SCAN for the flush walk
    // (from tag_rdata_eff[flush_way_q]); in both cases the tag is read
    // from BRAM and held in evict_tag_q across the multi-cycle WB burst.
    axi_req_o.aw.addr  = {evict_tag_q, miss_set_q, {OFFSET_W{1'b0}}};
    axi_req_o.aw.size  = 3'b011;
    axi_req_o.aw.len   = 8'd7;
    axi_req_o.aw.burst = axi_pkg::BURST_INCR;
    axi_req_o.aw.cache = 4'b1110;          // write-back, R+W allocate
    axi_req_o.aw.id    = {$bits(axi_req_o.aw.id){1'b0}};
    axi_req_o.aw_valid = (state_q == DC_WB_AW) | (state_q == DC_FLUSH_AW);

    // W.data is the previously-launched beat held in the victim way's
    // ram_rdata register (DC_WB_AW pre-launches beat 0 in the AW handshake
    // cycle; DC_WB_W pre-launches beat N+1 each time beat N retires).
    axi_req_o.w.data   = ram_rdata[victim_q];
    axi_req_o.w.strb   = {kronos_pkg::XLEN_BYTES{1'b1}};
    axi_req_o.w.last   = (wb_beat_cnt_q == 4'd7);
    axi_req_o.w_valid  = (state_q == DC_WB_W) | (state_q == DC_FLUSH_W);

    // NC bypass overrides AW/W for non-cacheable stores.
    if (state_q == DC_NC_AW) begin
      axi_req_o.aw.addr  = nc_addr_q;
      axi_req_o.aw.size  = nc_size_q;
      axi_req_o.aw.len   = 8'd0;
      axi_req_o.aw.burst = axi_pkg::BURST_INCR;
      axi_req_o.aw.cache = 4'b0000;
      axi_req_o.aw.id    = {$bits(axi_req_o.aw.id){1'b0}};
      axi_req_o.aw_valid = 1'b1;
      axi_req_o.w_valid  = 1'b0;
    end else if (state_q == DC_NC_W) begin
      axi_req_o.aw_valid = 1'b0;
      axi_req_o.w.data   = store_data_aligned(nc_size_q, nc_addr_q[2:0], nc_wdata_q);
      axi_req_o.w.strb   = store_strobes(nc_size_q, nc_addr_q[2:0]);
      axi_req_o.w.last   = 1'b1;
      axi_req_o.w_valid  = 1'b1;
    end else if (state_q == DC_NC_B) begin
      axi_req_o.aw_valid = 1'b0;
      axi_req_o.w_valid  = 1'b0;
    end

    axi_req_o.b_ready  = 1'b1;     // always accept B response
  end

  // ==========================================================================
  // AMO combinational datapath
  // ==========================================================================
  always_comb begin
    amo_result   = amo_compute(amo_op_q, amo_old_val_q, amo_src_q, amo_is_word_q);
    amo_be       = amo_is_word_q
                     ? store_strobes(3'd2, amo_addr_off_q)
                     : {kronos_pkg::XLEN_BYTES{1'b1}};
    amo_aligned  = amo_is_word_q
                     ? store_data_aligned(3'd2, amo_addr_off_q, amo_result)
                     : amo_result;
  end

  // ==========================================================================
  // Hit data path: select between cache hit, refill bypass, NC response, and
  // PTW lookup beat.
  // ==========================================================================
  // In DC_PTW_LOOKUP, ram_rdata[ptw_lookup_way_q] holds the PTW's beat;
  // hit_beat is otherwise the right way-mux output for LSU hits.
  assign beat_for_load = nc_rsp_valid_q             ? nc_rsp_data_q
                       : bypass_valid_q             ? bypass_data_q
                       : (state_q == DC_PTW_LOOKUP) ? ram_rdata[ptw_lookup_way_q]
                                                    : hit_beat;

  always_comb begin
    // Defaults (R7).
    eff_size_for_load = 3'b0;
    eff_off_for_load  = 3'b0;
    if (nc_rsp_valid_q) begin
      eff_size_for_load = nc_size_q;
      eff_off_for_load  = nc_addr_q[2:0];
    end else if (state_q == DC_PTW_LOOKUP) begin
      // PTW always issues 8B; offset within the beat is zero.
      eff_size_for_load = 3'd3;
      eff_off_for_load  = 3'b000;
    end else begin
      eff_size_for_load = eff_req_size;
      eff_off_for_load  = eff_req_addr[2:0];
    end
  end

  // ---- Size/sign extension on loads ----------------------------------------
  always_comb begin
    load_data_full = beat_for_load;
    unique case (eff_size_for_load)
      3'd0: begin     // byte (zero-extended)
        unique case (eff_off_for_load)
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
        unique case (eff_off_for_load[2:1])
          2'd0: load_data_full = {48'b0, beat_for_load[15: 0]};
          2'd1: load_data_full = {48'b0, beat_for_load[31:16]};
          2'd2: load_data_full = {48'b0, beat_for_load[47:32]};
          2'd3: load_data_full = {48'b0, beat_for_load[63:48]};
          default: load_data_full = beat_for_load;
        endcase
      end
      3'd2: begin     // word (zero-extended)
        load_data_full = eff_off_for_load[2] ? {32'b0, beat_for_load[63:32]}
                                              : {32'b0, beat_for_load[31: 0]};
      end
      default: load_data_full = beat_for_load;     // double
    endcase
  end

  // ==========================================================================
  // Outputs
  // ==========================================================================
  // Aggregate response signal (before LSU/PTW demux).
  // - LSU hits fire same-cycle via `hit` (and ~ptw_active so a PTW preempt
  //   doesn't raise data_valid_o for the LSU).
  // - PTW hits respond in DC_PTW_LOOKUP via the state_q check.
  // - Delayed responses (refill bypass, store_done, amo_done, NC) are
  //   unchanged.
  assign rsp_valid_int  = (hit & ~ptw_active)
                        | (state_q == DC_PTW_LOOKUP)
                        | bypass_valid_q | store_done_q | amo_done_q
                        | nc_rsp_valid_q | nc_b_done_q;
  assign rsp_rdata_int  = amo_done_q ? amo_old_val_q : load_data_full;
  // sc_success_int: the registered sc_success_q lags by one cycle after the
  // SC fires (it captures at the next posedge), but the LSU samples
  // sc_success_o the same cycle data_valid_o pulses (via `hit` in the
  // rsp_valid_int OR-tree).  In the MEM1/MEM2 pipeline, the SC at MEM2
  // advances to WB on the very next edge unless an unrelated stall holds
  // it — without combinational coverage, mem_wb_q.lsu_rdata captures
  // ~sc_success_q == 1 (failure) for an SC that actually hit and matched
  // its reservation.  Fold sc_hit_write_fire (the same combinational
  // predicate that fires the BRAM write) into sc_success_int so the LSU
  // sees the correct success bit in the same cycle data_valid pulses.
  assign sc_success_int = sc_success_q | sc_hit_write_fire;

  // route the response to either LSU or PTW.
  // - PTW hits land in DC_PTW_LOOKUP — owner is PTW.
  // - Same-cycle LSU hits in DC_IDLE (with no PTW preempt) — owner is LSU.
  // - Delayed responses (bypass / store_done / amo_done / sc_success after
  //   refill or RMW) are owned by the latched in_flight_is_ptw_q bit.
  assign rsp_to_ptw = (state_q == DC_PTW_LOOKUP)
                       ? 1'b1
                       : (state_q == DC_IDLE)
                          ? ((nc_rsp_valid_q | nc_b_done_q) ? nc_is_ptw_q : ptw_active)
                          : in_flight_is_ptw_q;

  // LSU response: gate by ~rsp_to_ptw.
  assign data_valid_o = rsp_valid_int  & ~rsp_to_ptw;
  assign rdata_o      = rsp_rdata_int;
  assign sc_success_o = sc_success_int & ~rsp_to_ptw;

  // PTW response: gate by rsp_to_ptw.
  assign ptw_rsp_valid_o = rsp_valid_int  &  rsp_to_ptw;
  assign ptw_rsp_rdata_o = rsp_rdata_int;
  assign ptw_rsp_sc_ok_o = sc_success_int &  rsp_to_ptw;

  assign stall_o      = (state_q != DC_IDLE);
  assign miss_pulse_o = miss_pulse_q;

  // AMO/LR/SC on non-cacheable address -> raise access-fault. The
  // signal is combinational so the trap is taken on the same cycle as the
  // EX-stage memory request, mirroring how pmp_data_fault is handled.
  assign amo_nc_fault_o = (state_q == DC_IDLE)
                        & eff_req_valid
                        & is_uncacheable
                        & ~(flush_i & ~flush_done_q)
                        & (eff_amo_req | eff_req_is_lr | eff_req_is_sc);

  // NC bus error -> raise access-fault. nc_rsp_err_q (R.resp != OKAY)
  // is the load-side error; nc_b_err_q (B.resp != OKAY) is the store-side.
  // Pulses high for one cycle, same shape as amo_nc_fault_o.
  assign bus_err_fault_o = nc_rsp_err_q | nc_b_err_q;

  // early_addr_i is the full PA from the dTLB; only the set-index slice
  // [OFFSET_W + SET_IDX_W - 1 : 3] gates the BRAM read.  The byte-offset
  // [2:0] and high address bits [63:12] arrive again in the MEM-stage
  // lookup_addr_i and are intentionally dropped on the early launch.
  // nc_we_q is captured from eff_req_we for parity with the rest of the
  // NC bypass register set, but the AW/W issue chain reads eff_req_we
  // directly and never re-reads the latched copy.
  assign _unused = ^{miss_store_off_q,
                     early_addr_i[PHYS_ADDR_W-1:12], early_addr_i[2:0],
                     nc_we_q};

endmodule
