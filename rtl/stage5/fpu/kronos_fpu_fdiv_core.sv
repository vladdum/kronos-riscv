// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Radix-2 restoring binary long-division core for IEEE 754 significands.
//
// Implements the exact algorithm from srt_divide.py:
//   1. FIRST cycle: compare a >= b, emit integer quotient bit.
//   2. RUN cycles: shift partial remainder left, compare, emit fractional bits.
//   3. n = 27 for single (fmt_d_i=0), n = 56 for double (fmt_d_i=1).
//
// Inputs are pre-normalized 53-bit significands (bit 52 = hidden 1).
// Output is a 56-bit raw quotient (27-bit meaningful for single) and a sticky
// bit indicating whether the final partial remainder is non-zero.

module kronos_fpu_fdiv_core (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        start_i,
  input  logic        fmt_d_i,   // 0 = S (27 iters), 1 = D (56 iters)
  input  logic [52:0] a_i,       // normalized dividend significand
  input  logic [52:0] b_i,       // normalized divisor significand
  output logic        done_o,
  output logic [55:0] quot_o,
  output logic        rem_nz_o
);

  // -------------------------------------------------------------------------
  // FSM encoding
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE  = 2'b00,
    ST_FIRST = 2'b01,
    ST_RUN   = 2'b10,
    ST_DONE  = 2'b11
  } state_e;

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  localparam int unsigned N_S = 27;
  localparam int unsigned N_D = 56;

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  state_e        state_q;
  logic [53:0]   p_q;       // partial remainder (54 bits: 2*p can reach 54 bits)
  logic [52:0]   b_q;       // latched divisor
  logic [55:0]   q_q;       // quotient shift register
  logic [5:0]    ctr_q;     // iteration counter
  logic          fmt_d_q;   // latched format

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  state_e        state_n;
  logic [53:0]   p_n;
  logic [55:0]   q_n;
  logic [5:0]    ctr_n;
  logic [53:0]   p_shift;   // 2 * p_q (left-shifted partial remainder)
  logic          ge;        // p >= b comparison result
  logic [5:0]    target;    // iteration count for current format

  // -------------------------------------------------------------------------
  // Target selection
  // -------------------------------------------------------------------------
  assign target = fmt_d_q ? 6'(N_D) : 6'(N_S);

  // -------------------------------------------------------------------------
  // Combinational next-state and datapath
  // -------------------------------------------------------------------------
  always_comb begin
    state_n = state_q;
    p_n     = p_q;
    q_n     = q_q;
    ctr_n   = ctr_q;
    ge      = 1'b0;
    p_shift = '0;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) begin
          state_n = ST_FIRST;
        end
      end

      ST_FIRST: begin
        // Integer bit: if p >= b, quotient bit = 1 and subtract.
        ge = (p_q >= {1'b0, b_q});
        if (ge) begin
          q_n = 56'd1;
          p_n = p_q - {1'b0, b_q};
        end else begin
          q_n = 56'd0;
          p_n = p_q;
        end
        ctr_n   = 6'd1;
        state_n = ST_RUN;
      end

      ST_RUN: begin
        // Shift partial remainder left by 1.
        p_shift = {p_q[52:0], 1'b0};
        ge      = (p_shift >= {1'b0, b_q});
        if (ge) begin
          q_n = {q_q[54:0], 1'b1};
          p_n = p_shift - {1'b0, b_q};
        end else begin
          q_n = {q_q[54:0], 1'b0};
          p_n = p_shift;
        end
        ctr_n = ctr_q + 6'd1;
        if (ctr_n == target) begin
          state_n = ST_DONE;
        end
      end

      ST_DONE: begin
        state_n = ST_IDLE;
      end

      default: begin
        state_n = ST_IDLE;
      end
    endcase

    if (flush_i) begin
      state_n = ST_IDLE;
    end
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      p_q     <= '0;
      b_q     <= '0;
      q_q     <= '0;
      ctr_q   <= '0;
      fmt_d_q <= 1'b0;
    end else begin
      state_q <= state_n;
      p_q     <= p_n;
      q_q     <= q_n;
      ctr_q   <= ctr_n;

      // Latch inputs and clear scratch state on start.
      if (start_i && (state_q == ST_IDLE)) begin
        p_q     <= {1'b0, a_i};
        b_q     <= b_i;
        q_q     <= '0;
        ctr_q   <= '0;
        fmt_d_q <= fmt_d_i;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  assign done_o   = (state_q == ST_DONE);
  assign quot_o   = q_q;
  assign rem_nz_o = (p_q != '0);

endmodule
