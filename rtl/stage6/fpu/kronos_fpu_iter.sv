// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Iterative FPU wrapper for FDIV and FSQRT.
//
// FSM: IDLE -> UNPACK1 -> UNPACK2 -> ITER -> ROUND1 -> ROUND2 -> PACK -> IDLE
//
// IDLE:    Latch raw inputs on in_valid_i.
// UNPACK1: Classify operands (CLZ, NaN/inf/subnorm flags), normalize
//          significands, compute unbiased true exponents and specials.
// UNPACK2: Compute biased result exponent (FDIV: a_true - b_true + bias;
//          FSQRT: asr(a_true) + bias). Specials bypass to PACK.
// ITER:    Wait for fdiv/fsqrt core done signal.
// ROUND1:  Post-norm shift + mantissa/GRS extract + tininess detect +
//          subnormal right-shift.
// ROUND2:  Rounding decision + 53-bit rounding adder + overflow detect +
//          pack into result_q/fflags_q. Reserves the writeback slot via
//          the scoreboard's late-grant interface and stalls until granted.
// PACK:    Drive out_valid_o, hand result/fflags/tag to the output mux.

module kronos_fpu_iter
  import kronos_pkg::*;
(
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            flush_i,

  input  logic            in_valid_i,
  input  fp_op_e          op_i,
  input  logic            fmt_d_i,
  input  logic [2:0]      rm_i,
  input  logic [kronos_pkg::FLEN-1:0] a_i,
  input  logic [kronos_pkg::FLEN-1:0] b_i,
  input  fpu_tag_t        tag_i,

  output logic            busy_o,
  output logic            out_valid_o,
  output logic [kronos_pkg::FLEN-1:0] result_o,
  output logic [4:0]      fflags_o,
  output fpu_tag_t        tag_o,

  // Late-reservation handshake to scoreboard (request slot, wait for grant).
  output logic            sb_late_req_o,
  output logic            sb_late_fp_dest_o,
  input  logic            sb_late_grant_i
);

  // -----------------------------------------------------------------------
  // 1. Constants
  // -----------------------------------------------------------------------
  // Canonical bit patterns for double precision
  localparam logic [kronos_pkg::FLEN-1:0] D_QNAN  = 64'h7FF8_0000_0000_0000;
  localparam logic [kronos_pkg::FLEN-1:0] D_PINF  = 64'h7FF0_0000_0000_0000;
  localparam logic [kronos_pkg::FLEN-1:0] D_NINF  = 64'hFFF0_0000_0000_0000;
  localparam logic [kronos_pkg::FLEN-1:0] D_PZERO = {kronos_pkg::FLEN{1'b0}};
  localparam logic [kronos_pkg::FLEN-1:0] D_NZERO = 64'h8000_0000_0000_0000;

  // Canonical bit patterns for single precision (NaN-boxed to 64 bits)
  localparam logic [kronos_pkg::FLEN-1:0] S_QNAN  = {kronos_pkg::FP_NANBOX_UPPER, 32'h7FC0_0000};
  localparam logic [kronos_pkg::FLEN-1:0] S_PINF  = {kronos_pkg::FP_NANBOX_UPPER, 32'h7F80_0000};
  localparam logic [kronos_pkg::FLEN-1:0] S_NINF  = {kronos_pkg::FP_NANBOX_UPPER, 32'hFF80_0000};
  localparam logic [kronos_pkg::FLEN-1:0] S_PZERO = {kronos_pkg::FP_NANBOX_UPPER, 32'h0000_0000};
  localparam logic [kronos_pkg::FLEN-1:0] S_NZERO = {kronos_pkg::FP_NANBOX_UPPER, 32'h8000_0000};

  // Flag bits
  localparam logic [4:0] FL_NV = 5'(1) << kronos_pkg::FP_FFLAG_NV;
  localparam logic [4:0] FL_DZ = 5'(1) << kronos_pkg::FP_FFLAG_DZ;

  // -----------------------------------------------------------------------
  // 2. Types
  // -----------------------------------------------------------------------
  // FSM states
  typedef enum logic [2:0] {
    IDLE    = 3'd0,
    UNPACK1 = 3'd1,
    UNPACK2 = 3'd2,
    ITER    = 3'd3,
    ROUND1  = 3'd4,
    ROUND2  = 3'd5,
    PACK    = 3'd6
  } state_e;

  // Operand classification
  typedef struct packed {
    logic        sign;
    logic [10:0] exp;       // biased exponent (11 bits covers both S and D)
    logic [51:0] sig;       // raw significand (no implicit 1)
    logic        is_zero;
    logic        is_subnorm;
    logic        is_inf;
    logic        is_snan;
    logic        is_qnan;
    logic        is_normal;
    logic [5:0]  clz;       // leading zeros of significand (for subnormals)
  } fp_class_t;

  // -----------------------------------------------------------------------
  // CLZ function for 53-bit significand (bit 52 = implicit 1 position)
  // -----------------------------------------------------------------------
  function automatic logic [5:0] clz53(input logic [52:0] x);
    for (int i = 52; i >= 0; i--) begin
      if (x[i]) return 6'd52 - i[5:0];
    end
    return 6'd53;
  endfunction

  // -----------------------------------------------------------------------
  // 3. State registers
  // -----------------------------------------------------------------------
  state_e             state_q;
  logic               iter_busy_q;  // look-ahead flop of (state_d != IDLE); breaks deep busy_o cone

  // Latched raw inputs (IDLE -> UNPACK1)
  fp_op_e             op_q;
  logic               fmt_d_q;
  logic [2:0]         rm_q;
  fpu_tag_t           tag_q;
  logic [kronos_pkg::FLEN-1:0]    a_raw_q;
  logic [kronos_pkg::FLEN-1:0]    b_raw_q;

  // Classified operands (registered in UNPACK1 -> UNPACK2 transition)
  fp_class_t          a_class_q;
  fp_class_t          b_class_q;

  // Normalized operands (latched UNPACK1 -> UNPACK2)
  logic [52:0]        a_norm_q;     // fdiv: 53-bit normalized sig
  logic [52:0]        b_norm_q;     // fdiv: 53-bit normalized sig
  logic [53:0]        a_sqrt_q;     // fsqrt: 54-bit normalized sig

  // Unbiased true exponents (latched UNPACK1 -> UNPACK2)
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] a_true_exp_q;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] b_true_exp_q;

  // Specials result/flags latched in UNPACK1, consumed in UNPACK2
  logic               is_special_q;
  logic [kronos_pkg::FLEN-1:0]    special_result_q;
  logic [4:0]         special_fflags_q;

  // Final biased result exponent + sign (computed in UNPACK2 combinationally,
  // latched UNPACK2 -> ITER into result_sign_q / result_exp_q)
  logic               result_sign_q;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] result_exp_q;        // signed intermediate exponent

  // Raw quotient from core (latched on core_done)
  logic [55:0]        raw_q;
  logic               raw_sticky_q;

  // ROUND1 -> ROUND2 latches (timing-closure split: see proc_round1_latch)
  logic [51:0]        rnd_mant_shifted_q;
  logic               rnd_new_lsb_q;
  logic               rnd_new_g_q;
  logic               rnd_new_r_q;
  logic               rnd_new_s_q;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] rnd_final_exp_q;
  logic               rnd_tiny_q;

  // core_start: delayed by one cycle from UNPACK2 -> ITER so that
  // a_norm_q / b_norm_q / a_sqrt_q are already latched when the core
  // samples start_i.  High for exactly one clock in the first ITER cycle.
  logic               core_start_q;

  // Result / fflags registers
  logic [kronos_pkg::FLEN-1:0]    result_q;
  logic [4:0]         fflags_q;

  // -----------------------------------------------------------------------
  // 4. Combinational signals
  // -----------------------------------------------------------------------
  state_e             state_d;
  fp_class_t          a_class;
  fp_class_t          b_class;

  // Specials
  logic               is_special;
  logic [kronos_pkg::FLEN-1:0]    special_result;
  logic [4:0]         special_fflags;
  logic               sp_result_sign;
  logic [kronos_pkg::FLEN-1:0]    sp_qnan;
  logic [kronos_pkg::FLEN-1:0]    sp_pinf;
  logic [kronos_pkg::FLEN-1:0]    sp_ninf;
  logic [kronos_pkg::FLEN-1:0]    sp_pzero;
  logic [kronos_pkg::FLEN-1:0]    sp_nzero;
  logic [kronos_pkg::FLEN-1:0]    sp_signed_inf;
  logic [kronos_pkg::FLEN-1:0]    sp_signed_zero;
  logic               sp_a_nan;
  logic               sp_b_nan;
  logic               sp_any_snan;
  logic               sp_any_nan;

  // Normalization
  logic [52:0]        a_norm;       // fdiv normalized significand
  logic [52:0]        b_norm;       // fdiv normalized significand
  logic [53:0]        a_sqrt;       // fsqrt normalized significand
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] a_true_exp;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] b_true_exp;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] bias;

  // UNPACK2 result-exp / sign
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] result_exp_comb;    // biased result exponent
  logic               result_sign_comb;   // result sign

  // ROUND state - rounding logic (combinational)
  logic [kronos_pkg::FLEN-1:0]    round_result;
  logic [4:0]         round_fflags;

  // Post-normalization shift signals
  logic [55:0]        rnd_shifted;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] rnd_adj_exp;
  logic               rnd_sticky_shift;

  // Mantissa extraction
  logic [51:0]        rnd_mantissa;
  logic               rnd_lsb;
  logic               rnd_g;
  logic               rnd_r;
  logic               rnd_s;

  // Tininess and subnormal shift
  logic               rnd_tiny;
  logic [51:0]        rnd_mant_shifted;
  logic               rnd_new_lsb;
  logic               rnd_new_g;
  logic               rnd_new_r;
  logic               rnd_new_s;
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] rnd_final_exp;
  logic [6:0]         rnd_shift_amt;
  logic [55:0]        rnd_combined_d;
  logic [55:0]        rnd_shifted_out_d;
  logic [55:0]        rnd_combined_shifted_d;
  logic [26:0]        rnd_combined_s;
  logic [26:0]        rnd_shifted_out_s;
  logic [26:0]        rnd_combined_shifted_s;

  // Rounding decision
  logic               rnd_round_up;
  logic               rnd_inexact;

  // Rounded mantissa
  logic [52:0]        rnd_rounded_mant;
  logic               rnd_carry;

  // Pack helpers (hoisted out of inner begin block)
  logic signed [kronos_pkg::FP_EXP_EXT_W-1:0] rnd_exp_pack;
  logic [52:0]        rnd_mant_pack;

  // Overflow
  logic               rnd_overflow;
  logic               rnd_overflow_to_inf;
  logic               rnd_to_max;

  // Flags
  logic               rnd_uf;
  logic               rnd_of;
  logic               rnd_nx;

  // FDIV normalization helper
  logic               rnd_need_shift;

  // -----------------------------------------------------------------------
  // 5. Submodule interface signals
  // -----------------------------------------------------------------------
  logic               core_start;
  logic               core_done_div;
  logic               core_done_sqrt;
  logic [55:0]        q_div;
  logic [55:0]        q_sqrt;
  logic               rem_nz_div;
  logic               rem_nz_sqrt;

  // Mux of core outputs
  logic [55:0]        raw;
  logic               raw_sticky;
  logic               core_done;

  // -----------------------------------------------------------------------
  // Operand classify (combinational, used in UNPACK1)
  // Reads from a_raw_q / b_raw_q (latched in IDLE)
  // -----------------------------------------------------------------------
  always_comb begin : proc_classify_a
    a_class = '{default: '0};
    if (fmt_d_q) begin
      // Double precision
      a_class.sign = a_raw_q[63];
      a_class.exp  = a_raw_q[62:52];
      a_class.sig  = a_raw_q[51:0];
    end else begin
      // Single precision -- check NaN-boxing
      if (a_raw_q[63:32] == kronos_pkg::FP_NANBOX_UPPER) begin
        a_class.sign = a_raw_q[31];
        a_class.exp  = {3'b0, a_raw_q[30:23]};
        a_class.sig  = {a_raw_q[22:0], 29'b0};
      end else begin
        // Not properly NaN-boxed: treat as canonical qNaN
        a_class.sign    = 1'b0;
        a_class.exp     = kronos_pkg::FP_D_EXP_MAX;
        a_class.sig     = {1'b1, 51'b0};
        a_class.is_qnan = 1'b1;
      end
    end

    // Classification (only if not already forced to qNaN by NaN-box check)
    if (!a_class.is_qnan) begin
      if (fmt_d_q) begin
        a_class.is_zero    = (a_class.exp == 11'h000) && (a_class.sig == {kronos_pkg::FP_D_MANT_W{1'b0}});
        a_class.is_subnorm = (a_class.exp == 11'h000) && (a_class.sig != {kronos_pkg::FP_D_MANT_W{1'b0}});
        a_class.is_inf     = (a_class.exp == kronos_pkg::FP_D_EXP_MAX) && (a_class.sig == {kronos_pkg::FP_D_MANT_W{1'b0}});
        a_class.is_snan    = (a_class.exp == kronos_pkg::FP_D_EXP_MAX) && (a_class.sig != {kronos_pkg::FP_D_MANT_W{1'b0}})
                             && !a_class.sig[51];
        a_class.is_qnan    = (a_class.exp == kronos_pkg::FP_D_EXP_MAX) && a_class.sig[51];
        a_class.is_normal  = !a_class.is_zero && !a_class.is_subnorm
                             && !a_class.is_inf && !a_class.is_snan
                             && !a_class.is_qnan;
      end else begin
        // Single: exponent is in [7:0] of a_class.exp, sig in [51:29]
        a_class.is_zero    = (a_class.exp[7:0] == 8'h00)
                             && (a_class.sig[51:29] == {kronos_pkg::FP_S_MANT_W{1'b0}});
        a_class.is_subnorm = (a_class.exp[7:0] == 8'h00)
                             && (a_class.sig[51:29] != {kronos_pkg::FP_S_MANT_W{1'b0}});
        a_class.is_inf     = (a_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && (a_class.sig[51:29] == {kronos_pkg::FP_S_MANT_W{1'b0}});
        a_class.is_snan    = (a_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && (a_class.sig[51:29] != {kronos_pkg::FP_S_MANT_W{1'b0}})
                             && !a_class.sig[51];
        a_class.is_qnan    = (a_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && a_class.sig[51];
        a_class.is_normal  = !a_class.is_zero && !a_class.is_subnorm
                             && !a_class.is_inf && !a_class.is_snan
                             && !a_class.is_qnan;
      end
    end

    // CLZ for subnormals
    if (fmt_d_q) begin
      a_class.clz = clz53({1'b0, a_class.sig});
    end else begin
      a_class.clz = clz53({1'b0, a_class.sig[51:29], 29'b0});
    end
  end

  always_comb begin : proc_classify_b
    b_class = '{default: '0};
    if (fmt_d_q) begin
      // Double precision
      b_class.sign = b_raw_q[63];
      b_class.exp  = b_raw_q[62:52];
      b_class.sig  = b_raw_q[51:0];
    end else begin
      // Single precision -- check NaN-boxing
      if (b_raw_q[63:32] == kronos_pkg::FP_NANBOX_UPPER) begin
        b_class.sign = b_raw_q[31];
        b_class.exp  = {3'b0, b_raw_q[30:23]};
        b_class.sig  = {b_raw_q[22:0], 29'b0};
      end else begin
        // Not properly NaN-boxed: treat as canonical qNaN
        b_class.sign    = 1'b0;
        b_class.exp     = kronos_pkg::FP_D_EXP_MAX;
        b_class.sig     = {1'b1, 51'b0};
        b_class.is_qnan = 1'b1;
      end
    end

    // Classification
    if (!b_class.is_qnan) begin
      if (fmt_d_q) begin
        b_class.is_zero    = (b_class.exp == 11'h000) && (b_class.sig == {kronos_pkg::FP_D_MANT_W{1'b0}});
        b_class.is_subnorm = (b_class.exp == 11'h000) && (b_class.sig != {kronos_pkg::FP_D_MANT_W{1'b0}});
        b_class.is_inf     = (b_class.exp == kronos_pkg::FP_D_EXP_MAX) && (b_class.sig == {kronos_pkg::FP_D_MANT_W{1'b0}});
        b_class.is_snan    = (b_class.exp == kronos_pkg::FP_D_EXP_MAX) && (b_class.sig != {kronos_pkg::FP_D_MANT_W{1'b0}})
                             && !b_class.sig[51];
        b_class.is_qnan    = (b_class.exp == kronos_pkg::FP_D_EXP_MAX) && b_class.sig[51];
        b_class.is_normal  = !b_class.is_zero && !b_class.is_subnorm
                             && !b_class.is_inf && !b_class.is_snan
                             && !b_class.is_qnan;
      end else begin
        // Single: exponent is in [7:0] of b_class.exp, sig in [51:29]
        b_class.is_zero    = (b_class.exp[7:0] == 8'h00)
                             && (b_class.sig[51:29] == {kronos_pkg::FP_S_MANT_W{1'b0}});
        b_class.is_subnorm = (b_class.exp[7:0] == 8'h00)
                             && (b_class.sig[51:29] != {kronos_pkg::FP_S_MANT_W{1'b0}});
        b_class.is_inf     = (b_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && (b_class.sig[51:29] == {kronos_pkg::FP_S_MANT_W{1'b0}});
        b_class.is_snan    = (b_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && (b_class.sig[51:29] != {kronos_pkg::FP_S_MANT_W{1'b0}})
                             && !b_class.sig[51];
        b_class.is_qnan    = (b_class.exp[7:0] == kronos_pkg::FP_S_EXP_MAX)
                             && b_class.sig[51];
        b_class.is_normal  = !b_class.is_zero && !b_class.is_subnorm
                             && !b_class.is_inf && !b_class.is_snan
                             && !b_class.is_qnan;
      end
    end

    // CLZ for subnormals
    if (fmt_d_q) begin
      b_class.clz = clz53({1'b0, b_class.sig});
    end else begin
      b_class.clz = clz53({1'b0, b_class.sig[51:29], 29'b0});
    end
  end

  // -----------------------------------------------------------------------
  // Specials short-circuit (combinational, used in UNPACK1)
  // -----------------------------------------------------------------------
  always_comb begin : proc_specials
    is_special     = 1'b0;
    special_result = {kronos_pkg::FLEN{1'b0}};
    special_fflags = 5'h0;
    sp_result_sign = 1'b0;
    sp_qnan        = {kronos_pkg::FLEN{1'b0}};
    sp_pinf        = {kronos_pkg::FLEN{1'b0}};
    sp_ninf        = {kronos_pkg::FLEN{1'b0}};
    sp_pzero       = {kronos_pkg::FLEN{1'b0}};
    sp_nzero       = {kronos_pkg::FLEN{1'b0}};
    sp_signed_inf  = {kronos_pkg::FLEN{1'b0}};
    sp_signed_zero = {kronos_pkg::FLEN{1'b0}};
    sp_a_nan       = 1'b0;
    sp_b_nan       = 1'b0;
    sp_any_snan    = 1'b0;
    sp_any_nan     = 1'b0;

    // Result sign for FDIV: sign_a XOR sign_b; for FSQRT: sign_a
    sp_result_sign = (op_q == FP_FDIV) ? (a_class.sign ^ b_class.sign)
                                       : a_class.sign;

    // Helper: select pattern based on format and sign
    sp_qnan  = fmt_d_q ? D_QNAN  : S_QNAN;
    sp_pinf  = fmt_d_q ? D_PINF  : S_PINF;
    sp_ninf  = fmt_d_q ? D_NINF  : S_NINF;
    sp_pzero = fmt_d_q ? D_PZERO : S_PZERO;
    sp_nzero = fmt_d_q ? D_NZERO : S_NZERO;
    sp_signed_inf  = sp_result_sign ? sp_ninf  : sp_pinf;
    sp_signed_zero = sp_result_sign ? sp_nzero : sp_pzero;

    // Any NaN input (sNaN or qNaN in either operand)
    sp_a_nan    = a_class.is_snan || a_class.is_qnan;
    sp_b_nan    = (op_q == FP_FDIV) && (b_class.is_snan || b_class.is_qnan);
    sp_any_snan = a_class.is_snan
                  || ((op_q == FP_FDIV) && b_class.is_snan);
    sp_any_nan  = sp_a_nan || sp_b_nan;

    if (op_q == FP_FDIV) begin
      // ---- FDIV specials ----
      if (sp_any_snan) begin
        // Any sNaN input -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end else if (sp_any_nan) begin
        // Any qNaN input -> qNaN, no flags
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = 5'h0;
      end else if (a_class.is_zero && b_class.is_zero) begin
        // 0 / 0 -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end else if (a_class.is_inf && b_class.is_inf) begin
        // inf / inf -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end else if (a_class.is_inf) begin
        // inf / x (x finite, incl. zero) -> signed inf, no flags.
        // Must precede b_class.is_zero so inf/0 does NOT raise DZ.
        is_special     = 1'b1;
        special_result = sp_signed_inf;
        special_fflags = 5'h0;
      end else if (b_class.is_zero) begin
        // x / 0 (x finite non-zero) -> signed inf, DZ
        is_special     = 1'b1;
        special_result = sp_signed_inf;
        special_fflags = FL_DZ;
      end else if (a_class.is_zero) begin
        // 0 / x (x finite, non-zero) -> signed zero
        is_special     = 1'b1;
        special_result = sp_signed_zero;
        special_fflags = 5'h0;
      end else if (b_class.is_inf) begin
        // x / inf (x finite) -> signed zero
        is_special     = 1'b1;
        special_result = sp_signed_zero;
        special_fflags = 5'h0;
      end
    end else begin
      // ---- FSQRT specials ----
      if (a_class.is_snan) begin
        // sNaN -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end else if (a_class.is_qnan) begin
        // qNaN -> qNaN
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = 5'h0;
      end else if (a_class.is_zero) begin
        // +0 -> +0, -0 -> -0
        is_special     = 1'b1;
        special_result = a_class.sign ? sp_nzero : sp_pzero;
        special_fflags = 5'h0;
      end else if (a_class.is_inf && !a_class.sign) begin
        // +inf -> +inf
        is_special     = 1'b1;
        special_result = sp_pinf;
        special_fflags = 5'h0;
      end else if (a_class.sign) begin
        // Negative (including -inf, -normal, -subnorm) -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Normalization logic (combinational, used in UNPACK1)
  // -----------------------------------------------------------------------
  always_comb begin : proc_normalize
    a_norm     = 53'h0;
    b_norm     = 53'h0;
    a_sqrt     = 54'h0;
    a_true_exp = {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    b_true_exp = {kronos_pkg::FP_EXP_EXT_W{1'b0}};

    bias = fmt_d_q ? kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_D_BIAS) : kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_S_BIAS);

    // --- Operand A normalization ---
    if (a_class.is_subnorm) begin
      a_true_exp = $signed(kronos_pkg::FP_EXP_EXT_W'(1)) - bias - $signed(kronos_pkg::FP_EXP_EXT_W'(a_class.clz));
      a_norm     = {1'b0, a_class.sig} << a_class.clz;
    end else begin
      a_true_exp = $signed(kronos_pkg::FP_EXP_EXT_W'(a_class.exp)) - bias;
      a_norm     = {1'b1, a_class.sig};
    end

    // --- Operand B normalization (FDIV only; harmless for FSQRT) ---
    if (b_class.is_subnorm) begin
      b_true_exp = $signed(kronos_pkg::FP_EXP_EXT_W'(1)) - bias - $signed(kronos_pkg::FP_EXP_EXT_W'(b_class.clz));
      b_norm     = {1'b0, b_class.sig} << b_class.clz;
    end else begin
      b_true_exp = $signed(kronos_pkg::FP_EXP_EXT_W'(b_class.exp)) - bias;
      b_norm     = {1'b1, b_class.sig};
    end

    // --- FSQRT significand preparation ---
    // Even true exponent: {1'b0, normalized_sig[52:0]} (bit 52 set)
    // Odd true exponent:  {normalized_sig[52:0], 1'b0} (bit 53 set)
    if (a_true_exp[0]) begin
      a_sqrt = {a_norm, 1'b0};
    end else begin
      a_sqrt = {1'b0, a_norm};
    end
  end

  // -----------------------------------------------------------------------
  // proc_result_exp: computes result_exp_comb / result_sign_comb from the
  // REGISTERED a_true_exp_q / b_true_exp_q in UNPACK2. Breaking the combined
  // classify+normalize+exp-compute cone into two cycles is the C4 fix.
  // -----------------------------------------------------------------------
  always_comb begin : proc_result_exp
    result_exp_comb  = {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    result_sign_comb = 1'b0;

    // Result sign: FDIV = sign_a ^ sign_b, FSQRT = 0 (negative caught as special).
    result_sign_comb = (op_q == FP_FDIV)
                       ? (a_class_q.sign ^ b_class_q.sign)
                       : 1'b0;

    if (op_q == FP_FDIV) begin
      // FDIV: result_exp (biased) = (a_true - b_true) + bias
      result_exp_comb = a_true_exp_q - b_true_exp_q
                        + (fmt_d_q ? kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_D_BIAS)
                                   : kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_S_BIAS));
    end else begin
      // FSQRT: result_exp (biased) = floor(a_true / 2) + bias
      // arithmetic right shift by 1 gives floor(x/2) for signed x
      result_exp_comb = (a_true_exp_q >>> 1)
                        + (fmt_d_q ? kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_D_BIAS)
                                   : kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_S_BIAS));
    end
  end

  // -----------------------------------------------------------------------
  // ROUND state - rounding logic stage 1 (combinational)
  // -----------------------------------------------------------------------
  always_comb begin : proc_round1
    // Defaults
    rnd_shifted            = 56'h0;
    rnd_adj_exp            = {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    rnd_sticky_shift       = 1'b0;
    rnd_mantissa           = {kronos_pkg::FP_D_MANT_W{1'b0}};
    rnd_lsb                = 1'b0;
    rnd_g                  = 1'b0;
    rnd_r                  = 1'b0;
    rnd_s                  = 1'b0;
    rnd_tiny               = 1'b0;
    rnd_mant_shifted       = {kronos_pkg::FP_D_MANT_W{1'b0}};
    rnd_new_lsb            = 1'b0;
    rnd_new_g              = 1'b0;
    rnd_new_r              = 1'b0;
    rnd_new_s              = 1'b0;
    rnd_final_exp          = {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    rnd_shift_amt          = 7'h0;
    rnd_combined_d         = 56'h0;
    rnd_shifted_out_d      = 56'h0;
    rnd_combined_shifted_d = 56'h0;
    rnd_combined_s         = 27'h0;
    rnd_shifted_out_s      = 27'h0;
    rnd_combined_shifted_s = 27'h0;
    rnd_need_shift         = 1'b0;

    // ------------------------------------------------------------------
    // 1. Post-normalization shift (FDIV only: if integer bit is 0)
    // ------------------------------------------------------------------
    if (op_q == FP_FDIV) begin
      rnd_need_shift = fmt_d_q ? !raw_q[55] : !raw_q[26];
      if (rnd_need_shift) begin
        rnd_shifted = {raw_q[54:0], raw_sticky_q};
        rnd_adj_exp = result_exp_q - $signed(kronos_pkg::FP_EXP_EXT_W'(1));
        rnd_sticky_shift = 1'b0;
      end else begin
        rnd_shifted = raw_q;
        rnd_adj_exp = result_exp_q;
        rnd_sticky_shift = raw_sticky_q;
      end
    end else begin
      rnd_shifted = raw_q;
      rnd_adj_exp = result_exp_q;
      rnd_sticky_shift = raw_sticky_q;
    end

    // ------------------------------------------------------------------
    // 2. Extract mantissa, G, R, S
    // ------------------------------------------------------------------
    if (fmt_d_q) begin
      rnd_mantissa = rnd_shifted[54:3];
      rnd_lsb      = rnd_shifted[3];
      rnd_g        = rnd_shifted[2];
      rnd_r        = rnd_shifted[1];
      rnd_s        = rnd_sticky_shift | rnd_shifted[0];
    end else begin
      rnd_mantissa = {{(kronos_pkg::FP_D_MANT_W-kronos_pkg::FP_S_MANT_W){1'b0}}, rnd_shifted[25:3]};
      rnd_lsb      = rnd_shifted[3];
      rnd_g        = rnd_shifted[2];
      rnd_r        = rnd_shifted[1];
      rnd_s        = rnd_sticky_shift | rnd_shifted[0];
    end

    // ------------------------------------------------------------------
    // 3. Tininess detection and subnormal shift (before rounding)
    // ------------------------------------------------------------------
    rnd_tiny = (rnd_adj_exp <= $signed({kronos_pkg::FP_EXP_EXT_W{1'b0}}));

    if (rnd_tiny) begin
      if (fmt_d_q) begin
        rnd_shift_amt = (($signed(kronos_pkg::FP_EXP_EXT_W'(1)) - rnd_adj_exp) > 13'sd56)
                        ? 7'd56 : 7'($signed(kronos_pkg::FP_EXP_EXT_W'(1)) - rnd_adj_exp);
      end else begin
        rnd_shift_amt = (($signed(kronos_pkg::FP_EXP_EXT_W'(1)) - rnd_adj_exp) > 13'sd27)
                        ? 7'd27 : 7'($signed(kronos_pkg::FP_EXP_EXT_W'(1)) - rnd_adj_exp);
      end

      if (fmt_d_q) begin
        rnd_combined_d = rnd_shifted;
        rnd_shifted_out_d = rnd_combined_d & ((56'd1 << rnd_shift_amt) - 56'd1);
        rnd_combined_shifted_d = rnd_combined_d >> rnd_shift_amt;
        rnd_mant_shifted = rnd_combined_shifted_d[54:3];
        rnd_new_lsb = rnd_combined_shifted_d[3];
        rnd_new_g   = rnd_combined_shifted_d[2];
        rnd_new_r   = rnd_combined_shifted_d[1];
        rnd_new_s   = rnd_s | rnd_combined_shifted_d[0] | (|rnd_shifted_out_d);
      end else begin
        rnd_combined_s = rnd_shifted[26:0];
        rnd_shifted_out_s = rnd_combined_s & ((27'd1 << rnd_shift_amt) - 27'd1);
        rnd_combined_shifted_s = rnd_combined_s >> rnd_shift_amt;
        rnd_mant_shifted = {{(kronos_pkg::FP_D_MANT_W-kronos_pkg::FP_S_MANT_W){1'b0}}, rnd_combined_shifted_s[25:3]};
        rnd_new_lsb = rnd_combined_shifted_s[3];
        rnd_new_g   = rnd_combined_shifted_s[2];
        rnd_new_r   = rnd_combined_shifted_s[1];
        rnd_new_s   = rnd_s | rnd_combined_shifted_s[0] | (|rnd_shifted_out_s);
      end

      rnd_final_exp = $signed({kronos_pkg::FP_EXP_EXT_W{1'b0}});
    end else begin
      rnd_mant_shifted = rnd_mantissa;
      rnd_new_lsb = rnd_lsb;
      rnd_new_g   = rnd_g;
      rnd_new_r   = rnd_r;
      rnd_new_s   = rnd_s;
      rnd_final_exp = rnd_adj_exp;
    end
  end

  // -----------------------------------------------------------------------
  // ROUND1 -> ROUND2 register (latches outputs of proc_round1)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_round1_latch
    if (!rst_ni) begin
      rnd_mant_shifted_q <= {kronos_pkg::FP_D_MANT_W{1'b0}};
      rnd_new_lsb_q      <= 1'b0;
      rnd_new_g_q        <= 1'b0;
      rnd_new_r_q        <= 1'b0;
      rnd_new_s_q        <= 1'b0;
      rnd_final_exp_q    <= {kronos_pkg::FP_EXP_EXT_W{1'b0}};
      rnd_tiny_q         <= 1'b0;
    end else if (state_q == ROUND1) begin
      rnd_mant_shifted_q <= rnd_mant_shifted;
      rnd_new_lsb_q      <= rnd_new_lsb;
      rnd_new_g_q        <= rnd_new_g;
      rnd_new_r_q        <= rnd_new_r;
      rnd_new_s_q        <= rnd_new_s;
      rnd_final_exp_q    <= rnd_final_exp;
      rnd_tiny_q         <= rnd_tiny;
    end
  end

  // -----------------------------------------------------------------------
  // ROUND2 state - rounding decision, 53-bit add, overflow detect, pack
  // Reads ROUND1 latches; writes round_result / round_fflags
  // -----------------------------------------------------------------------
  always_comb begin : proc_round2
    round_result        = {kronos_pkg::FLEN{1'b0}};
    round_fflags        = 5'h0;
    rnd_round_up        = 1'b0;
    rnd_inexact         = 1'b0;
    rnd_rounded_mant    = 53'h0;
    rnd_carry           = 1'b0;
    rnd_exp_pack        = {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    rnd_mant_pack       = 53'h0;
    rnd_overflow        = 1'b0;
    rnd_overflow_to_inf = 1'b0;
    rnd_to_max          = 1'b0;
    rnd_uf              = 1'b0;
    rnd_of              = 1'b0;
    rnd_nx              = 1'b0;

    // ------------------------------------------------------------------
    // 4. Rounding decision
    // ------------------------------------------------------------------
    rnd_inexact = rnd_new_g_q | rnd_new_r_q | rnd_new_s_q;

    unique case (rm_q)
      3'b000:  rnd_round_up = rnd_new_g_q & (rnd_new_lsb_q | rnd_new_r_q | rnd_new_s_q);
      3'b001:  rnd_round_up = 1'b0;
      3'b010:  rnd_round_up = result_sign_q & rnd_inexact;
      3'b011:  rnd_round_up = ~result_sign_q & rnd_inexact;
      3'b100:  rnd_round_up = rnd_new_g_q;
      default: rnd_round_up = 1'b0;
    endcase

    // ------------------------------------------------------------------
    // 5. Add rounding increment
    // ------------------------------------------------------------------
    if (fmt_d_q) begin
      rnd_rounded_mant = {1'b0, rnd_mant_shifted_q} + {{kronos_pkg::FP_D_MANT_W{1'b0}}, rnd_round_up};
    end else begin
      rnd_rounded_mant = {{(kronos_pkg::FP_D_MANT_W+1-kronos_pkg::FP_S_MANT_W){1'b0}}, rnd_mant_shifted_q[22:0]}
                       + {{kronos_pkg::FP_D_MANT_W{1'b0}}, rnd_round_up};
    end

    rnd_carry = fmt_d_q ? rnd_rounded_mant[52] : rnd_rounded_mant[23];

    // Local exponent value - rnd_final_exp_q possibly +1 on carry
    rnd_exp_pack  = rnd_final_exp_q;
    rnd_mant_pack = rnd_rounded_mant;
    if (rnd_carry) begin
      rnd_exp_pack  = rnd_final_exp_q + $signed(kronos_pkg::FP_EXP_EXT_W'(1));
      rnd_mant_pack = 53'h0;
    end

    // ----------------------------------------------------------------
    // 6. Overflow detection
    // ----------------------------------------------------------------
    rnd_overflow = fmt_d_q ? (rnd_exp_pack >= kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_D_EXP_MAX))
                           : (rnd_exp_pack >= kronos_pkg::FP_EXP_EXT_W'(kronos_pkg::FP_S_EXP_MAX));

    if (rnd_overflow) begin
      unique case (rm_q)
        3'b001:  rnd_to_max = 1'b1;
        3'b010:  rnd_to_max = ~result_sign_q;
        3'b011:  rnd_to_max = result_sign_q;
        default: rnd_to_max = 1'b0;
      endcase
    end
    rnd_overflow_to_inf = rnd_overflow & ~rnd_to_max;

    // ----------------------------------------------------------------
    // 7. Flag generation
    // ----------------------------------------------------------------
    rnd_nx = rnd_inexact | rnd_overflow;
    rnd_uf = rnd_tiny_q & rnd_inexact;
    rnd_of = rnd_overflow;
    round_fflags = {1'b0, 1'b0, rnd_of, rnd_uf, rnd_nx};

    // ----------------------------------------------------------------
    // 8. Pack result
    // ----------------------------------------------------------------
    if (rnd_overflow) begin
      if (rnd_overflow_to_inf) begin
        if (fmt_d_q) begin
          round_result = {result_sign_q, kronos_pkg::FP_D_EXP_MAX, {kronos_pkg::FP_D_MANT_W{1'b0}}};
        end else begin
          round_result = {kronos_pkg::FP_NANBOX_UPPER, result_sign_q, kronos_pkg::FP_S_EXP_MAX, {kronos_pkg::FP_S_MANT_W{1'b0}}};
        end
      end else begin
        if (fmt_d_q) begin
          round_result = {result_sign_q, kronos_pkg::FP_D_EXP_PENULT, {kronos_pkg::FP_D_MANT_W{1'b1}}};
        end else begin
          round_result = {kronos_pkg::FP_NANBOX_UPPER, result_sign_q, kronos_pkg::FP_S_EXP_PENULT, {kronos_pkg::FP_S_MANT_W{1'b1}}};
        end
      end
    end else begin
      if (fmt_d_q) begin
        round_result = {result_sign_q, rnd_exp_pack[kronos_pkg::FP_D_EXP_W-1:0], rnd_mant_pack[kronos_pkg::FP_D_MANT_W-1:0]};
      end else begin
        round_result = {kronos_pkg::FP_NANBOX_UPPER, result_sign_q, rnd_exp_pack[kronos_pkg::FP_S_EXP_W-1:0], rnd_mant_pack[kronos_pkg::FP_S_MANT_W-1:0]};
      end
    end
  end

  // -----------------------------------------------------------------------
  // Core instantiation
  // -----------------------------------------------------------------------
  kronos_fpu_fdiv_core u_fdiv (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .flush_i  (flush_i),
    .start_i  (core_start & (op_q == FP_FDIV)),
    .fmt_d_i  (fmt_d_q),
    .a_i      (a_norm_q),
    .b_i      (b_norm_q),
    .done_o   (core_done_div),
    .quot_o   (q_div),
    .rem_nz_o (rem_nz_div)
  );

  kronos_fpu_fsqrt_core u_fsqrt (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .flush_i  (flush_i),
    .start_i  (core_start & (op_q == FP_FSQRT)),
    .fmt_d_i  (fmt_d_q),
    .a_i      (a_sqrt_q),
    .done_o   (core_done_sqrt),
    .quot_o   (q_sqrt),
    .rem_nz_o (rem_nz_sqrt)
  );

  // Mux core outputs based on operation
  assign raw      = (op_q == FP_FDIV) ? q_div      : q_sqrt;
  assign raw_sticky = (op_q == FP_FDIV) ? rem_nz_div : rem_nz_sqrt;
  assign core_done  = (op_q == FP_FDIV) ? core_done_div : core_done_sqrt;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_core_start
    if (!rst_ni)        core_start_q <= 1'b0;
    else if (flush_i)   core_start_q <= 1'b0;
    else                core_start_q <= (state_q == UNPACK2) && !is_special_q;
  end
  assign core_start = core_start_q;

  // -----------------------------------------------------------------------
  // FSM next-state logic
  // -----------------------------------------------------------------------
  always_comb begin : proc_fsm_d
    state_d = state_q;
    unique case (state_q)
      IDLE:    if (in_valid_i) state_d = UNPACK1;
      UNPACK1: state_d = UNPACK2;
      UNPACK2: state_d = is_special_q ? PACK : ITER;
      ITER:    if (core_done) state_d = ROUND1;
      ROUND1:  state_d = ROUND2;
      ROUND2:  if (sb_late_grant_i) state_d = PACK;  // hold if scoreboard denies the slot
      PACK:    state_d = IDLE;
      default: state_d = IDLE;
    endcase
  end

  // -----------------------------------------------------------------------
  // FSM state register
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_fsm_state
    if (!rst_ni)
      state_q <= IDLE;
    else if (flush_i)
      state_q <= IDLE;
    else
      state_q <= state_d;
  end

  // -----------------------------------------------------------------------
  // iter_busy_q: look-ahead flop so busy_o is driven from an FF Q pin.
  // state_d is the next-state value, so iter_busy_q asserts on the same
  // clock edge that state_q transitions out of IDLE.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_iter_busy
    if (!rst_ni)       iter_busy_q <= 1'b0;
    else if (flush_i)  iter_busy_q <= 1'b0;
    else               iter_busy_q <= (state_d != IDLE);
  end

  // -----------------------------------------------------------------------
  // Input latch (IDLE -> UNPACK1 transition)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_input_latch
    if (!rst_ni) begin
      op_q    <= fp_op_e'(5'b0);
      fmt_d_q <= 1'b0;
      rm_q    <= 3'b0;
      tag_q   <= '{default: '0};
      a_raw_q <= {kronos_pkg::FLEN{1'b0}};
      b_raw_q <= {kronos_pkg::FLEN{1'b0}};
    end else if (state_q == IDLE && in_valid_i) begin
      op_q    <= op_i;
      fmt_d_q <= fmt_d_i;
      rm_q    <= rm_i;
      tag_q   <= tag_i;
      a_raw_q <= a_i;
      b_raw_q <= b_i;
    end
  end

  // -----------------------------------------------------------------------
  // Classify latch (UNPACK1 -> UNPACK2 transition)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_class_latch
    if (!rst_ni) begin
      a_class_q <= '{default: '0};
      b_class_q <= '{default: '0};
    end else if (state_q == UNPACK1) begin
      a_class_q <= a_class;
      b_class_q <= b_class;
    end
  end

  // -----------------------------------------------------------------------
  // UNPACK1 latch: normalized sigs + unbiased true exponents + specials
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_unpack1_latch
    if (!rst_ni) begin
      a_norm_q         <= 53'h0;
      b_norm_q         <= 53'h0;
      a_sqrt_q         <= 54'h0;
      a_true_exp_q     <= {kronos_pkg::FP_EXP_EXT_W{1'b0}};
      b_true_exp_q     <= {kronos_pkg::FP_EXP_EXT_W{1'b0}};
      is_special_q     <= 1'b0;
      special_result_q <= {kronos_pkg::FLEN{1'b0}};
      special_fflags_q <= 5'h0;
    end else if (state_q == UNPACK1) begin
      a_norm_q         <= a_norm;
      b_norm_q         <= b_norm;
      a_sqrt_q         <= a_sqrt;
      a_true_exp_q     <= a_true_exp;
      b_true_exp_q     <= b_true_exp;
      is_special_q     <= is_special;
      special_result_q <= special_result;
      special_fflags_q <= special_fflags;
    end
  end

  // -----------------------------------------------------------------------
  // UNPACK2 latch: biased result exponent + result sign (from _q inputs)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_unpack2_latch
    if (!rst_ni) begin
      result_sign_q <= 1'b0;
      result_exp_q  <= {kronos_pkg::FP_EXP_EXT_W{1'b0}};
    end else if (state_q == UNPACK2 && !is_special_q) begin
      result_sign_q <= result_sign_comb;
      result_exp_q  <= result_exp_comb;
    end
  end

  // -----------------------------------------------------------------------
  // Raw quotient latch (on core_done)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_raw_latch
    if (!rst_ni) begin
      raw_q      <= 56'h0;
      raw_sticky_q <= 1'b0;
    end else if (core_done) begin
      raw_q      <= raw;
      raw_sticky_q <= raw_sticky;
    end
  end

  // -----------------------------------------------------------------------
  // Result / fflags latch
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_result_latch
    if (!rst_ni) begin
      result_q <= {kronos_pkg::FLEN{1'b0}};
      fflags_q <= 5'h0;
    end else if (state_q == UNPACK2 && is_special_q) begin
      result_q <= special_result_q;
      fflags_q <= special_fflags_q;
    end else if (state_q == ROUND2) begin
      result_q <= round_result;
      fflags_q <= round_fflags;
    end
  end

  // -----------------------------------------------------------------------
  // Output assignments
  // -----------------------------------------------------------------------
  assign busy_o      = iter_busy_q;
  assign out_valid_o = (state_q == PACK);
  assign result_o    = result_q;
  assign fflags_o    = fflags_q;
  assign tag_o       = tag_q;

  // Late-reservation: request scoreboard slot one cycle before writeback.
  // ROUND lasts one or more cycles: request the slot every cycle, advance to
  // PACK on grant. Latency=1 means the scoreboard reserves the slot that fires
  // next cycle.
  assign sb_late_req_o     = (state_q == ROUND2);
  assign sb_late_fp_dest_o = tag_q.fp_dest;

endmodule
