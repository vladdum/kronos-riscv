// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 4-stage pipelined IEEE 754 floating-point multiplier (single and double).
//
// Pipeline:
//   S1: NaN-unbox single, decompose operands, classify specials, precompute
//       sign / unbiased exponent sum / extended significands.
//   S2: Multiply significands (wide multiply registered at stage boundary for
//       DSP inference).
//   S3: Normalize product (1x.x vs 01.x), compute guard/round/sticky, shift
//       right for subnormals if the result exponent is non-positive.
//   S4: Round, handle overflow/underflow, pack, NaN-box single. Register.

module kronos_fpu_fmul
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
  input  logic [63:0] c_i,       // unused
  input  fpu_tag_t    tag_i,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // -------------------------------------------------------------------------
  // Format constants
  // -------------------------------------------------------------------------
  localparam int unsigned S_EXP_W = 8;
  localparam int unsigned S_SIG_W = 23;
  localparam int unsigned D_EXP_W = 11;
  localparam int unsigned D_SIG_W = 52;

  // Shared widths — pad single into the double datapath to share the
  // arithmetic. Single significands are left-aligned at bit [52:29].
  localparam int unsigned SIG_W     = 53;             // mantissa incl. hidden bit
  localparam int unsigned PROD_W    = 2 * SIG_W;      // 106
  localparam int unsigned EXP_EXT_W = 13;             // signed, covers both fmts

  // -------------------------------------------------------------------------
  // Classification helpers
  // -------------------------------------------------------------------------
  function automatic logic is_snan_s(logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b1);
  endfunction
  function automatic logic is_nan_s(logic [31:0] x);
    return is_snan_s(x) || is_qnan_s(x);
  endfunction
  function automatic logic is_inf_s(logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22:0] == 23'd0);
  endfunction
  function automatic logic is_zero_s(logic [31:0] x);
    return (x[30:0] == 31'd0);
  endfunction

  function automatic logic is_snan_d(logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction
  function automatic logic is_qnan_d(logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b1);
  endfunction
  function automatic logic is_nan_d(logic [63:0] x);
    return is_snan_d(x) || is_qnan_d(x);
  endfunction
  function automatic logic is_inf_d(logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51:0] == 52'd0);
  endfunction
  function automatic logic is_zero_d(logic [63:0] x);
    return (x[62:0] == 63'd0);
  endfunction

  // -------------------------------------------------------------------------
  // S1 combinational: decompose, classify, prepare multiplicands
  // -------------------------------------------------------------------------
  logic [31:0] a_s_unb, b_s_unb;

  logic        s1_valid_c;
  logic        s1_fmt_d_c;
  logic [2:0]  s1_rm_c;
  fpu_tag_t    s1_tag_c;

  logic        s1_sign_c;
  logic signed [EXP_EXT_W-1:0] s1_exp_sum_c;   // ea + eb - bias (no hidden-bit fix)
  logic [SIG_W-1:0] s1_siga_c, s1_sigb_c;      // 53-bit mantissas

  // Special-case flags
  logic s1_any_snan_c;
  logic s1_any_nan_c;
  logic s1_inf_times_zero_c;
  logic s1_res_is_inf_c;
  logic s1_res_is_zero_c;

  always_comb begin
    logic [31:0] a_s_l, b_s_l;
    logic        a_is_snan, b_is_snan, a_is_nan, b_is_nan;
    logic        a_is_inf,  b_is_inf,  a_is_zero, b_is_zero;
    logic        a_sub, b_sub;
    logic [S_EXP_W-1:0] ea_s, eb_s;
    logic [D_EXP_W-1:0] ea_d, eb_d;
    logic signed [EXP_EXT_W-1:0] ea_ext, eb_ext;

    // NaN-unbox single operands (mirrors kronos_fpu_fmisc).
    a_s_l = (a_i[63:32] == FP_NANBOX_UPPER) ? a_i[31:0] : FP_CANON_QNAN_S;
    b_s_l = (b_i[63:32] == FP_NANBOX_UPPER) ? b_i[31:0] : FP_CANON_QNAN_S;
    a_s_unb = a_s_l;
    b_s_unb = b_s_l;

    // Classification
    if (fmt_d_i) begin
      a_is_snan = is_snan_d(a_i);
      b_is_snan = is_snan_d(b_i);
      a_is_nan  = is_nan_d(a_i);
      b_is_nan  = is_nan_d(b_i);
      a_is_inf  = is_inf_d(a_i);
      b_is_inf  = is_inf_d(b_i);
      a_is_zero = is_zero_d(a_i);
      b_is_zero = is_zero_d(b_i);
    end else begin
      a_is_snan = is_snan_s(a_s_l);
      b_is_snan = is_snan_s(b_s_l);
      a_is_nan  = is_nan_s(a_s_l);
      b_is_nan  = is_nan_s(b_s_l);
      a_is_inf  = is_inf_s(a_s_l);
      b_is_inf  = is_inf_s(b_s_l);
      a_is_zero = is_zero_s(a_s_l);
      b_is_zero = is_zero_s(b_s_l);
    end

    s1_any_snan_c       = a_is_snan || b_is_snan;
    s1_any_nan_c        = a_is_nan  || b_is_nan;
    s1_inf_times_zero_c = (a_is_inf && b_is_zero) || (a_is_zero && b_is_inf);
    s1_res_is_inf_c     = (a_is_inf || b_is_inf) && !s1_inf_times_zero_c
                           && !s1_any_nan_c;
    s1_res_is_zero_c    = (a_is_zero || b_is_zero) && !s1_inf_times_zero_c
                           && !s1_any_nan_c && !s1_res_is_inf_c;

    // Sign
    if (fmt_d_i) s1_sign_c = a_i[63] ^ b_i[63];
    else         s1_sign_c = a_s_l[31] ^ b_s_l[31];

    // Exponent and significand extraction. Left-align single into the 53-bit
    // datapath so the same normalization logic handles both formats.
    ea_s = a_s_l[30:23];
    eb_s = b_s_l[30:23];
    ea_d = a_i[62:52];
    eb_d = b_i[62:52];

    if (fmt_d_i) begin
      a_sub = (ea_d == 11'd0) && (a_i[51:0] != 52'd0);
      b_sub = (eb_d == 11'd0) && (b_i[51:0] != 52'd0);
      s1_siga_c = {~a_sub ? 1'b1 : 1'b0, a_i[51:0]};
      s1_sigb_c = {~b_sub ? 1'b1 : 1'b0, b_i[51:0]};
      // Subnormals use true exponent 1 instead of 0.
      ea_ext = a_sub ? 13'sd1 : {{(EXP_EXT_W-D_EXP_W){1'b0}}, ea_d};
      eb_ext = b_sub ? 13'sd1 : {{(EXP_EXT_W-D_EXP_W){1'b0}}, eb_d};
      s1_exp_sum_c = ea_ext + eb_ext - 13'sd1023;
    end else begin
      a_sub = (ea_s == 8'd0) && (a_s_l[22:0] != 23'd0);
      b_sub = (eb_s == 8'd0) && (b_s_l[22:0] != 23'd0);
      // Left-align single mantissa at bit [52:29]: hidden bit at 52, fraction
      // at 51:29, low 29 bits zero.
      s1_siga_c = {~a_sub ? 1'b1 : 1'b0, a_s_l[22:0], 29'd0};
      s1_sigb_c = {~b_sub ? 1'b1 : 1'b0, b_s_l[22:0], 29'd0};
      ea_ext = a_sub ? 13'sd1 : {{(EXP_EXT_W-S_EXP_W){1'b0}}, ea_s};
      eb_ext = b_sub ? 13'sd1 : {{(EXP_EXT_W-S_EXP_W){1'b0}}, eb_s};
      s1_exp_sum_c = ea_ext + eb_ext - 13'sd127;
    end

    s1_fmt_d_c = fmt_d_i;
    s1_rm_c    = rm_i;
    s1_tag_c   = tag_i;
    s1_valid_c = in_valid_i;
  end

  // -------------------------------------------------------------------------
  // S1 registers
  // -------------------------------------------------------------------------
  logic        s1_valid_q;
  logic        s1_fmt_d_q;
  logic [2:0]  s1_rm_q;
  fpu_tag_t    s1_tag_q;
  logic        s1_sign_q;
  logic signed [EXP_EXT_W-1:0] s1_exp_sum_q;
  logic [SIG_W-1:0] s1_siga_q, s1_sigb_q;
  logic        s1_any_snan_q, s1_any_nan_q, s1_inf_times_zero_q;
  logic        s1_res_is_inf_q, s1_res_is_zero_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q          <= 1'b0;
      s1_fmt_d_q          <= 1'b0;
      s1_rm_q             <= 3'd0;
      s1_tag_q            <= '0;
      s1_sign_q           <= 1'b0;
      s1_exp_sum_q        <= '0;
      s1_siga_q           <= '0;
      s1_sigb_q           <= '0;
      s1_any_snan_q       <= 1'b0;
      s1_any_nan_q        <= 1'b0;
      s1_inf_times_zero_q <= 1'b0;
      s1_res_is_inf_q     <= 1'b0;
      s1_res_is_zero_q    <= 1'b0;
    end else begin
      s1_valid_q          <= flush_i ? 1'b0 : s1_valid_c;
      s1_fmt_d_q          <= s1_fmt_d_c;
      s1_rm_q             <= s1_rm_c;
      s1_tag_q            <= s1_tag_c;
      s1_sign_q           <= s1_sign_c;
      s1_exp_sum_q        <= s1_exp_sum_c;
      s1_siga_q           <= s1_siga_c;
      s1_sigb_q           <= s1_sigb_c;
      s1_any_snan_q       <= s1_any_snan_c;
      s1_any_nan_q        <= s1_any_nan_c;
      s1_inf_times_zero_q <= s1_inf_times_zero_c;
      s1_res_is_inf_q     <= s1_res_is_inf_c;
      s1_res_is_zero_q    <= s1_res_is_zero_c;
    end
  end

  // -------------------------------------------------------------------------
  // S2 combinational: multiply
  // -------------------------------------------------------------------------
  logic [PROD_W-1:0] s2_prod_c;

  always_comb begin
    s2_prod_c = s1_siga_q * s1_sigb_q;
  end

  // -------------------------------------------------------------------------
  // S2 registers
  // -------------------------------------------------------------------------
  logic        s2_valid_q;
  logic        s2_fmt_d_q;
  logic [2:0]  s2_rm_q;
  fpu_tag_t    s2_tag_q;
  logic        s2_sign_q;
  logic signed [EXP_EXT_W-1:0] s2_exp_sum_q;
  logic [PROD_W-1:0] s2_prod_q;
  logic        s2_any_snan_q, s2_any_nan_q, s2_inf_times_zero_q;
  logic        s2_res_is_inf_q, s2_res_is_zero_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid_q          <= 1'b0;
      s2_fmt_d_q          <= 1'b0;
      s2_rm_q             <= 3'd0;
      s2_tag_q            <= '0;
      s2_sign_q           <= 1'b0;
      s2_exp_sum_q        <= '0;
      s2_prod_q           <= '0;
      s2_any_snan_q       <= 1'b0;
      s2_any_nan_q        <= 1'b0;
      s2_inf_times_zero_q <= 1'b0;
      s2_res_is_inf_q     <= 1'b0;
      s2_res_is_zero_q    <= 1'b0;
    end else begin
      s2_valid_q          <= flush_i ? 1'b0 : s1_valid_q;
      s2_fmt_d_q          <= s1_fmt_d_q;
      s2_rm_q             <= s1_rm_q;
      s2_tag_q            <= s1_tag_q;
      s2_sign_q           <= s1_sign_q;
      s2_exp_sum_q        <= s1_exp_sum_q;
      s2_prod_q           <= s2_prod_c;
      s2_any_snan_q       <= s1_any_snan_q;
      s2_any_nan_q        <= s1_any_nan_q;
      s2_inf_times_zero_q <= s1_inf_times_zero_q;
      s2_res_is_inf_q     <= s1_res_is_inf_q;
      s2_res_is_zero_q    <= s1_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S3 combinational: normalize, form guard/round/sticky, subnormal shift
  //
  // After an SIG_W x SIG_W unsigned multiply, the product is in [0, 2^(2*SIG_W))
  // with the leading 1 at bit [2*SIG_W-1] ("1x.xxx...") or bit [2*SIG_W-2]
  // ("01.xxx..."). We target a normalized mantissa of the form 1.f, so:
  //   - bit[105] = 1: shift right by (SIG_W-1) = 52. Exponent += 1.
  //   - bit[104] = 1: shift right by (SIG_W-2) = 51. Exponent += 0.
  // After that, we then need to collapse the low bits into GRS.
  //
  // We capture a normalized quantity of width SIG_W + 3 (hidden + fraction +
  // G + R + S) = 56 bits for double, and use the upper portion for single.
  // -------------------------------------------------------------------------

  // For readability alias sizes: normalized mantissa uses top SIG_W bits of
  // prod as {hidden, frac[D_SIG_W-1:0]} (for double) or {hidden, frac[S_SIG_W-1:0], 29 zeros}
  // (for single). To unify, we always produce a 53-bit {hidden, frac52} plus GRS.

  logic [PROD_W-1:0] s3_prod;
  logic signed [EXP_EXT_W-1:0] s3_exp_norm_c;
  logic [SIG_W-1:0] s3_mant_c;       // 53 bits: {1, frac52}
  logic             s3_guard_c;
  logic             s3_round_c;
  logic             s3_sticky_c;

  // After initial normalization (to "1.f" form across 53 bits), we may still
  // need to right-shift for subnormals if exp <= 0.
  logic [SIG_W-1:0] s3_mant_post_c;
  logic             s3_guard_post_c;
  logic             s3_round_post_c;
  logic             s3_sticky_post_c;
  logic signed [EXP_EXT_W-1:0] s3_exp_post_c;
  logic             s3_is_subnormal_c;

  // Leading-zero count for the 106-bit product. Used to normalize products
  // whose leading 1 sits below bit 104 (subnormal input operands).
  function automatic logic [6:0] lzc106(input logic [PROD_W-1:0] x);
    logic [6:0] n;
    n = 7'd0;
    for (int i = PROD_W-1; i >= 0; i--) begin
      if (x[i]) return n;
      n++;
    end
    return 7'd106; // all-zero product
  endfunction

  always_comb begin
    logic [6:0]  lz;
    logic signed [EXP_EXT_W-1:0] exp_adj;
    // Wide product, left-shifted to bring the leading 1 to bit PROD_W-2.
    // After left-shifting by (lz-1), all products have their hidden bit at bit 104.
    logic [PROD_W-1:0] prod_norm;
    // Hoisted from subnormal sub-blocks
    logic signed [EXP_EXT_W-1:0] shift_amt;
    logic [SIG_W-1:0] mant_fullw;
    logic g_in, r_in, s_in;
    int unsigned sh;
    logic [63:0] tail;
    logic [63:0] shifted;
    logic [63:0] lost_mask;

    // Defaults
    lz         = '0;
    exp_adj    = '0;
    prod_norm  = '0;
    shift_amt  = '0;
    mant_fullw = '0;
    g_in       = 1'b0;
    r_in       = 1'b0;
    s_in       = 1'b0;
    sh         = 0;
    tail       = '0;
    shifted    = '0;
    lost_mask  = '0;

    // Start from the wide product.
    s3_prod = s2_prod_q;

    // General normalization: find leading 1 and shift so that
    // bit[PROD_W-2] (= bit 104) becomes the hidden bit.
    // For normal*normal products the leading 1 is at bit 104 or 105.
    // For subnormal inputs the leading 1 can be lower.
    //
    // lzc106 counts zeros from the MSB (bit 105).  The leading 1 is at
    // bit (PROD_W-1-lz).  We want it at bit (PROD_W-2), so:
    //   left shift by (lz - 1)  and  exponent -= (lz - 1).
    // When lz == 0: leading 1 is at bit 105, left_shift = -1 → right shift by 1.
    //   Handled as the existing "top bit" case, exp += 1.
    // When lz == 1: leading 1 already at bit 104, no shift, exp unchanged.
    // When lz >= 2: left shift by (lz-1), exp -= (lz-1).

    lz = lzc106(s3_prod); // leading zeros from MSB (bit 105)

    if (lz == 7'd0) begin
      // leading 1 at bit 105: extract directly without using prod_norm shift.
      // prod_norm is unused in this path; assign a don't-care.
      prod_norm     = '0;
      s3_mant_c     = s3_prod[PROD_W-1 -: SIG_W];           // prod[105:53]
      s3_guard_c    = s3_prod[PROD_W-1 - SIG_W];             // prod[52]
      s3_round_c    = s3_prod[PROD_W-1 - SIG_W - 1];         // prod[51]
      s3_sticky_c   = |s3_prod[PROD_W-1 - SIG_W - 2 : 0];   // prod[50:0]
      s3_exp_norm_c = s2_exp_sum_q + 13'sd1;
    end else begin
      // leading 1 at bit (PROD_W-1-lz); left shift by (lz-1) to reach bit 104.
      prod_norm     = s3_prod << (lz - 7'd1);
      s3_mant_c     = prod_norm[PROD_W-2 -: SIG_W];
      s3_guard_c    = prod_norm[PROD_W-2 - SIG_W];
      s3_round_c    = prod_norm[PROD_W-2 - SIG_W - 1];
      s3_sticky_c   = |prod_norm[PROD_W-2 - SIG_W - 2 : 0];
      exp_adj       = 13'sd1 - {6'b0, lz};
      s3_exp_norm_c = s2_exp_sum_q + exp_adj;
    end

    // Now, for single-precision, the mantissa layout is {1, frac23, 29 zeros}
    // (since we left-padded the multiplicands with 29 zeros). The guard/round/
    // sticky must therefore be recomputed from the low 29 bits of the 53-bit
    // mantissa, OR'd with the previous sticky tail. We handle S/D uniformly
    // in the rounding stage by carrying a "trailing" width-adjusted GRS.
    //
    // Subnormal handling: if s3_exp_norm_c <= 0, shift the mantissa right by
    // (1 - s3_exp_norm_c) to denormalize, accumulating into sticky.
    begin
      mant_fullw = s3_mant_c;
      g_in = s3_guard_c;
      r_in = s3_round_c;
      s_in = s3_sticky_c;

      if (s3_exp_norm_c <= 13'sd0) begin
        shift_amt = 13'sd1 - s3_exp_norm_c;
        // clamp shift to avoid runaway; sh must hold values 0..64
        if (shift_amt >= 13'sd64) sh = 64;
        else                       sh = shift_amt[6:0];

        // Build a 64-bit tail to simplify sticky computation:
        // [mant (53)] [g (1)] [r (1)] [s (1)] ...
        begin
          tail = {mant_fullw, g_in, r_in, s_in, 8'd0};
          if (sh >= 64) begin
            shifted   = 64'd0;
            lost_mask = 64'hFFFF_FFFF_FFFF_FFFF;
          end else begin
            shifted   = tail >> sh;
            lost_mask = ~(64'hFFFF_FFFF_FFFF_FFFF << sh);
          end
          s3_mant_post_c  = shifted[63:11];
          s3_guard_post_c = shifted[10];
          s3_round_post_c = shifted[9];
          s3_sticky_post_c = |shifted[8:0] | (|(tail & lost_mask));
          s3_exp_post_c   = 13'sd0;
          s3_is_subnormal_c = 1'b1;
        end
      end else begin
        s3_mant_post_c  = mant_fullw;
        s3_guard_post_c = g_in;
        s3_round_post_c = r_in;
        s3_sticky_post_c = s_in;
        s3_exp_post_c   = s3_exp_norm_c;
        s3_is_subnormal_c = 1'b0;
      end
    end
  end

  // For single-precision, we need to fold the 29 low bits of the 53-bit
  // mantissa into sticky *after* the subnormal shift. This is done in S4
  // when we pick the format-specific fraction width.

  // -------------------------------------------------------------------------
  // S3 registers
  // -------------------------------------------------------------------------
  logic        s3_valid_q;
  logic        s3_fmt_d_q;
  logic [2:0]  s3_rm_q;
  fpu_tag_t    s3_tag_q;
  logic        s3_sign_q;
  logic signed [EXP_EXT_W-1:0] s3_exp_q;
  logic [SIG_W-1:0] s3_mant_q;
  logic s3_g_q, s3_r_q, s3_s_q;
  logic s3_is_subnormal_q;
  logic s3_any_snan_q, s3_any_nan_q, s3_inf_times_zero_q;
  logic s3_res_is_inf_q, s3_res_is_zero_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3_valid_q          <= 1'b0;
      s3_fmt_d_q          <= 1'b0;
      s3_rm_q             <= 3'd0;
      s3_tag_q            <= '0;
      s3_sign_q           <= 1'b0;
      s3_exp_q            <= '0;
      s3_mant_q           <= '0;
      s3_g_q              <= 1'b0;
      s3_r_q              <= 1'b0;
      s3_s_q              <= 1'b0;
      s3_is_subnormal_q   <= 1'b0;
      s3_any_snan_q       <= 1'b0;
      s3_any_nan_q        <= 1'b0;
      s3_inf_times_zero_q <= 1'b0;
      s3_res_is_inf_q     <= 1'b0;
      s3_res_is_zero_q    <= 1'b0;
    end else begin
      s3_valid_q          <= flush_i ? 1'b0 : s2_valid_q;
      s3_fmt_d_q          <= s2_fmt_d_q;
      s3_rm_q             <= s2_rm_q;
      s3_tag_q            <= s2_tag_q;
      s3_sign_q           <= s2_sign_q;
      s3_exp_q            <= s3_exp_post_c;
      s3_mant_q           <= s3_mant_post_c;
      s3_g_q              <= s3_guard_post_c;
      s3_r_q              <= s3_round_post_c;
      s3_s_q              <= s3_sticky_post_c;
      s3_is_subnormal_q   <= s3_is_subnormal_c;
      s3_any_snan_q       <= s2_any_snan_q;
      s3_any_nan_q        <= s2_any_nan_q;
      s3_inf_times_zero_q <= s2_inf_times_zero_q;
      s3_res_is_inf_q     <= s2_res_is_inf_q;
      s3_res_is_zero_q    <= s2_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S4 combinational: round, overflow/underflow, pack, NaN-box
  // -------------------------------------------------------------------------
  logic [63:0] s4_result_c;
  logic [4:0]  s4_fflags_c;

  // Rounding helper
  function automatic logic round_up(
    input logic [2:0] rm,
    input logic       sign,
    input logic       lsb,    // LSB of kept mantissa
    input logic       g,      // guard
    input logic       r,      // round
    input logic       s       // sticky
  );
    logic round_bit;
    logic sticky;
    round_bit = g;
    sticky    = r | s;
    unique case (rm)
      3'b000: // RNE: round to nearest, ties to even
        round_up = round_bit & (sticky | lsb);
      3'b001: // RTZ
        round_up = 1'b0;
      3'b010: // RDN (toward -inf)
        round_up = sign & (round_bit | sticky);
      3'b011: // RUP (toward +inf)
        round_up = (~sign) & (round_bit | sticky);
      3'b100: // RMM
        round_up = round_bit;
      default:
        round_up = 1'b0;
    endcase
  endfunction

  always_comb begin
    logic signed [EXP_EXT_W-1:0] exp_in;
    logic [SIG_W-1:0] mant_in;
    logic g_in, r_in, s_in;
    logic [SIG_W-1:0] mant_kept;
    logic g_eff, r_eff, s_eff;
    logic round_inc;
    logic [SIG_W:0]  mant_rnd;       // 54 bits to catch carry-out
    logic signed [EXP_EXT_W-1:0] exp_rnd;
    logic inexact;
    logic overflow;
    logic underflow_tiny;            // subnormal before rounding
    logic [S_EXP_W-1:0] pack_exp_s;
    logic [D_EXP_W-1:0] pack_exp_d;
    logic [S_SIG_W-1:0] pack_frac_s;
    logic [D_SIG_W-1:0] pack_frac_d;

    s4_result_c = '0;
    s4_fflags_c = '0;

    exp_in  = s3_exp_q;
    mant_in = s3_mant_q;
    g_in    = s3_g_q;
    r_in    = s3_r_q;
    s_in    = s3_s_q;

    // Extract kept mantissa + per-format GRS.
    // For single, kept fraction is bits [51:29] of mant_in, and [28:0] must
    // be folded into sticky along with g_in/r_in/s_in.
    if (s3_fmt_d_q) begin
      mant_kept = mant_in;       // 53 bits already
      g_eff = g_in;
      r_eff = r_in;
      s_eff = s_in;
    end else begin
      // Single: keep bits [52:29] (hidden + 23 frac). Next bit [28] is guard.
      mant_kept = {{(SIG_W - (1 + S_SIG_W)){1'b0}}, mant_in[52:29]};
      g_eff = mant_in[28];
      r_eff = mant_in[27];
      s_eff = |mant_in[26:0] | g_in | r_in | s_in;
    end

    // Determine if rounding increments mantissa
    round_inc = round_up(s3_rm_q, s3_sign_q, mant_kept[0], g_eff, r_eff, s_eff);
    mant_rnd  = {1'b0, mant_kept} + {{SIG_W{1'b0}}, round_inc};
    exp_rnd   = exp_in;
    inexact   = g_eff | r_eff | s_eff;

    // Carry out of mantissa after rounding: shift right and bump exponent.
    // For single, carry means mant[24] set.
    // For double, carry means mant[53] set.
    // We also need to handle the subnormal→normal transition: when the
    // subnormal mantissa rounds up to 1.0 in the hidden-bit position, the
    // exponent becomes 1 (normal).
    if (s3_fmt_d_q) begin
      if (mant_rnd[SIG_W]) begin
        // carry out of double's 53-bit field
        mant_rnd = mant_rnd >> 1;
        exp_rnd  = exp_rnd + 13'sd1;
      end
      // Subnormal that rounded into normal: mant_rnd[SIG_W-1]==1 (hidden),
      // exp was 0 (subnormal). Bump exp to 1.
      if ((exp_in == 13'sd0) && mant_rnd[SIG_W-1]) begin
        exp_rnd = 13'sd1;
      end
    end else begin
      // For single: kept field is low 24 bits of mant_rnd.
      if (mant_rnd[1 + S_SIG_W]) begin
        // carry out into bit 24
        mant_rnd = mant_rnd >> 1;
        exp_rnd  = exp_rnd + 13'sd1;
      end
      if ((exp_in == 13'sd0) && mant_rnd[S_SIG_W]) begin
        exp_rnd = 13'sd1;
      end
    end

    underflow_tiny = s3_is_subnormal_q;

    // -------- Build result --------
    if (s3_any_snan_q) begin
      // sNaN operand → invalid, canonical qNaN
      s4_fflags_c[FP_FFLAG_NV] = 1'b1;
      s4_result_c = s3_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s3_inf_times_zero_q) begin
      // inf * 0 → invalid, canonical qNaN
      s4_fflags_c[FP_FFLAG_NV] = 1'b1;
      s4_result_c = s3_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s3_any_nan_q) begin
      // qNaN propagation → canonical qNaN, no flag
      s4_result_c = s3_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s3_res_is_inf_q) begin
      // inf * finite(non-zero) → signed infinity, no flag
      if (s3_fmt_d_q) begin
        s4_result_c = {s3_sign_q, 11'h7FF, 52'd0};
      end else begin
        s4_result_c = {FP_NANBOX_UPPER, s3_sign_q, 8'hFF, 23'd0};
      end
    end else if (s3_res_is_zero_q) begin
      // zero * finite → signed zero, no flag
      if (s3_fmt_d_q) begin
        s4_result_c = {s3_sign_q, 63'd0};
      end else begin
        s4_result_c = {FP_NANBOX_UPPER, s3_sign_q, 31'd0};
      end
    end else begin
      // Normal numeric path — check overflow/underflow against format range.
      if (s3_fmt_d_q) begin
        overflow = (exp_rnd >= 13'sd2047);
        if (overflow) begin
          s4_fflags_c[FP_FFLAG_OF] = 1'b1;
          s4_fflags_c[FP_FFLAG_NX] = 1'b1;
          // Rounding mode controls whether we produce inf or max-finite.
          unique case (s3_rm_q)
            3'b001: // RTZ → max-finite
              s4_result_c = {s3_sign_q, 11'h7FE, {D_SIG_W{1'b1}}};
            3'b010: // RDN
              s4_result_c = s3_sign_q ? {1'b1, 11'h7FF, 52'd0}
                                       : {1'b0, 11'h7FE, {D_SIG_W{1'b1}}};
            3'b011: // RUP
              s4_result_c = s3_sign_q ? {1'b1, 11'h7FE, {D_SIG_W{1'b1}}}
                                       : {1'b0, 11'h7FF, 52'd0};
            default: // RNE, RMM → inf
              s4_result_c = {s3_sign_q, 11'h7FF, 52'd0};
          endcase
        end else begin
          // Pack exponent and fraction
          if (exp_rnd <= 13'sd0) begin
            pack_exp_d = 11'd0;
          end else begin
            pack_exp_d = exp_rnd[D_EXP_W-1:0];
          end
          pack_frac_d = mant_rnd[D_SIG_W-1:0];
          s4_result_c = {s3_sign_q, pack_exp_d, pack_frac_d};
          s4_fflags_c[FP_FFLAG_NX] = inexact;
          // Underflow: tiny before rounding AND inexact after rounding
          // (IEEE 754 "after rounding" underflow flag semantics).
          s4_fflags_c[FP_FFLAG_UF] = underflow_tiny & inexact & (pack_exp_d == 11'd0);
        end
      end else begin
        overflow = (exp_rnd >= 13'sd255);
        if (overflow) begin
          s4_fflags_c[FP_FFLAG_OF] = 1'b1;
          s4_fflags_c[FP_FFLAG_NX] = 1'b1;
          unique case (s3_rm_q)
            3'b001:
              s4_result_c = {FP_NANBOX_UPPER, s3_sign_q, 8'hFE, {S_SIG_W{1'b1}}};
            3'b010:
              s4_result_c = s3_sign_q
                ? {FP_NANBOX_UPPER, 1'b1, 8'hFF, 23'd0}
                : {FP_NANBOX_UPPER, 1'b0, 8'hFE, {S_SIG_W{1'b1}}};
            3'b011:
              s4_result_c = s3_sign_q
                ? {FP_NANBOX_UPPER, 1'b1, 8'hFE, {S_SIG_W{1'b1}}}
                : {FP_NANBOX_UPPER, 1'b0, 8'hFF, 23'd0};
            default:
              s4_result_c = {FP_NANBOX_UPPER, s3_sign_q, 8'hFF, 23'd0};
          endcase
        end else begin
          if (exp_rnd <= 13'sd0) begin
            pack_exp_s = 8'd0;
          end else begin
            pack_exp_s = exp_rnd[S_EXP_W-1:0];
          end
          pack_frac_s = mant_rnd[S_SIG_W-1:0];
          s4_result_c = {FP_NANBOX_UPPER, s3_sign_q, pack_exp_s, pack_frac_s};
          s4_fflags_c[FP_FFLAG_NX] = inexact;
          s4_fflags_c[FP_FFLAG_UF] = underflow_tiny & inexact & (pack_exp_s == 8'd0);
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // S4 output registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s3_valid_q;
      result_o    <= s4_result_c;
      fflags_o    <= s4_fflags_c;
      tag_o       <= s3_tag_q;
    end
  end

endmodule
