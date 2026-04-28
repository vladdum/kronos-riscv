// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_pmp.sv — Stage 6a Physical Memory Protection unit.
// N regions (parameterisable, default 8), NA4 + NAPOT. Combinational fault
// check for one access per cycle.
// Spec: RISC-V Privileged v1.12 § 3.7.
module kronos_pmp
  import kronos_pkg::*;
#(
  parameter int N = 8
) (
  // Per-region CSR snapshot from kronos_csr (combinational read).
  input  logic [N-1:0][7:0]   pmpcfg_i,    // N regions × 8-bit cfg
  input  logic [N-1:0][53:0]  pmpaddr_i,   // N regions × 54-bit addr (PA[55:2])

  // Access query.
  input  priv_e             priv_i,
  input  logic              valid_i,
  input  logic [55:0]       addr_i,
  input  logic [2:0]        size_i,      // 0=1B, 1=2B, 2=4B, 3=8B
  input  logic              is_fetch_i,
  input  logic              is_load_i,
  input  logic              is_store_i,

  // Result.
  output logic              fault_o,
  output logic [55:0]       fault_addr_o
);

  // -----------------------------------------------------------------------
  // Decode per-region cfg fields.
  // -----------------------------------------------------------------------
  logic [N-1:0]       reg_l;
  logic [N-1:0][1:0]  reg_a;     // 00=OFF, 10=NA4, 11=NAPOT (01=TOR not impl)
  logic [N-1:0]       reg_x;
  logic [N-1:0]       reg_w;
  logic [N-1:0]       reg_r;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      reg_l[i] = pmpcfg_i[i][7];
      reg_a[i] = pmpcfg_i[i][4:3];
      reg_x[i] = pmpcfg_i[i][2];
      reg_w[i] = pmpcfg_i[i][1];
      reg_r[i] = pmpcfg_i[i][0];
    end
  end

  // -----------------------------------------------------------------------
  // Per-region match.
  // -----------------------------------------------------------------------
  // For NAPOT: pmpaddr encodes a base + log2(size/4)−1 trailing zero bits.
  // The match mask is derived as ~(((pmpaddr+1) ^ pmpaddr) << 1).
  // For NA4: exact 4-byte match on PA[55:2].
  // Multi-byte access (size > region) is rejected as a fault.
  logic [N-1:0]        match;
  logic [N-1:0][53:0]  napot_mask;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      automatic logic [54:0] inc       = {1'b0, pmpaddr_i[i]} + 55'd1;
      automatic logic [54:0] xor_v     = inc ^ {1'b0, pmpaddr_i[i]};
      automatic logic [53:0] mask      = ~xor_v[53:0];
      automatic logic [55:0] addr_plus = addr_i + ((56'd1 << size_i) - 56'd1);

      napot_mask[i] = mask;

      unique case (reg_a[i])
        2'b10: begin  // NA4 — exact 4-byte boundary
          match[i] = valid_i &
                     (addr_i[55:2]      == pmpaddr_i[i]) &
                     (addr_plus[55:2]   == pmpaddr_i[i]);
        end
        2'b11: begin  // NAPOT
          match[i] = valid_i &
                     ((addr_i[55:2]    & napot_mask[i]) == (pmpaddr_i[i] & napot_mask[i])) &
                     ((addr_plus[55:2] & napot_mask[i]) == (pmpaddr_i[i] & napot_mask[i]));
        end
        default: match[i] = 1'b0;  // OFF or TOR (TOR not implemented)
      endcase
    end
  end

  // Active = matched AND not OFF.
  logic [N-1:0] active;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      active[i] = match[i] & (reg_a[i] != 2'b00);
    end
  end

  // -----------------------------------------------------------------------
  // Priority encode (lowest index wins).
  // -----------------------------------------------------------------------
  logic [$clog2(N)-1:0] matched_idx;
  logic                 any_match;
  always_comb begin
    matched_idx = '0;
    any_match   = 1'b0;
    for (int i = 0; i < N; i++) begin
      if (active[i] & ~any_match) begin
        matched_idx = i[$clog2(N)-1:0];
        any_match   = 1'b1;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Permission resolution.
  // -----------------------------------------------------------------------
  logic matched_l, matched_x, matched_w, matched_r;
  always_comb begin
    matched_l = reg_l[matched_idx];
    matched_x = reg_x[matched_idx];
    matched_w = reg_w[matched_idx];
    matched_r = reg_r[matched_idx];
  end

  logic m_bypass;        // M-mode unconstrained when matched region is unlocked
  logic op_allowed;      // matched-region permission for this access
  logic no_match_pass;   // M passes by default; S/U fault by default
  always_comb begin
    m_bypass      = (priv_i == PRIV_M) & ~matched_l;
    op_allowed    = (is_fetch_i & matched_x)
                  | (is_load_i  & matched_r)
                  | (is_store_i & matched_w);
    no_match_pass = (priv_i == PRIV_M);
  end

  assign fault_o = valid_i &
                    ~( any_match
                       ? (m_bypass | op_allowed)
                       : no_match_pass );

  assign fault_addr_o = addr_i;

endmodule
