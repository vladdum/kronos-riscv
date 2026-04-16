// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Iterative FPU wrapper for FDIV and FSQRT.
//
// FSM: IDLE -> UNPACK -> ITER -> ROUND -> PACK -> IDLE
//
// IDLE:   Latch raw inputs on in_valid_i.
// UNPACK: Classify operands, detect specials (bypass to PACK),
//         normalize subnormals, compute result exponent, start cores.
// ITER:   Wait for fdiv/fsqrt core done signal.
// ROUND:  (placeholder — Task 11)
// PACK:   (placeholder — Task 12)

module kronos_fpu_iter
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,

  input  logic        in_valid_i,
  input  fp_op_e      op_i,
  input  logic        fmt_d_i,
  input  logic [2:0]  rm_i,
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  fpu_tag_t    tag_i,

  output logic        busy_o,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o,

  // Late-reservation to scoreboard (wired in Task 14-15)
  output logic        sb_late_req_o,
  output logic        sb_late_fp_dest_o,
  input  logic        sb_late_grant_i
);

  // -----------------------------------------------------------------------
  // FSM states
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE   = 3'd0,
    UNPACK = 3'd1,
    ITER   = 3'd2,
    ROUND  = 3'd3,
    PACK   = 3'd4
  } state_e;

  // -----------------------------------------------------------------------
  // Operand classification
  // -----------------------------------------------------------------------
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
  // State registers
  // -----------------------------------------------------------------------
  state_e    state_q;

  // Latched raw inputs (IDLE -> UNPACK)
  fp_op_e    op_q;
  logic      fmt_d_q;
  logic [2:0] rm_q;
  fpu_tag_t  tag_q;
  logic [63:0] a_raw_q, b_raw_q;

  // Classified operands (registered in UNPACK -> ITER transition)
  fp_class_t a_class_q, b_class_q;

  // Normalized operands and result exponent (latched UNPACK -> ITER)
  logic [52:0]       a_norm_q, b_norm_q;   // fdiv: 53-bit normalized sigs
  logic [53:0]       a_sqrt_q;             // fsqrt: 54-bit normalized sig
  logic              result_sign_q;
  logic signed [12:0] result_exp_q;        // signed intermediate exponent

  // Raw quotient from core (latched on core_done)
  logic [55:0] raw_q_q;
  logic        raw_sticky_q;

  // -----------------------------------------------------------------------
  // Combinational signals
  // -----------------------------------------------------------------------
  state_e    state_d;
  fp_class_t a_class, b_class;

  // -----------------------------------------------------------------------
  // Operand classify (combinational, used in UNPACK)
  // Reads from a_raw_q / b_raw_q (latched in IDLE)
  // -----------------------------------------------------------------------
  always_comb begin : proc_classify_a
    a_class = '0;
    if (fmt_d_q) begin
      // Double precision
      a_class.sign = a_raw_q[63];
      a_class.exp  = a_raw_q[62:52];
      a_class.sig  = a_raw_q[51:0];
    end else begin
      // Single precision -- check NaN-boxing
      if (a_raw_q[63:32] == 32'hFFFF_FFFF) begin
        a_class.sign = a_raw_q[31];
        a_class.exp  = {3'b0, a_raw_q[30:23]};
        a_class.sig  = {a_raw_q[22:0], 29'b0};
      end else begin
        // Not properly NaN-boxed: treat as canonical qNaN
        a_class.sign    = 1'b0;
        a_class.exp     = 11'h7FF;
        a_class.sig     = {1'b1, 51'b0};
        a_class.is_qnan = 1'b1;
      end
    end

    // Classification (only if not already forced to qNaN by NaN-box check)
    if (!a_class.is_qnan) begin
      if (fmt_d_q) begin
        a_class.is_zero    = (a_class.exp == 11'h000) && (a_class.sig == 52'b0);
        a_class.is_subnorm = (a_class.exp == 11'h000) && (a_class.sig != 52'b0);
        a_class.is_inf     = (a_class.exp == 11'h7FF) && (a_class.sig == 52'b0);
        a_class.is_snan    = (a_class.exp == 11'h7FF) && (a_class.sig != 52'b0)
                             && !a_class.sig[51];
        a_class.is_qnan    = (a_class.exp == 11'h7FF) && a_class.sig[51];
        a_class.is_normal  = !a_class.is_zero && !a_class.is_subnorm
                             && !a_class.is_inf && !a_class.is_snan
                             && !a_class.is_qnan;
      end else begin
        // Single: exponent is in [7:0] of a_class.exp, sig in [51:29]
        a_class.is_zero    = (a_class.exp[7:0] == 8'h00)
                             && (a_class.sig[51:29] == 23'b0);
        a_class.is_subnorm = (a_class.exp[7:0] == 8'h00)
                             && (a_class.sig[51:29] != 23'b0);
        a_class.is_inf     = (a_class.exp[7:0] == 8'hFF)
                             && (a_class.sig[51:29] == 23'b0);
        a_class.is_snan    = (a_class.exp[7:0] == 8'hFF)
                             && (a_class.sig[51:29] != 23'b0)
                             && !a_class.sig[51];
        a_class.is_qnan    = (a_class.exp[7:0] == 8'hFF)
                             && a_class.sig[51];
        a_class.is_normal  = !a_class.is_zero && !a_class.is_subnorm
                             && !a_class.is_inf && !a_class.is_snan
                             && !a_class.is_qnan;
      end
    end

    // CLZ for subnormals
    if (fmt_d_q)
      a_class.clz = clz53({1'b0, a_class.sig});
    else
      a_class.clz = clz53({1'b0, a_class.sig[51:29], 29'b0});
  end

  always_comb begin : proc_classify_b
    b_class = '0;
    if (fmt_d_q) begin
      // Double precision
      b_class.sign = b_raw_q[63];
      b_class.exp  = b_raw_q[62:52];
      b_class.sig  = b_raw_q[51:0];
    end else begin
      // Single precision -- check NaN-boxing
      if (b_raw_q[63:32] == 32'hFFFF_FFFF) begin
        b_class.sign = b_raw_q[31];
        b_class.exp  = {3'b0, b_raw_q[30:23]};
        b_class.sig  = {b_raw_q[22:0], 29'b0};
      end else begin
        // Not properly NaN-boxed: treat as canonical qNaN
        b_class.sign    = 1'b0;
        b_class.exp     = 11'h7FF;
        b_class.sig     = {1'b1, 51'b0};
        b_class.is_qnan = 1'b1;
      end
    end

    // Classification
    if (!b_class.is_qnan) begin
      if (fmt_d_q) begin
        b_class.is_zero    = (b_class.exp == 11'h000) && (b_class.sig == 52'b0);
        b_class.is_subnorm = (b_class.exp == 11'h000) && (b_class.sig != 52'b0);
        b_class.is_inf     = (b_class.exp == 11'h7FF) && (b_class.sig == 52'b0);
        b_class.is_snan    = (b_class.exp == 11'h7FF) && (b_class.sig != 52'b0)
                             && !b_class.sig[51];
        b_class.is_qnan    = (b_class.exp == 11'h7FF) && b_class.sig[51];
        b_class.is_normal  = !b_class.is_zero && !b_class.is_subnorm
                             && !b_class.is_inf && !b_class.is_snan
                             && !b_class.is_qnan;
      end else begin
        // Single: exponent is in [7:0] of b_class.exp, sig in [51:29]
        b_class.is_zero    = (b_class.exp[7:0] == 8'h00)
                             && (b_class.sig[51:29] == 23'b0);
        b_class.is_subnorm = (b_class.exp[7:0] == 8'h00)
                             && (b_class.sig[51:29] != 23'b0);
        b_class.is_inf     = (b_class.exp[7:0] == 8'hFF)
                             && (b_class.sig[51:29] == 23'b0);
        b_class.is_snan    = (b_class.exp[7:0] == 8'hFF)
                             && (b_class.sig[51:29] != 23'b0)
                             && !b_class.sig[51];
        b_class.is_qnan    = (b_class.exp[7:0] == 8'hFF)
                             && b_class.sig[51];
        b_class.is_normal  = !b_class.is_zero && !b_class.is_subnorm
                             && !b_class.is_inf && !b_class.is_snan
                             && !b_class.is_qnan;
      end
    end

    // CLZ for subnormals
    if (fmt_d_q)
      b_class.clz = clz53({1'b0, b_class.sig});
    else
      b_class.clz = clz53({1'b0, b_class.sig[51:29], 29'b0});
  end

  // -----------------------------------------------------------------------
  // Specials short-circuit (combinational, used in UNPACK)
  // -----------------------------------------------------------------------
  logic        is_special;
  logic [63:0] special_result;
  logic [4:0]  special_fflags;

  // Canonical bit patterns for double precision
  localparam logic [63:0] D_QNAN  = 64'h7FF8_0000_0000_0000;
  localparam logic [63:0] D_PINF  = 64'h7FF0_0000_0000_0000;
  localparam logic [63:0] D_NINF  = 64'hFFF0_0000_0000_0000;
  localparam logic [63:0] D_PZERO = 64'h0000_0000_0000_0000;
  localparam logic [63:0] D_NZERO = 64'h8000_0000_0000_0000;

  // Canonical bit patterns for single precision (NaN-boxed to 64 bits)
  localparam logic [63:0] S_QNAN  = 64'hFFFF_FFFF_7FC0_0000;
  localparam logic [63:0] S_PINF  = 64'hFFFF_FFFF_7F80_0000;
  localparam logic [63:0] S_NINF  = 64'hFFFF_FFFF_FF80_0000;
  localparam logic [63:0] S_PZERO = 64'hFFFF_FFFF_0000_0000;
  localparam logic [63:0] S_NZERO = 64'hFFFF_FFFF_8000_0000;

  // Flag bits
  localparam logic [4:0] FL_NV = 5'(1) << FP_FFLAG_NV;
  localparam logic [4:0] FL_DZ = 5'(1) << FP_FFLAG_DZ;

  // Specials helper signals
  logic        sp_result_sign;
  logic [63:0] sp_qnan, sp_pinf, sp_ninf, sp_pzero, sp_nzero;
  logic [63:0] sp_signed_inf, sp_signed_zero;
  logic        sp_a_nan, sp_b_nan, sp_any_snan, sp_any_nan;

  always_comb begin : proc_specials
    is_special     = 1'b0;
    special_result = '0;
    special_fflags = '0;

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
        special_fflags = '0;
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
      end else if (b_class.is_zero) begin
        // x / 0 (x finite, non-zero) -> signed inf, DZ
        is_special     = 1'b1;
        special_result = sp_signed_inf;
        special_fflags = FL_DZ;
      end else if (a_class.is_zero) begin
        // 0 / x (x finite, non-zero) -> signed zero
        is_special     = 1'b1;
        special_result = sp_signed_zero;
        special_fflags = '0;
      end else if (a_class.is_inf) begin
        // inf / x (x finite) -> signed inf
        is_special     = 1'b1;
        special_result = sp_signed_inf;
        special_fflags = '0;
      end else if (b_class.is_inf) begin
        // x / inf (x finite) -> signed zero
        is_special     = 1'b1;
        special_result = sp_signed_zero;
        special_fflags = '0;
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
        special_fflags = '0;
      end else if (a_class.is_zero) begin
        // +0 -> +0, -0 -> -0
        is_special     = 1'b1;
        special_result = a_class.sign ? sp_nzero : sp_pzero;
        special_fflags = '0;
      end else if (a_class.is_inf && !a_class.sign) begin
        // +inf -> +inf
        is_special     = 1'b1;
        special_result = sp_pinf;
        special_fflags = '0;
      end else if (a_class.sign) begin
        // Negative (including -inf, -normal, -subnorm) -> qNaN, NV
        is_special     = 1'b1;
        special_result = sp_qnan;
        special_fflags = FL_NV;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Normalization logic (combinational, used in UNPACK -> ITER transition)
  // -----------------------------------------------------------------------
  logic [52:0]       a_norm, b_norm;      // fdiv normalized significands
  logic [53:0]       a_sqrt;              // fsqrt normalized significand
  logic signed [12:0] result_exp_comb;    // intermediate result exponent
  logic              result_sign_comb;
  logic signed [12:0] a_true_exp, b_true_exp;
  logic signed [12:0] bias;

  always_comb begin : proc_normalize
    a_norm     = '0;
    b_norm     = '0;
    a_sqrt     = '0;
    result_exp_comb = '0;
    result_sign_comb = '0;
    a_true_exp = '0;
    b_true_exp = '0;

    bias = fmt_d_q ? 13'sd1023 : 13'sd127;

    // Result sign: FDIV = sign_a ^ sign_b, FSQRT = 0 (negative caught
    // as special)
    result_sign_comb = (op_q == FP_FDIV) ? (a_class.sign ^ b_class.sign)
                                         : 1'b0;

    // --- Operand A normalization ---
    if (a_class.is_subnorm) begin
      // Subnormal: true exponent = 1 - bias - clz
      // Shift {0, sig} left by clz to place leading 1 at bit 52
      a_true_exp = 13'sd1 - bias - 13'(a_class.clz);
      a_norm     = {1'b0, a_class.sig} << a_class.clz;
    end else begin
      // Normal: true exponent = biased_exp - bias
      a_true_exp = 13'(a_class.exp) - bias;
      a_norm     = {1'b1, a_class.sig};
    end

    // --- Operand B normalization (FDIV only) ---
    if (b_class.is_subnorm) begin
      b_true_exp = 13'sd1 - bias - 13'(b_class.clz);
      b_norm     = {1'b0, b_class.sig} << b_class.clz;
    end else begin
      b_true_exp = 13'(b_class.exp) - bias;
      b_norm     = {1'b1, b_class.sig};
    end

    // --- Result exponent computation ---
    if (op_q == FP_FDIV) begin
      // FDIV: result_exp (biased) = (a_true - b_true) + bias
      // Quotient normalization adjustment handled in ROUND.
      result_exp_comb = a_true_exp - b_true_exp + bias;
    end else begin
      // FSQRT: result_exp (biased) = floor(a_true / 2) + bias
      // If a_true is odd, pre-shift significand left by 1 (handled below).
      // Use arithmetic right shift for floor division of signed value.
      // floor(a_true / 2): for negative odd, e.g. -3 => floor(-1.5) = -2
      // (a_true_exp - (a_true_exp < 0 && a_true_exp[0])) >>> 1
      // Actually: (a_true_exp >> 1) works for even. For odd negative:
      // a_true_exp = -3: we want floor(-3/2) = -2. (-3)>>>1 = -2. OK.
      // a_true_exp = -1: we want floor(-1/2) = -1. (-1)>>>1 = -1. OK.
      // a_true_exp = 3:  we want floor(3/2) = 1.  3>>>1 = 1. OK.
      // So arithmetic right shift by 1 gives floor(x/2) for signed x.
      result_exp_comb = (a_true_exp >>> 1) + bias;
    end

    // --- FSQRT significand preparation ---
    // For fsqrt, the core expects a 54-bit input:
    //   Even exponent: {1'b0, normalized_sig[52:0]} (bit 52 set)
    //   Odd exponent:  {normalized_sig[52:0], 1'b0} (bit 53 set)
    // "Odd" means a_true_exp[0] == 1.
    if (a_true_exp[0]) begin
      // Odd true exponent: shift left by 1
      a_sqrt = {a_norm, 1'b0};
    end else begin
      // Even true exponent
      a_sqrt = {1'b0, a_norm};
    end
  end

  // -----------------------------------------------------------------------
  // ROUND state — rounding logic (combinational)
  // -----------------------------------------------------------------------
  logic [63:0] round_result;
  logic [4:0]  round_fflags;

  // Post-normalization shift signals
  logic [55:0]        rnd_shifted;
  logic signed [12:0] rnd_adj_exp;
  logic               rnd_sticky_shift;

  // Mantissa extraction
  logic [51:0] rnd_mantissa;
  logic        rnd_lsb, rnd_g, rnd_r, rnd_s;

  // Tininess and subnormal shift
  logic               rnd_tiny;
  logic [51:0]        rnd_mant_shifted;
  logic               rnd_new_lsb, rnd_new_g, rnd_new_r, rnd_new_s;
  logic signed [12:0] rnd_final_exp;
  logic [6:0]         rnd_shift_amt;
  logic [55:0]        rnd_combined_d, rnd_shifted_out_d, rnd_combined_shifted_d;
  logic [26:0]        rnd_combined_s, rnd_shifted_out_s, rnd_combined_shifted_s;

  // Rounding decision
  logic        rnd_round_up;
  logic        rnd_inexact;

  // Rounded mantissa
  logic [52:0] rnd_rounded_mant;
  logic        rnd_carry;

  // Overflow
  logic        rnd_overflow;
  logic        rnd_overflow_to_inf;
  logic        rnd_to_max;

  // Flags
  logic        rnd_uf, rnd_of, rnd_nx;

  // FDIV normalization helper
  logic        rnd_need_shift;

  always_comb begin : proc_round
    // Defaults
    round_result   = '0;
    round_fflags   = '0;
    rnd_shifted    = '0;
    rnd_adj_exp    = '0;
    rnd_sticky_shift = 1'b0;
    rnd_mantissa   = '0;
    rnd_lsb        = 1'b0;
    rnd_g          = 1'b0;
    rnd_r          = 1'b0;
    rnd_s          = 1'b0;
    rnd_tiny       = 1'b0;
    rnd_mant_shifted = '0;
    rnd_new_lsb    = 1'b0;
    rnd_new_g      = 1'b0;
    rnd_new_r      = 1'b0;
    rnd_new_s      = 1'b0;
    rnd_final_exp  = '0;
    rnd_shift_amt  = '0;
    rnd_combined_d = '0;
    rnd_shifted_out_d = '0;
    rnd_combined_shifted_d = '0;
    rnd_combined_s = '0;
    rnd_shifted_out_s = '0;
    rnd_combined_shifted_s = '0;
    rnd_round_up   = 1'b0;
    rnd_inexact    = 1'b0;
    rnd_rounded_mant = '0;
    rnd_carry      = 1'b0;
    rnd_overflow   = 1'b0;
    rnd_overflow_to_inf = 1'b0;
    rnd_to_max     = 1'b0;
    rnd_uf         = 1'b0;
    rnd_of         = 1'b0;
    rnd_nx         = 1'b0;

    // ------------------------------------------------------------------
    // 1. Post-normalization shift (FDIV only: if integer bit is 0)
    // ------------------------------------------------------------------
    // For FDIV: the core emits n bits where bit[n-1] is the integer bit.
    // For D (n=56): integer bit at [55]. For S (n=27): at [26].
    // If the integer bit is 0, shift left by 1 and decrement exponent.
    rnd_need_shift = 1'b0;
    if (op_q == FP_FDIV) begin
      rnd_need_shift = fmt_d_q ? !raw_q_q[55] : !raw_q_q[26];
      if (rnd_need_shift) begin
        rnd_shifted = {raw_q_q[54:0], raw_sticky_q};
        rnd_adj_exp = result_exp_q - 13'sd1;
        rnd_sticky_shift = 1'b0;
      end else begin
        rnd_shifted = raw_q_q;
        rnd_adj_exp = result_exp_q;
        rnd_sticky_shift = raw_sticky_q;
      end
    end else begin
      // FSQRT: MSB always 1, no shift needed
      rnd_shifted = raw_q_q;
      rnd_adj_exp = result_exp_q;
      rnd_sticky_shift = raw_sticky_q;
    end

    // ------------------------------------------------------------------
    // 2. Extract mantissa, G, R, S
    // ------------------------------------------------------------------
    // After normalization, bit [n-1] = 1 (implicit). With n+1 quotient bits:
    // D: [55]=implicit, [54:3]=mantissa, [2]=G, [1]=R, [0]=extra→S.
    // S: [26]=implicit, [25:3]=mantissa, [2]=G, [1]=R, [0]=extra→S.
    if (fmt_d_q) begin
      rnd_mantissa = rnd_shifted[54:3];
      rnd_lsb      = rnd_shifted[3];
      rnd_g        = rnd_shifted[2];
      rnd_r        = rnd_shifted[1];
      rnd_s        = rnd_sticky_shift | rnd_shifted[0];
    end else begin
      rnd_mantissa = {29'b0, rnd_shifted[25:3]};
      rnd_lsb      = rnd_shifted[3];
      rnd_g        = rnd_shifted[2];
      rnd_r        = rnd_shifted[1];
      rnd_s        = rnd_sticky_shift | rnd_shifted[0];
    end

    // ------------------------------------------------------------------
    // 3. Tininess detection and subnormal shift (before rounding)
    // ------------------------------------------------------------------
    rnd_tiny = (rnd_adj_exp <= 13'sd0);

    if (rnd_tiny) begin
      // Compute shift in full width to avoid 7-bit truncation overflow.
      // rnd_adj_exp <= 0 here, so (1 - rnd_adj_exp) >= 1.
      if (fmt_d_q) begin
        rnd_shift_amt = ((13'sd1 - rnd_adj_exp) > 13'sd56)
                        ? 7'd56 : 7'(13'sd1 - rnd_adj_exp);
      end else begin
        rnd_shift_amt = ((13'sd1 - rnd_adj_exp) > 13'sd27)
                        ? 7'd27 : 7'(13'sd1 - rnd_adj_exp);
      end

      // Include implicit 1 bit in the combined vector for correct
      // denormalization: D = {1, mantissa[51:0], G, R, extra} = rnd_shifted.
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
        rnd_mant_shifted = {29'b0, rnd_combined_shifted_s[25:3]};
        rnd_new_lsb = rnd_combined_shifted_s[3];
        rnd_new_g   = rnd_combined_shifted_s[2];
        rnd_new_r   = rnd_combined_shifted_s[1];
        rnd_new_s   = rnd_s | rnd_combined_shifted_s[0] | (|rnd_shifted_out_s);
      end

      rnd_final_exp = 13'sd0;
    end else begin
      rnd_mant_shifted = rnd_mantissa;
      rnd_new_lsb = rnd_lsb;
      rnd_new_g   = rnd_g;
      rnd_new_r   = rnd_r;
      rnd_new_s   = rnd_s;
      rnd_final_exp = rnd_adj_exp;
    end

    // ------------------------------------------------------------------
    // 4. Rounding decision
    // ------------------------------------------------------------------
    rnd_inexact = rnd_new_g | rnd_new_r | rnd_new_s;

    unique case (rm_q)
      3'b000:  rnd_round_up = rnd_new_g & (rnd_new_lsb | rnd_new_r | rnd_new_s);
      3'b001:  rnd_round_up = 1'b0;
      3'b010:  rnd_round_up = result_sign_q & rnd_inexact;
      3'b011:  rnd_round_up = ~result_sign_q & rnd_inexact;
      3'b100:  rnd_round_up = rnd_new_g;
      default: rnd_round_up = 1'b0;
    endcase

    // ------------------------------------------------------------------
    // 5. Add rounding increment
    // ------------------------------------------------------------------
    if (fmt_d_q)
      rnd_rounded_mant = {1'b0, rnd_mant_shifted} + {52'b0, rnd_round_up};
    else
      rnd_rounded_mant = {30'b0, rnd_mant_shifted[22:0]} + {52'b0, rnd_round_up};

    rnd_carry = fmt_d_q ? rnd_rounded_mant[52] : rnd_rounded_mant[23];

    if (rnd_carry) begin
      rnd_final_exp = rnd_final_exp + 13'sd1;
      rnd_rounded_mant = '0;
    end

    // ------------------------------------------------------------------
    // 6. Overflow detection
    // ------------------------------------------------------------------
    rnd_overflow = fmt_d_q ? (rnd_final_exp >= 13'sd2047)
                           : (rnd_final_exp >= 13'sd255);

    // Overflow rounding: RTZ or directed toward zero -> max finite
    rnd_to_max = 1'b0;
    if (rnd_overflow) begin
      unique case (rm_q)
        3'b001:  rnd_to_max = 1'b1;
        3'b010:  rnd_to_max = ~result_sign_q;
        3'b011:  rnd_to_max = result_sign_q;
        default: rnd_to_max = 1'b0;
      endcase
    end
    rnd_overflow_to_inf = rnd_overflow & ~rnd_to_max;

    // ------------------------------------------------------------------
    // 7. Flag generation
    // ------------------------------------------------------------------
    rnd_nx = rnd_inexact | rnd_overflow;
    rnd_uf = rnd_tiny & rnd_inexact;
    rnd_of = rnd_overflow;

    round_fflags = {1'b0, 1'b0, rnd_of, rnd_uf, rnd_nx};

    // ------------------------------------------------------------------
    // 8. Pack result
    // ------------------------------------------------------------------
    if (rnd_overflow) begin
      if (rnd_overflow_to_inf) begin
        if (fmt_d_q)
          round_result = {result_sign_q, 11'h7FF, 52'b0};
        else
          round_result = {32'hFFFF_FFFF, result_sign_q, 8'hFF, 23'b0};
      end else begin
        if (fmt_d_q)
          round_result = {result_sign_q, 11'h7FE, {52{1'b1}}};
        else
          round_result = {32'hFFFF_FFFF, result_sign_q, 8'hFE, {23{1'b1}}};
      end
    end else begin
      if (fmt_d_q)
        round_result = {result_sign_q, rnd_final_exp[10:0],
                        rnd_rounded_mant[51:0]};
      else
        round_result = {32'hFFFF_FFFF, result_sign_q, rnd_final_exp[7:0],
                        rnd_rounded_mant[22:0]};
    end
  end

  // -----------------------------------------------------------------------
  // Result / fflags registers
  // -----------------------------------------------------------------------
  logic [63:0] result_q;
  logic [4:0]  fflags_q;

  // -----------------------------------------------------------------------
  // Core instantiation
  // -----------------------------------------------------------------------
  logic        core_start;
  logic        core_done_div, core_done_sqrt;
  logic [55:0] q_div, q_sqrt;
  logic        rem_nz_div, rem_nz_sqrt;

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
  logic [55:0] raw_q;
  logic        raw_sticky;
  logic        core_done;

  assign raw_q      = (op_q == FP_FDIV) ? q_div      : q_sqrt;
  assign raw_sticky = (op_q == FP_FDIV) ? rem_nz_div : rem_nz_sqrt;
  assign core_done  = (op_q == FP_FDIV) ? core_done_div : core_done_sqrt;

  // core_start: delayed by one cycle from UNPACK -> ITER so that
  // a_norm_q / b_norm_q / a_sqrt_q are already latched when the core
  // samples start_i.  High for exactly one clock in the first ITER cycle.
  logic core_start_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        core_start_q <= 1'b0;
    else if (flush_i)   core_start_q <= 1'b0;
    else                core_start_q <= (state_q == UNPACK) && !is_special;
  end
  assign core_start = core_start_q;

  // -----------------------------------------------------------------------
  // FSM next-state logic
  // -----------------------------------------------------------------------
  always_comb begin : proc_fsm_next
    state_d = state_q;
    unique case (state_q)
      IDLE:   if (in_valid_i) state_d = UNPACK;
      UNPACK: state_d = is_special ? PACK : ITER;
      ITER:   if (core_done) state_d = ROUND;
      ROUND:  state_d = PACK;    // placeholder: one cycle
      PACK:   state_d = IDLE;
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
  // Input latch (IDLE -> UNPACK transition)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_input_latch
    if (!rst_ni) begin
      op_q    <= fp_op_e'('0);
      fmt_d_q <= 1'b0;
      rm_q    <= 3'b0;
      tag_q   <= '0;
      a_raw_q <= '0;
      b_raw_q <= '0;
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
  // Classify latch (UNPACK -> ITER transition)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_class_latch
    if (!rst_ni) begin
      a_class_q <= '0;
      b_class_q <= '0;
    end else if (state_q == UNPACK) begin
      a_class_q <= a_class;
      b_class_q <= b_class;
    end
  end

  // -----------------------------------------------------------------------
  // Normalization latch (UNPACK -> ITER transition, non-special path)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_norm_latch
    if (!rst_ni) begin
      a_norm_q      <= '0;
      b_norm_q      <= '0;
      a_sqrt_q      <= '0;
      result_sign_q <= 1'b0;
      result_exp_q  <= '0;
    end else if (state_q == UNPACK && !is_special) begin
      a_norm_q      <= a_norm;
      b_norm_q      <= b_norm;
      a_sqrt_q      <= a_sqrt;
      result_sign_q <= result_sign_comb;
      result_exp_q  <= result_exp_comb;
    end
  end

  // -----------------------------------------------------------------------
  // Raw quotient latch (on core_done)
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_raw_latch
    if (!rst_ni) begin
      raw_q_q      <= '0;
      raw_sticky_q <= 1'b0;
    end else if (core_done) begin
      raw_q_q      <= raw_q;
      raw_sticky_q <= raw_sticky;
    end
  end

  // -----------------------------------------------------------------------
  // Result / fflags latch
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_result_latch
    if (!rst_ni) begin
      result_q <= '0;
      fflags_q <= '0;
    end else if (state_q == UNPACK && is_special) begin
      result_q <= special_result;
      fflags_q <= special_fflags;
    end else if (state_q == ROUND) begin
      result_q <= round_result;
      fflags_q <= round_fflags;
    end
  end

  // -----------------------------------------------------------------------
  // Output assignments
  // -----------------------------------------------------------------------
  assign busy_o      = (state_q != IDLE);
  assign out_valid_o = (state_q == PACK);
  assign result_o    = result_q;
  assign fflags_o    = fflags_q;
  assign tag_o       = tag_q;

  // Late-reservation: request scoreboard slot one cycle before writeback.
  // ROUND state lasts one cycle, then transitions to PACK (out_valid).
  // Latency=1 means the scoreboard reserves the slot that fires next cycle.
  assign sb_late_req_o     = (state_q == ROUND);
  assign sb_late_fp_dest_o = tag_q.fp_dest;

endmodule
