// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_ptw.sv — Stage 6b shared hardware page-table walker.
// Walks satp.PPN through 3 (Sv39) or 4 (Sv48) levels, issuing 8B reads
// through the dcache priority port.  Sets A/D atomically via LR/SC.  Refills
// the requesting TLB on success; raises page-fault on any failure.
// Spec: RISC-V Privileged v1.12 § 4.4 / § 4.5 / Svadu.
module kronos_ptw
  import kronos_pkg::*;
(
  input  logic              clk_i,
  input  logic              rst_ni,

  // Translation control (from CSR)
  input  logic [3:0]        satp_mode_i,
  input  logic [15:0]       satp_asid_i,
  input  logic [43:0]       satp_ppn_i,

  // Miss requests from iTLB and dTLB
  input  logic              itlb_miss_i,
  input  logic [63:0]       itlb_miss_va_i,
  input  logic              dtlb_miss_i,
  input  logic [63:0]       dtlb_miss_va_i,
  input  logic              dtlb_miss_is_load_i,
  input  logic              dtlb_miss_is_store_i,
  input  priv_e             miss_priv_i,
  input  logic              sum_i,
  input  logic              mxr_i,

  // Refill outputs to the TLBs
  output logic              itlb_refill_valid_o,
  output logic              dtlb_refill_valid_o,
  output logic [1:0]        refill_size_o,
  output logic [35:0]       refill_vpn_o,
  output logic [43:0]       refill_ppn_o,
  output logic [15:0]       refill_asid_o,
  output logic              refill_global_o,
  output logic [3:0]        refill_perm_o,
  output logic              refill_a_o,
  output logic              refill_d_o,

  // Page-fault output (1-cycle pulse)
  output logic              page_fault_o,
  output logic [4:0]        page_fault_cause_o,
  output logic [63:0]       page_fault_tval_o,
  output tlb_op_e           page_fault_which_o,

  // Dcache priority request
  output logic              dcache_req_valid_o,
  output logic [55:0]       dcache_req_addr_o,
  output logic              dcache_req_we_o,
  output logic [63:0]       dcache_req_wdata_o,
  output logic [2:0]        dcache_req_size_o,
  output logic              dcache_req_is_lr_o,
  output logic              dcache_req_is_sc_o,
  input  logic              dcache_rsp_valid_i,
  input  logic [63:0]       dcache_rsp_rdata_i,
  input  logic              dcache_rsp_sc_ok_i,

  output logic              busy_o
);

  typedef enum logic [3:0] {
    S_IDLE,
    S_FETCH_REQ,
    S_FETCH_WAIT,
    S_AD_LR_REQ,
    S_AD_LR_WAIT,
    S_AD_SC_REQ,
    S_AD_SC_WAIT,
    S_REFILL,
    S_PAGE_FAULT
  } state_e;

  state_e state_q, state_n;

  logic [63:0]  walk_va_q;
  logic [1:0]   walk_level_q;
  logic [55:0]  walk_addr_q;
  logic [63:0]  cur_pte_q;
  tlb_op_e      walk_which_q;
  logic         walk_is_load_q;
  logic         walk_is_store_q;
  logic         needs_a_q;
  logic         needs_d_q;

  // PTE field accessors
  function automatic logic pte_v(input logic [63:0] p); return p[PTE_V_BIT]; endfunction
  function automatic logic pte_r(input logic [63:0] p); return p[PTE_R_BIT]; endfunction
  function automatic logic pte_w(input logic [63:0] p); return p[PTE_W_BIT]; endfunction
  function automatic logic pte_x(input logic [63:0] p); return p[PTE_X_BIT]; endfunction
  function automatic logic pte_u(input logic [63:0] p); return p[PTE_U_BIT]; endfunction
  function automatic logic pte_g(input logic [63:0] p); return p[PTE_G_BIT]; endfunction
  function automatic logic pte_a(input logic [63:0] p); return p[PTE_A_BIT]; endfunction
  function automatic logic pte_d(input logic [63:0] p); return p[PTE_D_BIT]; endfunction
  function automatic logic [43:0] pte_ppn(input logic [63:0] p); return p[53:10]; endfunction
  function automatic logic pte_reserved_set(input logic [63:0] p); return |p[63:54]; endfunction
  function automatic logic pte_is_leaf(input logic [63:0] p);
    return pte_v(p) & (pte_r(p) | pte_x(p));
  endfunction
  function automatic logic pte_is_pointer(input logic [63:0] p);
    return pte_v(p) & ~pte_r(p) & ~pte_x(p);
  endfunction

  function automatic logic ppn_aligned(input logic [43:0] ppn,
                                        input logic [1:0]  level);
    unique case (level)
      2'b00: ppn_aligned = 1'b1;
      2'b01: ppn_aligned = (ppn[8:0]   == 9'd0);
      2'b10: ppn_aligned = (ppn[17:0]  == 18'd0);
      2'b11: ppn_aligned = (ppn[26:0]  == 27'd0);
      default: ppn_aligned = 1'b0;
    endcase
  endfunction

  function automatic logic perm_fail(input logic [63:0] p,
                                      input priv_e prv,
                                      input logic isf, input logic isl, input logic iss,
                                      input logic sm, input logic mx);
    automatic logic rx, rw, rr, ru_bit;
    rx     = pte_x(p);
    rw     = pte_w(p);
    rr     = pte_r(p);
    ru_bit = pte_u(p);
    perm_fail = 1'b0;
    if (isf & ~rx) perm_fail = 1'b1;
    if (isl & ~(rr | (rx & mx))) perm_fail = 1'b1;
    if (iss & ~rw) perm_fail = 1'b1;
    if ((prv == PRIV_S) & ru_bit & (isf | ~sm)) perm_fail = 1'b1;
    if ((prv == PRIV_U) & ~ru_bit) perm_fail = 1'b1;
  endfunction

  function automatic logic [8:0] vpn_at_level(input logic [63:0] va,
                                                input logic [1:0] level);
    unique case (level)
      2'b00: vpn_at_level = va[20:12];
      2'b01: vpn_at_level = va[29:21];
      2'b10: vpn_at_level = va[38:30];
      2'b11: vpn_at_level = va[47:39];
      default: vpn_at_level = '0;
    endcase
  endfunction

  // Arbiter
  logic        accept_req;
  tlb_op_e     accepted_which;
  logic [63:0] accepted_va;
  logic        accepted_is_load, accepted_is_store;

  always_comb begin
    accept_req        = 1'b0;
    accepted_which    = TLB_NONE;
    accepted_va       = '0;
    accepted_is_load  = 1'b0;
    accepted_is_store = 1'b0;
    if (state_q == S_IDLE) begin
      if (itlb_miss_i) begin
        accept_req     = 1'b1;
        accepted_which = TLB_FETCH;
        accepted_va    = itlb_miss_va_i;
      end else if (dtlb_miss_i) begin
        accept_req        = 1'b1;
        accepted_which    = dtlb_miss_is_store_i ? TLB_STORE : TLB_LOAD;
        accepted_va       = dtlb_miss_va_i;
        accepted_is_load  = dtlb_miss_is_load_i;
        accepted_is_store = dtlb_miss_is_store_i;
      end
    end
  end

  logic [1:0] start_level;
  assign start_level = (satp_mode_i == SATP_MODE_SV48) ? 2'd3 : 2'd2;

  always_comb begin
    state_n             = state_q;
    dcache_req_valid_o  = 1'b0;
    dcache_req_addr_o   = walk_addr_q;
    dcache_req_we_o     = 1'b0;
    dcache_req_wdata_o  = '0;
    dcache_req_size_o   = 3'd3;
    dcache_req_is_lr_o  = 1'b0;
    dcache_req_is_sc_o  = 1'b0;

    itlb_refill_valid_o = 1'b0;
    dtlb_refill_valid_o = 1'b0;
    page_fault_o        = 1'b0;
    page_fault_cause_o  = '0;
    page_fault_tval_o   = '0;
    page_fault_which_o  = TLB_NONE;
    busy_o              = (state_q != S_IDLE);

    unique case (state_q)
      S_IDLE: begin
        if (accept_req & (satp_mode_i != SATP_MODE_BARE)) state_n = S_FETCH_REQ;
      end

      S_FETCH_REQ: begin
        dcache_req_valid_o = 1'b1;
        dcache_req_addr_o  = walk_addr_q;
        if (dcache_rsp_valid_i) state_n = S_FETCH_WAIT;
      end

      S_FETCH_WAIT: begin
        if (~pte_v(cur_pte_q) | (pte_w(cur_pte_q) & ~pte_r(cur_pte_q)) |
            pte_reserved_set(cur_pte_q)) begin
          state_n = S_PAGE_FAULT;
        end else if (pte_is_leaf(cur_pte_q)) begin
          if (~ppn_aligned(pte_ppn(cur_pte_q), walk_level_q)) state_n = S_PAGE_FAULT;
          else if (perm_fail(cur_pte_q, miss_priv_i,
                              walk_which_q == TLB_FETCH,
                              walk_is_load_q, walk_is_store_q,
                              sum_i, mxr_i)) state_n = S_PAGE_FAULT;
          else if (~pte_a(cur_pte_q) | (walk_is_store_q & ~pte_d(cur_pte_q)))
            state_n = S_AD_LR_REQ;
          else
            state_n = S_REFILL;
        end else if (pte_is_pointer(cur_pte_q)) begin
          if (walk_level_q == 2'b00) state_n = S_PAGE_FAULT;
          else                       state_n = S_FETCH_REQ;
        end else begin
          state_n = S_PAGE_FAULT;
        end
      end

      S_AD_LR_REQ: begin
        dcache_req_valid_o = 1'b1;
        dcache_req_addr_o  = walk_addr_q;
        dcache_req_is_lr_o = 1'b1;
        if (dcache_rsp_valid_i) state_n = S_AD_LR_WAIT;
      end

      S_AD_LR_WAIT: begin
        if (~pte_v(cur_pte_q)) state_n = S_IDLE;
        else                   state_n = S_AD_SC_REQ;
      end

      S_AD_SC_REQ: begin
        dcache_req_valid_o = 1'b1;
        dcache_req_addr_o  = walk_addr_q;
        dcache_req_we_o    = 1'b1;
        dcache_req_is_sc_o = 1'b1;
        // Bit 6 = A, bit 7 = D
        dcache_req_wdata_o = cur_pte_q
                              | (needs_a_q ? 64'h40 : 64'h00)
                              | (needs_d_q ? 64'h80 : 64'h00);
        if (dcache_rsp_valid_i) state_n = S_AD_SC_WAIT;
      end

      S_AD_SC_WAIT: begin
        if (dcache_rsp_sc_ok_i) state_n = S_REFILL;
        else                    state_n = S_IDLE;
      end

      S_REFILL: begin
        if (walk_which_q == TLB_FETCH) itlb_refill_valid_o = 1'b1;
        else                            dtlb_refill_valid_o = 1'b1;
        state_n = S_IDLE;
      end

      S_PAGE_FAULT: begin
        page_fault_o       = 1'b1;
        page_fault_cause_o = (walk_which_q == TLB_FETCH) ? CAUSE_INSTR_PAGE_FAULT
                            : (walk_which_q == TLB_LOAD)  ? CAUSE_LOAD_PAGE_FAULT
                                                          : CAUSE_STORE_PAGE_FAULT;
        page_fault_tval_o  = walk_va_q;
        page_fault_which_o = walk_which_q;
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

  // Refill outputs
  assign refill_size_o   = walk_level_q;
  assign refill_vpn_o    = walk_va_q[47:12];
  assign refill_ppn_o    = pte_ppn(cur_pte_q);
  assign refill_asid_o   = satp_asid_i;
  assign refill_global_o = pte_g(cur_pte_q);
  assign refill_perm_o   = {pte_u(cur_pte_q), pte_x(cur_pte_q),
                             pte_w(cur_pte_q), pte_r(cur_pte_q)};
  assign refill_a_o      = 1'b1;
  assign refill_d_o      = walk_is_store_q | pte_d(cur_pte_q);

  // Sequential
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= S_IDLE;
      walk_va_q        <= '0;
      walk_level_q     <= '0;
      walk_addr_q      <= '0;
      cur_pte_q        <= '0;
      walk_which_q     <= TLB_NONE;
      walk_is_load_q   <= 1'b0;
      walk_is_store_q  <= 1'b0;
      needs_a_q        <= 1'b0;
      needs_d_q        <= 1'b0;
    end else begin
      state_q <= state_n;

      if (state_q == S_IDLE & accept_req & (satp_mode_i != SATP_MODE_BARE)) begin
        walk_va_q       <= accepted_va;
        walk_level_q    <= start_level;
        walk_addr_q     <= {satp_ppn_i, vpn_at_level(accepted_va, start_level), 3'b000};
        walk_which_q    <= accepted_which;
        walk_is_load_q  <= accepted_is_load;
        walk_is_store_q <= accepted_is_store;
      end

      if ((state_q == S_FETCH_REQ | state_q == S_AD_LR_REQ) & dcache_rsp_valid_i) begin
        cur_pte_q <= dcache_rsp_rdata_i;
      end

      if (state_q == S_FETCH_WAIT) begin
        if (pte_is_leaf(cur_pte_q) &
            (~pte_a(cur_pte_q) | (walk_is_store_q & ~pte_d(cur_pte_q)))) begin
          needs_a_q <= ~pte_a(cur_pte_q);
          needs_d_q <= walk_is_store_q & ~pte_d(cur_pte_q);
        end
        if (pte_is_pointer(cur_pte_q) & (walk_level_q != 2'd0)) begin
          walk_level_q <= walk_level_q - 2'd1;
          walk_addr_q  <= {pte_ppn(cur_pte_q),
                           vpn_at_level(walk_va_q, walk_level_q - 2'd1),
                           3'b000};
        end
      end
    end
  end

endmodule
