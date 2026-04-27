// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_trigger.sv — RISC-V Debug Spec Sdtrig (mcontrol6 subset).
// 4 triggers (T0..T3), M-mode only, action=BREAKPOINT (cause 3),
// match=equal only.  Read/write CSR ports for tselect/tdata1/tdata2/
// tdata3/tinfo; combinational hit detection in EX.
module kronos_trigger
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  // CSR access (one address per cycle, single-ported).
  input  logic        csr_req_i,
  input  logic [11:0] csr_addr_i,
  input  logic        csr_we_i,
  input  logic [63:0] csr_wdata_i,
  output logic [63:0] csr_rdata_o,
  output logic        csr_match_o,   // 1 = csr_addr_i is a trigger CSR

  // EX-stage probe (sample exactly when valid_i is high).
  input  logic        ex_valid_i,
  input  logic [31:0] ex_pc_i,
  input  logic        ex_is_load_i,
  input  logic        ex_is_store_i,
  input  logic [63:0] ex_mem_addr_i,

  // Match output.  Combinational: hit_o pulses high for one cycle when
  // an EX-stage instruction matches an enabled trigger.
  output logic        hit_o,
  output logic [31:0] hit_pc_o
);

  // Per-trigger state.  Only the writable bits are stored; the rest are
  // synthesized as constants on read.
  typedef struct packed {
    logic        m;        // tdata1[6]
    logic        execute;  // tdata1[3]
    logic        store;    // tdata1[2]
    logic        load;     // tdata1[1]
    logic        hit;      // tdata1[10] (sticky-set on match; RW1C)
    logic [63:0] tdata2;
  } trigger_t;

  trigger_t    triggers_q [0:3];
  logic [1:0]  tselect_q;

  // Build a tdata1 view from per-trigger fields.
  function automatic logic [63:0] pack_tdata1(input trigger_t t);
    logic [63:0] v;
    v          = '0;
    v[63:60]   = 4'h6;       // type=mcontrol6
    v[59]      = 1'b0;       // dmode=0
    v[10]      = t.hit;
    v[6]       = t.m;
    v[3]       = t.execute;
    v[2]       = t.store;
    v[1]       = t.load;
    return v;
  endfunction

  // CSR read mux.
  always_comb begin
    csr_rdata_o   = '0;
    csr_match_o   = 1'b0;
    unique case (csr_addr_i)
      12'h7A0: begin csr_match_o = 1'b1; csr_rdata_o = {62'b0, tselect_q}; end
      12'h7A1: begin csr_match_o = 1'b1; csr_rdata_o = pack_tdata1(triggers_q[tselect_q]); end
      12'h7A2: begin csr_match_o = 1'b1; csr_rdata_o = triggers_q[tselect_q].tdata2; end
      12'h7A3: begin csr_match_o = 1'b1; csr_rdata_o = '0; end
      12'h7A4: begin csr_match_o = 1'b1; csr_rdata_o = 64'h0000_0000_0000_0040; end // bit 6 = mcontrol6
      default: ;
    endcase
  end

  // Per-trigger combinational match (one bit per trigger).
  logic [3:0] match_vec;
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      automatic trigger_t t          = triggers_q[i];
      automatic logic     exec_match  = t.m & t.execute & ex_valid_i & ({32'b0, ex_pc_i} == t.tdata2);
      automatic logic     load_match  = t.m & t.load    & ex_valid_i & ex_is_load_i  & (ex_mem_addr_i == t.tdata2);
      automatic logic     store_match = t.m & t.store   & ex_valid_i & ex_is_store_i & (ex_mem_addr_i == t.tdata2);
      match_vec[i] = exec_match | load_match | store_match;
    end
  end

  assign hit_o    = |match_vec;
  assign hit_pc_o = ex_pc_i;

  // Sequential: CSR writes + sticky-hit update.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tselect_q <= 2'd0;
      for (int i = 0; i < 4; i++) begin
        triggers_q[i].m       <= 1'b0;
        triggers_q[i].execute <= 1'b0;
        triggers_q[i].store   <= 1'b0;
        triggers_q[i].load    <= 1'b0;
        triggers_q[i].hit     <= 1'b0;
        triggers_q[i].tdata2  <= '0;
      end
    end else begin
      // Sticky-hit update — set on match, regardless of CSR write.
      for (int i = 0; i < 4; i++) begin
        if (match_vec[i]) triggers_q[i].hit <= 1'b1;
      end

      // CSR write — overrides sticky update on the same cycle.
      if (csr_req_i & csr_we_i) begin
        unique case (csr_addr_i)
          12'h7A0: tselect_q <= csr_wdata_i[1:0];   // ignore high bits
          12'h7A1: begin
            // Writes to the type/dmode field are ignored (RO).  Hit bit (10) is
            // RW1C: writing 1 clears it.
            triggers_q[tselect_q].m       <= csr_wdata_i[6];
            triggers_q[tselect_q].execute <= csr_wdata_i[3];
            triggers_q[tselect_q].store   <= csr_wdata_i[2];
            triggers_q[tselect_q].load    <= csr_wdata_i[1];
            if (csr_wdata_i[10]) triggers_q[tselect_q].hit <= 1'b0;
          end
          12'h7A2: triggers_q[tselect_q].tdata2 <= csr_wdata_i;
          // 12'h7A3, 12'h7A4: read-only / reserved — ignore
          default: ;
        endcase
      end
    end
  end

endmodule
