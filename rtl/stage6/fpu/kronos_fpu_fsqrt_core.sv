// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Radix-2 digit-by-digit square root core for IEEE 754 significands.
//
// Implements the exact algorithm from srt_sqrt.py:
//   - Input: pre-normalized significand a in [1<<52, 1<<54).
//     Even exponent: a in [1<<52, 1<<53), bit 52 set.
//     Odd exponent:  a in [1<<53, 1<<54), bit 53 set.
//   - Runs total = n + 26 iterations (82 for D, 53 for S).
//   - Output: n-bit root Q = q >> 26, sticky = |q[25:0] | |r.
//
// Cycle count: 2*total + 1 (165 for D, 107 for S).
// Each iteration is split into two clock cycles:
//   ST_CMP (phase A): compute r_shifted, trial, ge — register results
//   ST_UPD (phase B): use registered results to update r_q and q_q

module kronos_fpu_fsqrt_core (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        start_i,
  input  logic        fmt_d_i,   // 0 = S (53 iters), 1 = D (82 iters)
  input  logic [53:0] a_i,       // normalized significand (53 or 54 bits)
  output logic        done_o,
  output logic [55:0] quot_o,    // n-bit root (56 for D, 27 for S)
  output logic        rem_nz_o   // sticky
);

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  localparam int unsigned TOTAL_S = 53;  // n=27 + 26
  localparam int unsigned TOTAL_D = 82;  // n=56 + 26
  localparam int unsigned Q_W     = 82;  // max q width (total_D iterations)
  localparam int unsigned R_W     = 84;  // r < trial < 2^83, use 84 bits

  // -------------------------------------------------------------------------
  // FSM encoding
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE = 2'b00,
    ST_CMP  = 2'b01,
    ST_UPD  = 2'b10,
    ST_DONE = 2'b11
  } state_e;

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  state_e           state_q;
  logic [R_W-1:0]   r_q;         // partial remainder
  logic [Q_W-1:0]   q_q;         // running root
  logic [53:0]       a_q;         // latched input significand
  logic [6:0]        ctr_q;       // iteration counter (0..81)
  logic              fmt_d_q;     // latched format
  logic [R_W-1:0]   r_shifted_q; // registered shift result from ST_CMP
  logic [R_W-1:0]   trial_q;     // registered trial value from ST_CMP
  logic              ge_q;        // registered comparison result from ST_CMP

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  state_e           state_d;
  logic [R_W-1:0]   r_d;
  logic [Q_W-1:0]   q_d;
  logic [6:0]        ctr_d;
  logic [1:0]        pair;        // 2-bit input pair for current iteration
  logic [R_W-1:0]   r_shifted;   // r << 2 | pair
  logic [R_W-1:0]   trial;       // (q << 2) | 1
  logic              ge;          // r_shifted >= trial
  logic [6:0]        target;      // total iterations for current format

  // -------------------------------------------------------------------------
  // Target selection
  // -------------------------------------------------------------------------
  assign target = fmt_d_q ? 7'(TOTAL_D) : 7'(TOTAL_S);

  // -------------------------------------------------------------------------
  // Input pair extraction
  //
  // a_padded = a << (2*total - 54). At iteration i, the 2-bit pair from
  // a_padded is at position 2*(total-1-i). Mapping back to a:
  //   offset = 2*(total-1-i) - (2*total - 54) = 52 - 2*i
  // So pair = a[53-2*i : 52-2*i] when 52-2*i >= 0, else 0.
  // -------------------------------------------------------------------------
  always_comb begin
    pair = 2'b00;
    // 52 - 2*ctr_q >= 0  =>  ctr_q <= 26
    if (ctr_q <= 7'd26) begin
      // Bit index: 53 - 2*ctr_q. For ctr_q=0: bits [53:52].
      // For ctr_q=26: bits [1:0].
      unique case (ctr_q)
        7'd0:  pair = a_q[53:52];
        7'd1:  pair = a_q[51:50];
        7'd2:  pair = a_q[49:48];
        7'd3:  pair = a_q[47:46];
        7'd4:  pair = a_q[45:44];
        7'd5:  pair = a_q[43:42];
        7'd6:  pair = a_q[41:40];
        7'd7:  pair = a_q[39:38];
        7'd8:  pair = a_q[37:36];
        7'd9:  pair = a_q[35:34];
        7'd10: pair = a_q[33:32];
        7'd11: pair = a_q[31:30];
        7'd12: pair = a_q[29:28];
        7'd13: pair = a_q[27:26];
        7'd14: pair = a_q[25:24];
        7'd15: pair = a_q[23:22];
        7'd16: pair = a_q[21:20];
        7'd17: pair = a_q[19:18];
        7'd18: pair = a_q[17:16];
        7'd19: pair = a_q[15:14];
        7'd20: pair = a_q[13:12];
        7'd21: pair = a_q[11:10];
        7'd22: pair = a_q[9:8];
        7'd23: pair = a_q[7:6];
        7'd24: pair = a_q[5:4];
        7'd25: pair = a_q[3:2];
        7'd26: pair = a_q[1:0];
        default: pair = 2'b00;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Combinational next-state and datapath
  // -------------------------------------------------------------------------
  always_comb begin
    state_d   = state_q;
    r_d       = r_q;
    q_d       = q_q;
    ctr_d     = ctr_q;
    ge        = 1'b0;
    r_shifted = {R_W{1'b0}};
    trial     = {R_W{1'b0}};

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) state_d = ST_CMP;
      end

      ST_CMP: begin
        // Phase A: compute shift, trial, and comparison — results registered
        r_shifted = {r_q[R_W-3:0], pair};
        trial     = {q_q, 2'b01} & {R_W{1'b1}};
        ge        = (r_shifted >= trial);
        state_d   = ST_UPD;
      end

      ST_UPD: begin
        // Phase B: use registered phase-A results to update r_q and q_q
        if (ge_q) begin
          r_d = r_shifted_q - trial_q;
          q_d = {q_q[Q_W-2:0], 1'b1};
        end else begin
          r_d = r_shifted_q;
          q_d = {q_q[Q_W-2:0], 1'b0};
        end
        ctr_d = ctr_q + 7'd1;
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
      state_q     <= ST_IDLE;
      r_q         <= {R_W{1'b0}};
      q_q         <= {Q_W{1'b0}};
      a_q         <= 54'h0;
      ctr_q       <= 7'h0;
      fmt_d_q     <= 1'b0;
      r_shifted_q <= {R_W{1'b0}};
      trial_q     <= {R_W{1'b0}};
      ge_q        <= 1'b0;
    end else begin
      state_q <= state_d;

      // Capture phase-A results at end of ST_CMP cycle
      if (state_q == ST_CMP) begin
        r_shifted_q <= r_shifted;
        trial_q     <= trial;
        ge_q        <= ge;
      end

      // Latch inputs and clear scratch state on start; otherwise advance the
      // datapath registers from the combinational next-state.
      if (start_i && (state_q == ST_IDLE)) begin
        a_q     <= a_i;
        fmt_d_q <= fmt_d_i;
        r_q     <= {R_W{1'b0}};
        q_q     <= {Q_W{1'b0}};
        ctr_q   <= 7'h0;
      end else begin
        r_q   <= r_d;
        q_q   <= q_d;
        ctr_q <= ctr_d;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Outputs
  //
  // Q = q_q >> 26.  For D (total=82): q_q has 82 bits, Q = q_q[81:26] (56 bits).
  // For S (total=53): q_q has 53 meaningful bits, Q = q_q[52:26] (27 bits),
  // zero-extended to 56 bits.
  // sticky = |q_q[25:0] | |r_q
  // -------------------------------------------------------------------------
  assign done_o   = (state_q == ST_DONE);
  assign quot_o   = fmt_d_q ? q_q[81:26] : {29'd0, q_q[52:26]};
  assign rem_nz_o = (|q_q[25:0]) | (|r_q);

endmodule
