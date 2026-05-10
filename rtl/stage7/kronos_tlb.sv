// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_tlb.sv — N-entry fully-associative TLB, internally split into two
// pipeline sub-stages:
//
//   Cycle S0 (combinational on lookup_va_i): per-entry CAM compare + ASID
//     match, priority encode, snapshot mux selecting per-entry data at
//     hit_idx.  Snapshot register at S0->S1 edge captures the hit vector,
//     hit_idx, and the selected per-entry fields plus context (lookup_priv,
//     is_load/store/fetch, sum, mxr, lookup_valid, va offset).
//
//   Cycle S1 (combinational on registered S0 outputs): hit OR-reduce, PA
//     reconstruct mux on registered page_size, perm-check on registered
//     perm + context, A/D-zero detect.  All five outputs (lookup_pa_o,
//     lookup_hit_o, lookup_perm_fail_o, lookup_a_zero_o, lookup_d_zero_o)
//     are flop outputs of the S1 stage.
//
// Refill / flush behave as before — refill writes at the same clock edge
// as S0->S1; in-flight S1 reads use the snapshot (pre-refill data).
// New lookups starting at S0 see the refilled / flushed entry.
//
// Spec: RISC-V Privileged v1.12 § 4.4 (Sv39) and § 4.5 (Sv48).
module kronos_tlb
  import kronos_pkg::*;
#(
  parameter int N = 8
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  // Lookup port (output is registered S1 stage).
  input  logic              lookup_valid_i,
  input  logic [kronos_pkg::XLEN-1:0]   lookup_va_i,
  input  logic [15:0]       lookup_asid_i,
  input  priv_e             lookup_priv_i,
  input  logic              is_load_i,
  input  logic              is_store_i,
  input  logic              is_fetch_i,
  input  logic              sum_i,
  input  logic              mxr_i,
  output logic              lookup_hit_o,
  output logic [55:0]       lookup_pa_o,
  output logic              lookup_perm_fail_o,
  output logic              lookup_a_zero_o,
  output logic              lookup_d_zero_o,

  // Refill port (PTW writes a new entry).
  input  logic              refill_valid_i,
  input  logic [1:0]        refill_size_i,       // 0=4K,1=2M,2=1G,3=512G
  input  logic [35:0]       refill_vpn_i,
  input  logic [43:0]       refill_ppn_i,
  input  logic [15:0]       refill_asid_i,
  input  logic              refill_global_i,
  input  logic [3:0]        refill_perm_i,       // {U,X,W,R}
  input  logic              refill_a_i,
  input  logic              refill_d_i,

  // sfence.vma port (1-cycle pulse).
  input  logic              flush_valid_i,
  input  logic              flush_va_valid_i,
  input  logic              flush_asid_valid_i,
  input  logic [kronos_pkg::XLEN-1:0]   flush_va_i,
  input  logic [15:0]       flush_asid_i
);

  // 1. Constants
  localparam int unsigned IDX_W = $clog2(N);

  // 2. Types (none beyond pkg imports)

  // 3. State registers — entry arrays
  logic              valid     [N];
  logic              global_   [N];
  logic [15:0]       asid      [N];
  logic [1:0]        page_size [N];
  logic [35:0]       vpn       [N];
  logic [43:0]       ppn       [N];
  logic [3:0]        perm      [N];
  logic              a_bit     [N];
  logic              d_bit     [N];
  logic [N-2:0]      plru_tree;

  // S0->S1 snapshot register.
  logic [N-1:0]       hit_q;
  logic [IDX_W-1:0]   hit_idx_q;
  logic [43:0]        ppn_sel_q;
  logic [1:0]         page_size_sel_q;
  logic [3:0]         perm_sel_q;
  logic               a_bit_sel_q;
  logic               d_bit_sel_q;
  logic [38:0]        lookup_va_offset_q;  // 39 bits cover 512 GiB pages
  logic               is_load_q;
  logic               is_store_q;
  logic               is_fetch_q;
  logic               sum_q;
  logic               mxr_q;
  priv_e              lookup_priv_q;
  logic               lookup_valid_q;

  // 4. Combinational signals — S0 stage
  logic [N-1:0]      hit;
  logic [35:0]       lookup_vpn;
  logic [IDX_W-1:0]  hit_idx_d;
  logic [43:0]       ppn_sel_d;
  logic [1:0]        page_size_sel_d;
  logic [3:0]        perm_sel_d;
  logic              a_bit_sel_d;
  logic              d_bit_sel_d;

  // S1 combinational signals
  logic              hit_u;
  logic              hit_x;
  logic              hit_w;
  logic              hit_r;

  // Refill / replacement signals
  logic [IDX_W-1:0]  victim_idx;
  logic [IDX_W-1:0]  refill_idx;
  logic              has_invalid;

  // VA carries the full 64-bit virtual address; the TLB uses only VPN
  // bits [47:12].  Bits [63:48] (Sv48 sign-extension) and the [11:0] page
  // offset are intentionally dropped here.
  logic              _unused;

  // 5. Submodule interface signals (none)

  // VPN comparison helper
  function automatic logic vpn_match(input logic [35:0] a,
                                      input logic [35:0] b,
                                      input logic [1:0] sz);
    unique case (sz)
      2'b00: vpn_match = (a               == b);
      2'b01: vpn_match = (a[35:9]         == b[35:9]);
      2'b10: vpn_match = (a[35:18]        == b[35:18]);
      2'b11: vpn_match = (a[35:27]        == b[35:27]);
      default: vpn_match = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // S0 stage — CAM compare + priority encode + per-entry snapshot mux.
  // ---------------------------------------------------------------------------
  assign lookup_vpn = lookup_va_i[47:12];

  for (genvar i = 0; i < N; i++) begin : gen_hit
    assign hit[i] = lookup_valid_i &
                    valid[i] &
                    vpn_match(lookup_vpn, vpn[i], page_size[i]) &
                    (global_[i] | (asid[i] == lookup_asid_i));
  end

  // Priority encode (lowest hitting index).
  always_comb begin
    hit_idx_d = {IDX_W{1'b0}};
    for (int i = 0; i < N; i++) begin
      if (hit[i]) begin
        hit_idx_d = i[IDX_W-1:0];
        break;
      end
    end
  end

  // Snapshot mux — read per-entry arrays at hit_idx_d.  The next-cycle refill /
  // flush writes the same arrays at the S0->S1 edge; in-flight S1 reads use
  // the snapshot captured here, so the contract "lookup output reflects S0
  // state" is preserved across refill/flush races.
  always_comb begin
    ppn_sel_d       = ppn       [hit_idx_d];
    page_size_sel_d = page_size [hit_idx_d];
    perm_sel_d      = perm      [hit_idx_d];
    a_bit_sel_d     = a_bit     [hit_idx_d];
    d_bit_sel_d     = d_bit     [hit_idx_d];
  end

  // S0->S1 pipeline register.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hit_q              <= {N{1'b0}};
      hit_idx_q          <= {IDX_W{1'b0}};
      ppn_sel_q          <= 44'd0;
      page_size_sel_q    <= 2'd0;
      perm_sel_q         <= 4'd0;
      a_bit_sel_q        <= 1'b0;
      d_bit_sel_q        <= 1'b0;
      lookup_va_offset_q <= 39'd0;
      is_load_q          <= 1'b0;
      is_store_q         <= 1'b0;
      is_fetch_q         <= 1'b0;
      sum_q              <= 1'b0;
      mxr_q              <= 1'b0;
      lookup_priv_q      <= PRIV_M;
      lookup_valid_q     <= 1'b0;
    end else begin
      hit_q              <= hit;
      hit_idx_q          <= hit_idx_d;
      ppn_sel_q          <= ppn_sel_d;
      page_size_sel_q    <= page_size_sel_d;
      perm_sel_q         <= perm_sel_d;
      a_bit_sel_q        <= a_bit_sel_d;
      d_bit_sel_q        <= d_bit_sel_d;
      lookup_va_offset_q <= lookup_va_i[38:0];
      is_load_q          <= is_load_i;
      is_store_q         <= is_store_i;
      is_fetch_q         <= is_fetch_i;
      sum_q              <= sum_i;
      mxr_q              <= mxr_i;
      lookup_priv_q      <= lookup_priv_i;
      lookup_valid_q     <= lookup_valid_i;
    end
  end

  // ---------------------------------------------------------------------------
  // S1 stage — hit aggregate + PA reconstruct + perm-check + A/D-zero detect.
  // ---------------------------------------------------------------------------
  assign lookup_hit_o = lookup_valid_q & |hit_q;

  always_comb begin
    hit_u = perm_sel_q[3];
    hit_x = perm_sel_q[2];
    hit_w = perm_sel_q[1];
    hit_r = perm_sel_q[0];
  end

  always_comb begin
    lookup_pa_o = 56'd0;
    unique case (page_size_sel_q)
      2'b00: lookup_pa_o = {ppn_sel_q,         lookup_va_offset_q[11:0]};   // 4K
      2'b01: lookup_pa_o = {ppn_sel_q[43:9],   lookup_va_offset_q[20:0]};   // 2M
      2'b10: lookup_pa_o = {ppn_sel_q[43:18],  lookup_va_offset_q[29:0]};   // 1G
      2'b11: lookup_pa_o = {ppn_sel_q[43:27],  lookup_va_offset_q[38:0]};   // 512G
      default: lookup_pa_o = 56'd0;
    endcase
  end

  always_comb begin
    lookup_perm_fail_o = 1'b0;
    if (lookup_hit_o) begin
      if (is_fetch_q & ~hit_x) lookup_perm_fail_o = 1'b1;
      if (is_load_q  & ~(hit_r | (hit_x & mxr_q))) lookup_perm_fail_o = 1'b1;
      if (is_store_q & ~hit_w) lookup_perm_fail_o = 1'b1;
      if ((lookup_priv_q == PRIV_S) & hit_u & (is_fetch_q | ~sum_q)) begin
        lookup_perm_fail_o = 1'b1;
      end
      if ((lookup_priv_q == PRIV_U) & ~hit_u) begin
        lookup_perm_fail_o = 1'b1;
      end
    end
  end

  assign lookup_a_zero_o = lookup_hit_o & ~a_bit_sel_q;
  assign lookup_d_zero_o = lookup_hit_o & is_store_q & ~d_bit_sel_q;

  // ---------------------------------------------------------------------------
  // Pseudo-LRU victim selection (3-bit tree for N=8).
  // ---------------------------------------------------------------------------
  generate
    if (N == 8) begin : gen_plru8
      always_comb begin
        victim_idx = {IDX_W{1'b0}};
        if (plru_tree[0] == 0) begin
          if (plru_tree[1] == 0) begin
            victim_idx = plru_tree[3] ? 3'd1 : 3'd0;
          end else begin
            victim_idx = plru_tree[4] ? 3'd3 : 3'd2;
          end
        end else begin
          if (plru_tree[2] == 0) begin
            victim_idx = plru_tree[5] ? 3'd5 : 3'd4;
          end else begin
            victim_idx = plru_tree[6] ? 3'd7 : 3'd6;
          end
        end
      end
    end else begin : gen_plru_round_robin
      logic [IDX_W-1:0] rr_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) rr_q <= {IDX_W{1'b0}};
        else if (refill_valid_i) rr_q <= rr_q + 1'b1;
      end
      assign victim_idx = rr_q;
    end
  endgenerate

  // Refill destination: prefer invalid; otherwise victim
  always_comb begin
    refill_idx  = victim_idx;
    has_invalid = 1'b0;
    for (int i = 0; i < N; i++) begin
      if (!valid[i] & !has_invalid) begin
        refill_idx  = i[IDX_W-1:0];
        has_invalid = 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential update — entry arrays + plru tree.
  //
  // plru_tree updates use the registered S1-cycle hit_q / hit_idx_q so the
  // pLRU update aligns with the lookup whose hit is actually observed by
  // consumers.  This is one cycle later than the pre-split design, which
  // updated on the live lookup_hit / hit_idx; functionally equivalent for
  // replacement policy purposes (the entry that hit is still marked recent).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < N; i++) begin
        valid[i]     <= 1'b0;
        global_[i]   <= 1'b0;
        asid[i]      <= 16'd0;
        page_size[i] <= 2'd0;
        vpn[i]       <= 36'd0;
        ppn[i]       <= 44'd0;
        perm[i]      <= 4'd0;
        a_bit[i]     <= 1'b0;
        d_bit[i]     <= 1'b0;
      end
      plru_tree <= {(N-1){1'b0}};
    end else begin
      // sfence.vma takes priority over refill
      if (flush_valid_i) begin
        for (int i = 0; i < N; i++) begin
          if ((~flush_va_valid_i | vpn_match(flush_va_i[47:12], vpn[i], page_size[i])) &
              (~flush_asid_valid_i | ((asid[i] == flush_asid_i) & ~global_[i])))
            valid[i] <= 1'b0;
        end
      end
      // refill
      else if (refill_valid_i) begin
        // invalidate any existing entries matching this refill VPN
        // (any page-size match) before installing the new entry.  Without
        // this, an A/D-driven re-walk would refill into a fresh slot while
        // the stale entry (e.g. A=1 D=0) still answers lookups at a lower
        // index, producing an infinite miss loop.
        for (int i = 0; i < N; i++) begin
          if (valid[i] & vpn_match(refill_vpn_i, vpn[i], page_size[i]) &
              (global_[i] | (asid[i] == refill_asid_i))) begin
            valid[i] <= 1'b0;
          end
        end
        valid    [refill_idx] <= 1'b1;
        global_  [refill_idx] <= refill_global_i;
        asid     [refill_idx] <= refill_asid_i;
        page_size[refill_idx] <= refill_size_i;
        vpn      [refill_idx] <= refill_vpn_i;
        ppn      [refill_idx] <= refill_ppn_i;
        perm     [refill_idx] <= refill_perm_i;
        a_bit    [refill_idx] <= refill_a_i;
        d_bit    [refill_idx] <= refill_d_i;

        if (N == 8) begin
          plru_tree[0] <= ~refill_idx[2];
          if (refill_idx[2] == 0) plru_tree[1] <= ~refill_idx[1];
          else                     plru_tree[2] <= ~refill_idx[1];
          unique case (refill_idx)
            3'd0, 3'd1: plru_tree[3] <= ~refill_idx[0];
            3'd2, 3'd3: plru_tree[4] <= ~refill_idx[0];
            3'd4, 3'd5: plru_tree[5] <= ~refill_idx[0];
            3'd6, 3'd7: plru_tree[6] <= ~refill_idx[0];
            default: ;
          endcase
        end
      end
      // on lookup hit, update pLRU using the registered S1-cycle hit_idx.
      else if (lookup_hit_o) begin
        if (N == 8) begin
          plru_tree[0] <= ~hit_idx_q[2];
          if (hit_idx_q[2] == 0) plru_tree[1] <= ~hit_idx_q[1];
          else                    plru_tree[2] <= ~hit_idx_q[1];
          unique case (hit_idx_q)
            3'd0, 3'd1: plru_tree[3] <= ~hit_idx_q[0];
            3'd2, 3'd3: plru_tree[4] <= ~hit_idx_q[0];
            3'd4, 3'd5: plru_tree[5] <= ~hit_idx_q[0];
            3'd6, 3'd7: plru_tree[6] <= ~hit_idx_q[0];
            default: ;
          endcase
        end
      end
    end
  end

  assign _unused = ^{lookup_va_i[63:48], flush_va_i[63:48], flush_va_i[11:0]};

endmodule
