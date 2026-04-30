// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Radix-2 restoring binary long-division core for IEEE 754 significands.
//
// Implements the exact algorithm from srt_divide.py:
//   1. FIRST cycle: compare a >= b, emit integer quotient bit.
//   2. CMP/UPD cycle pairs: shift partial remainder left, compare (CMP),
//      then conditionally subtract (UPD), emitting fractional bits.
//   3. n = 27 for single (fmt_d_i=0), n = 56 for double (fmt_d_i=1).
//
// Inputs are pre-normalized 53-bit significands (bit 52 = hidden 1).
// Output is a 56-bit raw quotient (27-bit meaningful for single) and a sticky
// bit indicating whether the final partial remainder is non-zero.

module kronos_fpu_fdiv_core
  import kronos_pkg::*;
(
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
  // Constants
  // -------------------------------------------------------------------------
  // N = mantissa width + 4 guard bits (3 fractional + 1 integer)
  localparam int unsigned N_S = FP_S_MANT_W + 4;  // 27 iterations for single
  localparam int unsigned N_D = FP_D_MANT_W + 4;  // 56 iterations for double

  // -------------------------------------------------------------------------
  // FSM encoding
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE  = 3'b000,
    ST_FIRST = 3'b001,
    ST_CMP   = 3'b010,
    ST_UPD   = 3'b011,
    ST_DONE  = 3'b100
  } state_e;

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  state_e        state_q;
  logic [53:0]   p_q;         // partial remainder (54 bits: 2*p can reach 54 bits)
  logic [52:0]   b_q;         // latched divisor
  logic [55:0]   q_q;         // quotient shift register
  logic [5:0]    ctr_q;       // iteration counter
  logic          fmt_d_q;     // latched format
  logic [53:0]   p_shift_q;   // registered p_q shifted left by 1
  logic          ge_q;        // registered comparison result

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  state_e        state_d;
  logic [53:0]   p_d;
  logic [55:0]   q_d;
  logic [5:0]    ctr_d;
  logic [53:0]   p_shift;     // 2 * p_q (left-shifted partial remainder)
  logic          ge;          // p >= b comparison result
  logic [5:0]    target;      // iteration count for current format

  // -------------------------------------------------------------------------
  // Target selection
  // -------------------------------------------------------------------------
  assign target = fmt_d_q ? 6'(N_D) : 6'(N_S);

  // -------------------------------------------------------------------------
  // Combinational next-state and datapath
  // -------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    p_d     = p_q;
    q_d     = q_q;
    ctr_d   = ctr_q;
    ge      = 1'b0;
    p_shift = 54'h0;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) state_d = ST_FIRST;
      end

      ST_FIRST: begin
        ge = (p_q >= {1'b0, b_q});
        if (ge) begin
          q_d = 56'd1;
          p_d = p_q - {1'b0, b_q};
        end else begin
          q_d = 56'd0;
          p_d = p_q;
        end
        ctr_d   = 6'd1;
        state_d = ST_CMP;
      end

      ST_CMP: begin
        p_shift = {p_q[52:0], 1'b0};
        ge      = (p_shift >= {1'b0, b_q});
        state_d = ST_UPD;
      end

      ST_UPD: begin
        if (ge_q) begin
          q_d = {q_q[54:0], 1'b1};
          p_d = p_shift_q - {1'b0, b_q};
        end else begin
          q_d = {q_q[54:0], 1'b0};
          p_d = p_shift_q;
        end
        ctr_d = ctr_q + 6'd1;
        if (ctr_d == target) state_d = ST_DONE;
        else                  state_d = ST_CMP;
      end

      ST_DONE: begin
        state_d = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase

    if (flush_i) begin
      state_d = ST_IDLE;
    end
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      p_q       <= 54'h0;
      b_q       <= 53'h0;
      q_q       <= 56'h0;
      ctr_q     <= 6'h0;
      fmt_d_q   <= 1'b0;
      p_shift_q <= 54'h0;
      ge_q      <= 1'b0;
    end else begin
      state_q <= state_d;
      p_q     <= p_d;
      q_q     <= q_d;
      ctr_q   <= ctr_d;

      if (state_q == ST_CMP) begin
        p_shift_q <= p_shift;
        ge_q      <= ge;
      end

      if (start_i && (state_q == ST_IDLE)) begin
        p_q     <= {1'b0, a_i};
        b_q     <= b_i;
        q_q     <= 56'h0;
        ctr_q   <= 6'h0;
        fmt_d_q <= fmt_d_i;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  assign done_o   = (state_q == ST_DONE);
  assign quot_o   = q_q;
  assign rem_nz_o = (p_q != 54'h0);

endmodule
