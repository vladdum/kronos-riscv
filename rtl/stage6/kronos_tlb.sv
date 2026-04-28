// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_tlb.sv — Stage 6b N-entry fully-associative TLB.
// Stores per-entry {V, ASID, page_size, VPN, PPN, perm{U,X,W,R}, A, D, global}.
// Lookup: parallel CAM compare with size-masked VPN equality + ASID/global
// match + permission compare.  Refill: pseudo-LRU victim selection.
// sfence.vma: 4 selectivity modes (full / per-VA / per-ASID / per-(VA,ASID)).
// Spec: RISC-V Privileged v1.12 § 4.4 (Sv39) and § 4.5 (Sv48).
module kronos_tlb
  import kronos_pkg::*;
#(
  parameter int N = 8
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  // Lookup port (combinational).
  input  logic              lookup_valid_i,
  input  logic [63:0]       lookup_va_i,
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
  input  logic [63:0]       flush_va_i,
  input  logic [15:0]       flush_asid_i
);

  // Per-entry state
  logic        valid     [N];
  logic        global_   [N];
  logic [15:0] asid      [N];
  logic [1:0]  page_size [N];
  logic [35:0] vpn       [N];
  logic [43:0] ppn       [N];
  logic [3:0]  perm      [N];
  logic        a_bit     [N];
  logic        d_bit     [N];
  logic [N-2:0] plru_tree;

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

  // Lookup hit per entry
  logic [N-1:0] hit;
  logic [35:0]  lookup_vpn;
  assign lookup_vpn = lookup_va_i[47:12];

  for (genvar i = 0; i < N; i++) begin : gen_hit
    assign hit[i] = lookup_valid_i &
                    valid[i] &
                    vpn_match(lookup_vpn, vpn[i], page_size[i]) &
                    (global_[i] | (asid[i] == lookup_asid_i));
  end

  // Priority encode (lowest index)
  logic [$clog2(N)-1:0] hit_idx;
  always_comb begin
    hit_idx = '0;
    for (int i = 0; i < N; i++) begin
      if (hit[i]) begin
        hit_idx = i[$clog2(N)-1:0];
        break;
      end
    end
  end

  assign lookup_hit_o = |hit;

  // PA reconstruction by page size
  logic [43:0] hit_ppn;
  logic [1:0]  hit_size;
  always_comb begin
    hit_ppn  = ppn[hit_idx];
    hit_size = page_size[hit_idx];
  end

  always_comb begin
    lookup_pa_o = '0;
    unique case (hit_size)
      2'b00: lookup_pa_o = {hit_ppn,        lookup_va_i[11:0]};
      2'b01: lookup_pa_o = {hit_ppn[43:9],  lookup_va_i[20:0]};
      2'b10: lookup_pa_o = {hit_ppn[43:18], lookup_va_i[29:0]};
      2'b11: lookup_pa_o = {hit_ppn[43:27], lookup_va_i[38:0]};
      default: lookup_pa_o = '0;
    endcase
  end

  // Permission resolution
  logic hit_u, hit_x, hit_w, hit_r;
  always_comb begin
    hit_u = perm[hit_idx][3];
    hit_x = perm[hit_idx][2];
    hit_w = perm[hit_idx][1];
    hit_r = perm[hit_idx][0];
  end

  always_comb begin
    lookup_perm_fail_o = 1'b0;
    if (lookup_hit_o) begin
      if (is_fetch_i & ~hit_x) lookup_perm_fail_o = 1'b1;
      if (is_load_i  & ~(hit_r | (hit_x & mxr_i))) lookup_perm_fail_o = 1'b1;
      if (is_store_i & ~hit_w) lookup_perm_fail_o = 1'b1;
      if ((lookup_priv_i == PRIV_S) & hit_u & (is_fetch_i | ~sum_i))
        lookup_perm_fail_o = 1'b1;
      if ((lookup_priv_i == PRIV_U) & ~hit_u)
        lookup_perm_fail_o = 1'b1;
    end
  end

  assign lookup_a_zero_o = lookup_hit_o & ~a_bit[hit_idx];
  assign lookup_d_zero_o = lookup_hit_o & is_store_i & ~d_bit[hit_idx];

  // Pseudo-LRU victim selection (3-bit tree for N=8)
  logic [$clog2(N)-1:0] victim_idx;
  generate
    if (N == 8) begin : gen_plru8
      always_comb begin
        if (plru_tree[0] == 0) begin
          if (plru_tree[1] == 0)
            victim_idx = plru_tree[3] ? 3'd1 : 3'd0;
          else
            victim_idx = plru_tree[4] ? 3'd3 : 3'd2;
        end else begin
          if (plru_tree[2] == 0)
            victim_idx = plru_tree[5] ? 3'd5 : 3'd4;
          else
            victim_idx = plru_tree[6] ? 3'd7 : 3'd6;
        end
      end
    end else begin : gen_plru_round_robin
      logic [$clog2(N)-1:0] rr_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) rr_q <= '0;
        else if (refill_valid_i) rr_q <= rr_q + 1'b1;
      end
      assign victim_idx = rr_q;
    end
  endgenerate

  // Refill destination: prefer invalid; otherwise victim
  logic [$clog2(N)-1:0] refill_idx;
  logic                 has_invalid;
  always_comb begin
    refill_idx  = victim_idx;
    has_invalid = 1'b0;
    for (int i = 0; i < N; i++) begin
      if (!valid[i] & !has_invalid) begin
        refill_idx  = i[$clog2(N)-1:0];
        has_invalid = 1'b1;
      end
    end
  end

  // Sequential update
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < N; i++) begin
        valid[i]     <= 1'b0;
        global_[i]   <= 1'b0;
        asid[i]      <= '0;
        page_size[i] <= '0;
        vpn[i]       <= '0;
        ppn[i]       <= '0;
        perm[i]      <= '0;
        a_bit[i]     <= 1'b0;
        d_bit[i]     <= 1'b0;
      end
      plru_tree <= '0;
    end else begin
      // sfence.vma takes priority over refill
      if (flush_valid_i) begin
        for (int i = 0; i < N; i++) begin
          automatic logic v_ok = ~flush_va_valid_i |
                                  vpn_match(flush_va_i[47:12], vpn[i], page_size[i]);
          automatic logic a_ok = ~flush_asid_valid_i |
                                  ((asid[i] == flush_asid_i) & ~global_[i]);
          if (v_ok & a_ok) valid[i] <= 1'b0;
        end
      end
      // refill
      else if (refill_valid_i) begin
        // Stage 6b: invalidate any existing entries matching this refill VPN
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
      // on lookup hit, update pLRU
      else if (lookup_hit_o) begin
        if (N == 8) begin
          plru_tree[0] <= ~hit_idx[2];
          if (hit_idx[2] == 0) plru_tree[1] <= ~hit_idx[1];
          else                  plru_tree[2] <= ~hit_idx[1];
          unique case (hit_idx)
            3'd0, 3'd1: plru_tree[3] <= ~hit_idx[0];
            3'd2, 3'd3: plru_tree[4] <= ~hit_idx[0];
            3'd4, 3'd5: plru_tree[5] <= ~hit_idx[0];
            3'd6, 3'd7: plru_tree[6] <= ~hit_idx[0];
            default: ;
          endcase
        end
      end
    end
  end

endmodule
