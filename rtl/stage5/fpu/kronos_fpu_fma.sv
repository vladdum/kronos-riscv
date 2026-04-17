// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Single-rounded fused multiply-add for binary32 and binary64.
// Computes +/-(a*b) +/- c with a single rounding step applied after the
// full-precision multiply-add.  Pipelined over 5 cycles:
//   S1 : decompose operands, decode specials, compute prod sign/exponent
//   S2 : significand multiply (48b for S, 106b for D)
//   S3 : align addend against product (wide sticky capture)
//   S4 : add / subtract, leading-zero normalize, collect G/R/S
//   S5 : round, encode result, merge special handling and flags
//
// Subnormal inputs are treated like normals with zero leading bit and the
// biased exponent bumped to the subnormal emin.  Subnormal outputs fall out of
// the normal normalize + round path via the tininess-after-rounding rule used
// across the rest of the FPU.

module kronos_fpu_fma
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
  input  logic [63:0] c_i,
  input  fpu_tag_t    tag_i,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // ---------------------------------------------------------------------------
  // Datapath widths
  //   - Unified 53-bit significand (hidden bit + 52-bit fraction)
  //   - Product significand: 106 bits (full 53x53)
  //   - Aligned addend lane: PROD_WIDTH + PAD (= 160b), addend sits just under
  //     the product and spills into the low pad for sticky bits.
  // ---------------------------------------------------------------------------
  localparam int unsigned SIG_W      = 53;          // significand incl. hidden
  localparam int unsigned PROD_W     = 2 * SIG_W;   // 106
  localparam int unsigned PAD_W      = 54;          // headroom for shift-out
  localparam int unsigned SUM_W      = PROD_W + PAD_W; // 160

  // Exponent bias per format
  localparam int signed S_BIAS = 127;
  localparam int signed D_BIAS = 1023;

  // ---------------------------------------------------------------------------
  // Helpers: classification
  // ---------------------------------------------------------------------------
  function automatic logic is_snan_s(logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b1);
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
  function automatic logic is_inf_d(logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51:0] == 52'd0);
  endfunction
  function automatic logic is_zero_d(logic [63:0] x);
    return (x[62:0] == 63'd0);
  endfunction

  // ---------------------------------------------------------------------------
  // Stage 1 combinational: decompose, detect specials
  // ---------------------------------------------------------------------------
  logic [31:0] a_s, b_s, c_s;
  logic [63:0] a_d, b_d, c_d;

  // Common signal shape per operand
  logic        s1_a_sign, s1_b_sign, s1_c_sign;
  logic signed [12:0] s1_a_exp, s1_b_exp, s1_c_exp; // biased exponent
  logic [52:0] s1_a_sig, s1_b_sig, s1_c_sig;
  logic        s1_a_zero, s1_b_zero, s1_c_zero;
  logic        s1_a_inf, s1_b_inf, s1_c_inf;
  logic        s1_a_nan, s1_b_nan, s1_c_nan;
  logic        s1_a_snan, s1_b_snan, s1_c_snan;

  logic        s1_negate_product, s1_negate_addend;
  logic        s1_prod_sign, s1_addend_sign;
  logic signed [12:0] s1_prod_exp;  // biased exponent of product
  logic        s1_prod_zero;

  // Special result flags
  logic        s1_special;
  logic [63:0] s1_special_result;
  logic [4:0]  s1_special_flags;

  always_comb begin
    // NaN-unbox single operands
    a_s = (a_i[63:32] == FP_NANBOX_UPPER) ? a_i[31:0] : FP_CANON_QNAN_S;
    b_s = (b_i[63:32] == FP_NANBOX_UPPER) ? b_i[31:0] : FP_CANON_QNAN_S;
    c_s = (c_i[63:32] == FP_NANBOX_UPPER) ? c_i[31:0] : FP_CANON_QNAN_S;
    a_d = a_i;
    b_d = b_i;
    c_d = c_i;

    if (fmt_d_i) begin
      s1_a_sign = a_d[63];
      s1_b_sign = b_d[63];
      s1_c_sign = c_d[63];

      // Exponent: for subnormal (exp==0, sig!=0) effective exponent is 1.
      s1_a_exp = (a_d[62:52] == 11'd0) ? 13'sd1 : {2'b00, a_d[62:52]};
      s1_b_exp = (b_d[62:52] == 11'd0) ? 13'sd1 : {2'b00, b_d[62:52]};
      s1_c_exp = (c_d[62:52] == 11'd0) ? 13'sd1 : {2'b00, c_d[62:52]};

      // Significand: explicit leading bit (1 for normal, 0 for subnormal/zero)
      s1_a_sig = {(a_d[62:52] != 11'd0), a_d[51:0]};
      s1_b_sig = {(b_d[62:52] != 11'd0), b_d[51:0]};
      s1_c_sig = {(c_d[62:52] != 11'd0), c_d[51:0]};

      s1_a_zero = is_zero_d(a_d);
      s1_b_zero = is_zero_d(b_d);
      s1_c_zero = is_zero_d(c_d);
      s1_a_inf  = is_inf_d(a_d);
      s1_b_inf  = is_inf_d(b_d);
      s1_c_inf  = is_inf_d(c_d);
      s1_a_nan  = is_snan_d(a_d) || is_qnan_d(a_d);
      s1_b_nan  = is_snan_d(b_d) || is_qnan_d(b_d);
      s1_c_nan  = is_snan_d(c_d) || is_qnan_d(c_d);
      s1_a_snan = is_snan_d(a_d);
      s1_b_snan = is_snan_d(b_d);
      s1_c_snan = is_snan_d(c_d);
    end else begin
      s1_a_sign = a_s[31];
      s1_b_sign = b_s[31];
      s1_c_sign = c_s[31];

      s1_a_exp = (a_s[30:23] == 8'd0) ? 13'sd1 : {5'd0, a_s[30:23]};
      s1_b_exp = (b_s[30:23] == 8'd0) ? 13'sd1 : {5'd0, b_s[30:23]};
      s1_c_exp = (c_s[30:23] == 8'd0) ? 13'sd1 : {5'd0, c_s[30:23]};

      // Expand 24-bit S significand into 53-bit field (left-aligned in
      // the 53-bit container: hidden bit at [52], fraction at [51:29]).
      s1_a_sig = {(a_s[30:23] != 8'd0), a_s[22:0], 29'd0};
      s1_b_sig = {(b_s[30:23] != 8'd0), b_s[22:0], 29'd0};
      s1_c_sig = {(c_s[30:23] != 8'd0), c_s[22:0], 29'd0};

      s1_a_zero = is_zero_s(a_s);
      s1_b_zero = is_zero_s(b_s);
      s1_c_zero = is_zero_s(c_s);
      s1_a_inf  = is_inf_s(a_s);
      s1_b_inf  = is_inf_s(b_s);
      s1_c_inf  = is_inf_s(c_s);
      s1_a_nan  = is_snan_s(a_s) || is_qnan_s(a_s);
      s1_b_nan  = is_snan_s(b_s) || is_qnan_s(b_s);
      s1_c_nan  = is_snan_s(c_s) || is_qnan_s(c_s);
      s1_a_snan = is_snan_s(a_s);
      s1_b_snan = is_snan_s(b_s);
      s1_c_snan = is_snan_s(c_s);
    end

    // FMADD = a*b + c, FMSUB = a*b - c, FNMSUB = -(a*b) + c, FNMADD = -(a*b) - c.
    // FNMADD needs both the product AND the addend negated.
    s1_negate_product = (op_i == FP_FNMADD) || (op_i == FP_FNMSUB);
    s1_negate_addend  = (op_i == FP_FMSUB)  || (op_i == FP_FNMADD);

    s1_prod_sign   = s1_a_sign ^ s1_b_sign ^ s1_negate_product;
    s1_addend_sign = s1_c_sign ^ s1_negate_addend;

    // Biased exponent of product (before normalize of significand).
    // Product significand lies in [1,4): we'll handle the extra bit in stage 4.
    s1_prod_exp = s1_a_exp + s1_b_exp - 13'(fmt_d_i ? D_BIAS : S_BIAS);
    s1_prod_zero = s1_a_zero || s1_b_zero;

    // ---------- Special-case resolution ----------
    s1_special        = 1'b0;
    s1_special_result = '0;
    s1_special_flags  = '0;

    if (s1_a_snan || s1_b_snan || s1_c_snan) begin
      s1_special              = 1'b1;
      s1_special_result       = fmt_d_i ? FP_CANON_QNAN_D
                                        : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
      s1_special_flags[FP_FFLAG_NV] = 1'b1;
    end else if ((s1_a_inf && s1_b_zero) || (s1_a_zero && s1_b_inf)) begin
      // 0 * inf -> invalid
      s1_special              = 1'b1;
      s1_special_result       = fmt_d_i ? FP_CANON_QNAN_D
                                        : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
      s1_special_flags[FP_FFLAG_NV] = 1'b1;
    end else if ((s1_a_inf || s1_b_inf) && s1_c_inf &&
                 (s1_prod_sign != s1_addend_sign)) begin
      // Inf - Inf -> invalid
      s1_special              = 1'b1;
      s1_special_result       = fmt_d_i ? FP_CANON_QNAN_D
                                        : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
      s1_special_flags[FP_FFLAG_NV] = 1'b1;
    end else if (s1_a_nan || s1_b_nan || s1_c_nan) begin
      // Propagate as canonical qNaN
      s1_special        = 1'b1;
      s1_special_result = fmt_d_i ? FP_CANON_QNAN_D
                                  : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s1_a_inf || s1_b_inf) begin
      // Inf * finite (+/- finite addend, same sign or c finite)
      s1_special        = 1'b1;
      if (fmt_d_i) begin
        s1_special_result = {s1_prod_sign, 11'h7FF, 52'd0};
      end else begin
        s1_special_result = {FP_NANBOX_UPPER, s1_prod_sign, 8'hFF, 23'd0};
      end
    end else if (s1_c_inf) begin
      // finite * finite + inf -> +/- inf (sign = addend sign)
      s1_special        = 1'b1;
      if (fmt_d_i) begin
        s1_special_result = {s1_addend_sign, 11'h7FF, 52'd0};
      end else begin
        s1_special_result = {FP_NANBOX_UPPER, s1_addend_sign, 8'hFF, 23'd0};
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 1 -> Stage 2 register
  // ---------------------------------------------------------------------------
  logic              s2_valid;
  logic              s2_special;
  logic [63:0]       s2_special_result;
  logic [4:0]        s2_special_flags;
  logic              s2_fmt_d;
  logic [2:0]        s2_rm;
  logic              s2_prod_sign;
  logic              s2_addend_sign;
  logic signed [12:0] s2_prod_exp;
  logic signed [12:0] s2_c_exp;
  logic [52:0]       s2_a_sig;
  logic [52:0]       s2_b_sig;
  logic [52:0]       s2_c_sig;
  logic              s2_prod_zero;
  logic              s2_c_zero;
  fpu_tag_t          s2_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid          <= 1'b0;
      s2_special        <= 1'b0;
      s2_special_result <= '0;
      s2_special_flags  <= '0;
      s2_fmt_d          <= 1'b0;
      s2_rm             <= '0;
      s2_prod_sign      <= 1'b0;
      s2_addend_sign    <= 1'b0;
      s2_prod_exp       <= '0;
      s2_c_exp          <= '0;
      s2_a_sig          <= '0;
      s2_b_sig          <= '0;
      s2_c_sig          <= '0;
      s2_prod_zero      <= 1'b0;
      s2_c_zero         <= 1'b0;
      s2_tag            <= '0;
    end else begin
      s2_valid          <= flush_i ? 1'b0 : in_valid_i;
      s2_special        <= s1_special;
      s2_special_result <= s1_special_result;
      s2_special_flags  <= s1_special_flags;
      s2_fmt_d          <= fmt_d_i;
      s2_rm             <= rm_i;
      s2_prod_sign      <= s1_prod_sign;
      s2_addend_sign    <= s1_addend_sign;
      s2_prod_exp       <= s1_prod_exp;
      s2_c_exp          <= s1_c_exp;
      s2_a_sig          <= s1_a_sig;
      s2_b_sig          <= s1_b_sig;
      s2_c_sig          <= s1_c_sig;
      s2_prod_zero      <= s1_prod_zero;
      s2_c_zero         <= s1_c_zero;
      s2_tag            <= tag_i;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2: multiply significands
  // ---------------------------------------------------------------------------
  logic [PROD_W-1:0] s2_product_comb;

  always_comb begin
    s2_product_comb = s2_a_sig * s2_b_sig;
  end

  // Stage 2 -> Stage 3 register
  logic              s3_valid;
  logic              s3_special;
  logic [63:0]       s3_special_result;
  logic [4:0]        s3_special_flags;
  logic              s3_fmt_d;
  logic [2:0]        s3_rm;
  logic              s3_prod_sign;
  logic              s3_addend_sign;
  logic signed [12:0] s3_prod_exp;
  logic signed [12:0] s3_c_exp;
  logic [PROD_W-1:0] s3_product;
  logic [52:0]       s3_c_sig;
  logic              s3_prod_zero;
  logic              s3_c_zero;
  fpu_tag_t          s3_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3_valid          <= 1'b0;
      s3_special        <= 1'b0;
      s3_special_result <= '0;
      s3_special_flags  <= '0;
      s3_fmt_d          <= 1'b0;
      s3_rm             <= '0;
      s3_prod_sign      <= 1'b0;
      s3_addend_sign    <= 1'b0;
      s3_prod_exp       <= '0;
      s3_c_exp          <= '0;
      s3_product        <= '0;
      s3_c_sig          <= '0;
      s3_prod_zero      <= 1'b0;
      s3_c_zero         <= 1'b0;
      s3_tag            <= '0;
    end else begin
      s3_valid          <= flush_i ? 1'b0 : s2_valid;
      s3_special        <= s2_special;
      s3_special_result <= s2_special_result;
      s3_special_flags  <= s2_special_flags;
      s3_fmt_d          <= s2_fmt_d;
      s3_rm             <= s2_rm;
      s3_prod_sign      <= s2_prod_sign;
      s3_addend_sign    <= s2_addend_sign;
      s3_prod_exp       <= s2_prod_exp;
      s3_c_exp          <= s2_c_exp;
      s3_product        <= s2_product_comb;
      s3_c_sig          <= s2_c_sig;
      s3_prod_zero      <= s2_prod_zero;
      s3_c_zero         <= s2_c_zero;
      s3_tag            <= s2_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3: alignment
  //
  // We form two 160-bit lanes:
  //   prod_lane   : product placed at bits [PROD_W+PAD_W-1 : PAD_W]
  //   addend_lane : c_sig placed at the same bit position as the implicit
  //                 leading bit of the product, then shifted right by
  //                 (prod_exp - c_exp - SIG_W + 1).  When that shift is
  //                 negative, we instead shift the product right and align
  //                 against the addend; in that case we track the resulting
  //                 exponent accordingly.
  //
  // The result exponent candidate (before normalize) is the larger of
  // prod_exp and c_exp.
  // ---------------------------------------------------------------------------
  logic [SUM_W-1:0]    s3_prod_lane_comb;
  logic [SUM_W-1:0]    s3_c_lane_comb;
  logic signed [12:0]  s3_base_exp_comb;
  logic                s3_eff_sub_comb;

  always_comb begin
    logic signed [13:0] exp_diff;
    logic signed [13:0] shift_amt;
    logic [SUM_W-1:0]   c_extended;
    logic [SUM_W-1:0]   p_extended;
    int unsigned        sh;
    logic [SUM_W-1:0]   shifted;
    logic               sticky;
    int unsigned        i;

    // Defaults — prevents latches in branches that don't touch these.
    exp_diff  = '0;
    shift_amt = '0;
    sh        = 0;
    shifted   = '0;
    sticky    = 1'b0;

    s3_eff_sub_comb = s3_prod_sign ^ s3_addend_sign;

    // Place product so its top bit sits at [SUM_W-1-1 .. SUM_W-1]:
    //   product is up to PROD_W bits (2.xxxx or 1.xxxx at top).  We align
    //   its MSB to SUM_W-2 so that even the carry bit has room at SUM_W-1.
    p_extended = {1'b0, s3_product, {(PAD_W-1){1'b0}}};

    // Place addend's hidden bit at the same position as the product's MSB-1
    // (i.e. unit-of-least-precision line of the product's "1.xxxx" form).
    // product significand is a*b in Q(2*SIG_W) form; since both a_sig and
    // b_sig are in Q(SIG_W-1) (hidden-bit weight = 2^(SIG_W-1)), the product
    // has weight 2^(2*(SIG_W-1)) for its logical leading bit.  We want the
    // addend's hidden bit aligned to the same weight, i.e. at bit position
    // (2*SIG_W-2) in the product-only representation.  In the extended lane
    // the product MSB sits at bit index (PROD_W-1 + PAD_W-1) = SUM_W-2, and
    // its "hidden*hidden" bit sits at SUM_W-3 (since product is 1.x or 1x.x).
    //
    // To keep this simple, align the addend so its hidden bit sits at
    // position (SIG_W-1) + (PAD_W-1) when exp_diff == SIG_W-1, matching the
    // weight of the product's ulp.  Equivalently: place c_sig left-justified
    // and shift right by shift_amt = prod_exp - c_exp.
    c_extended = '0;
    // Reference position REF = SUM_W-3 = 157.  Place c_sig so its hidden bit
    // sits at REF when no alignment shift is needed.  The product occupies
    // bits [PROD_W-1 + (PAD_W-1) : PAD_W-1] = [158:53] in p_extended; its top
    // bit can be at 158 (2.x case) or 157 (1.x case).  Sharing REF with c
    // keeps bit-weights matched.
    c_extended[(SUM_W-3) -: SIG_W] = s3_c_sig;

    exp_diff = s3_prod_exp - s3_c_exp;

    if (s3_prod_zero) begin
      // Product is zero: result is just the addend.
      s3_prod_lane_comb = '0;
      s3_c_lane_comb    = c_extended;
      s3_base_exp_comb  = s3_c_exp;
    end else if (s3_c_zero) begin
      s3_prod_lane_comb = p_extended;
      s3_c_lane_comb    = '0;
      s3_base_exp_comb  = s3_prod_exp;
    end else if (exp_diff >= 0) begin
      // product >= addend: keep product, shift addend right by exp_diff.
      shift_amt = exp_diff;
      if (shift_amt > 14'(SUM_W - 1)) sh = SUM_W - 1;
      else                              sh = {22'd0, shift_amt[9:0]};
      shifted = c_extended >> sh;
      // Sticky-OR the bits that fell off.
      sticky = 1'b0;
      if (sh > 0) begin
        // collect shifted-out bits from c_extended's low sh bits
        for (i = 0; i < SUM_W; i = i + 1) begin
          if (i < sh) sticky = sticky | c_extended[i];
        end
      end
      s3_prod_lane_comb = p_extended;
      s3_c_lane_comb    = shifted | {{(SUM_W-1){1'b0}}, sticky};
      s3_base_exp_comb  = s3_prod_exp;
    end else begin
      // addend > product: shift product right by -exp_diff.
      shift_amt = -exp_diff;
      if (shift_amt > 14'(SUM_W - 1)) sh = SUM_W - 1;
      else                              sh = {22'd0, shift_amt[9:0]};
      shifted = p_extended >> sh;
      sticky = 1'b0;
      if (sh > 0) begin
        for (i = 0; i < SUM_W; i = i + 1) begin
          if (i < sh) sticky = sticky | p_extended[i];
        end
      end
      s3_prod_lane_comb = shifted | {{(SUM_W-1){1'b0}}, sticky};
      s3_c_lane_comb    = c_extended;
      s3_base_exp_comb  = s3_c_exp;
    end
  end

  // Stage 3 -> Stage 4 register
  logic              s4_valid;
  logic              s4_special;
  logic [63:0]       s4_special_result;
  logic [4:0]        s4_special_flags;
  logic              s4_fmt_d;
  logic [2:0]        s4_rm;
  logic              s4_prod_sign;
  logic              s4_addend_sign;
  logic signed [12:0] s4_base_exp;
  logic [SUM_W-1:0]  s4_prod_lane;
  logic [SUM_W-1:0]  s4_c_lane;
  logic              s4_eff_sub;
  fpu_tag_t          s4_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s4_valid          <= 1'b0;
      s4_special        <= 1'b0;
      s4_special_result <= '0;
      s4_special_flags  <= '0;
      s4_fmt_d          <= 1'b0;
      s4_rm             <= '0;
      s4_prod_sign      <= 1'b0;
      s4_addend_sign    <= 1'b0;
      s4_base_exp       <= '0;
      s4_prod_lane      <= '0;
      s4_c_lane         <= '0;
      s4_eff_sub        <= 1'b0;
      s4_tag            <= '0;
    end else begin
      s4_valid          <= flush_i ? 1'b0 : s3_valid;
      s4_special        <= s3_special;
      s4_special_result <= s3_special_result;
      s4_special_flags  <= s3_special_flags;
      s4_fmt_d          <= s3_fmt_d;
      s4_rm             <= s3_rm;
      s4_prod_sign      <= s3_prod_sign;
      s4_addend_sign    <= s3_addend_sign;
      s4_base_exp       <= s3_base_exp_comb;
      s4_prod_lane      <= s3_prod_lane_comb;
      s4_c_lane         <= s3_c_lane_comb;
      s4_eff_sub        <= s3_eff_sub_comb;
      s4_tag            <= s3_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 4: add/subtract, leading-zero normalize
  // ---------------------------------------------------------------------------
  logic [SUM_W:0]      s4_sum_comb;     // 161b with room for 1-bit carry
  logic                s4_res_sign_comb;
  logic                s4_zero_comb;
  logic signed [12:0]  s4_norm_exp_comb;
  logic [SUM_W-1:0]    s4_norm_mag_comb;

  always_comb begin
    logic [SUM_W-1:0]   diff;
    logic [SUM_W-1:0]   mag;
    logic               sign;
    int                 msb_pos;
    int unsigned        i;
    logic signed [12:0] exp;
    int                 ref_pos;

    diff    = '0;
    mag     = '0;
    sign    = 1'b0;
    msb_pos = -1;
    exp     = '0;
    ref_pos = SUM_W - 3;  // 157

    if (!s4_eff_sub) begin
      s4_sum_comb = {1'b0, s4_prod_lane} + {1'b0, s4_c_lane};
      mag         = s4_sum_comb[SUM_W-1:0];
      sign        = s4_prod_sign;
    end else begin
      if (s4_prod_lane >= s4_c_lane) begin
        diff = s4_prod_lane - s4_c_lane;
        sign = s4_prod_sign;
      end else begin
        diff = s4_c_lane - s4_prod_lane;
        sign = s4_addend_sign;
      end
      s4_sum_comb = {1'b0, diff};
      mag         = diff;
    end

    s4_zero_comb = (mag == '0);

    // Find position of MSB (highest set bit) in mag.  If none, msb_pos = -1.
    msb_pos = -1;
    for (i = 0; i < SUM_W; i = i + 1) begin
      if (mag[i] && (msb_pos < $signed(i))) msb_pos = i;
    end

    // New exponent = base_exp + (msb_pos - ref_pos).  Keep significand in mag
    // untouched; downstream stage 5 will shift based on (msb_pos, exp).
    if (s4_zero_comb) begin
      exp = '0;
      s4_norm_mag_comb = '0;
    end else begin
      exp = s4_base_exp + 13'(msb_pos - ref_pos);
      s4_norm_mag_comb = mag;
    end

    s4_norm_exp_comb = exp;
    s4_res_sign_comb = sign;
  end

  // MSB position captured for stage 5.  Recompute from mag in stage 5 via
  // another LZC pass; but to avoid re-doing the loop there, propagate it.
  logic [8:0] s4_msb_pos_comb;
  always_comb begin
    int        i;
    int        m;
    i = 0;
    m = -1;
    for (i = 0; i < SUM_W; i = i + 1) begin
      if (s4_norm_mag_comb[i] && (m < $signed(i))) m = i;
    end
    if (m < 0) s4_msb_pos_comb = 9'd0;
    else       s4_msb_pos_comb = m[8:0];
  end

  // Stage 4 -> Stage 5 register
  logic              s5_valid;
  logic              s5_special;
  logic [63:0]       s5_special_result;
  logic [4:0]        s5_special_flags;
  logic              s5_fmt_d;
  logic [2:0]        s5_rm;
  logic              s5_res_sign;
  logic              s5_zero;
  logic signed [12:0] s5_norm_exp;
  logic [SUM_W-1:0]  s5_norm_mag;
  logic              s5_eff_sub;
  logic              s5_prod_sign;
  logic [8:0]        s5_msb_pos;
  fpu_tag_t          s5_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s5_valid          <= 1'b0;
      s5_special        <= 1'b0;
      s5_special_result <= '0;
      s5_special_flags  <= '0;
      s5_fmt_d          <= 1'b0;
      s5_rm             <= '0;
      s5_res_sign       <= 1'b0;
      s5_zero           <= 1'b0;
      s5_norm_exp       <= '0;
      s5_norm_mag       <= '0;
      s5_eff_sub        <= 1'b0;
      s5_prod_sign      <= 1'b0;
      s5_msb_pos        <= '0;
      s5_tag            <= '0;
    end else begin
      s5_valid          <= flush_i ? 1'b0 : s4_valid;
      s5_special        <= s4_special;
      s5_special_result <= s4_special_result;
      s5_special_flags  <= s4_special_flags;
      s5_fmt_d          <= s4_fmt_d;
      s5_rm             <= s4_rm;
      s5_res_sign       <= s4_res_sign_comb;
      s5_zero           <= s4_zero_comb;
      s5_norm_exp       <= s4_norm_exp_comb;
      s5_norm_mag       <= s4_norm_mag_comb;
      s5_eff_sub        <= s4_eff_sub;
      s5_prod_sign      <= s4_prod_sign;
      s5_msb_pos        <= s4_msb_pos_comb;
      s5_tag            <= s4_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 5: round and pack
  // ---------------------------------------------------------------------------
  logic [63:0] s5_result_comb;
  logic [4:0]  s5_flags_comb;

  always_comb begin
    int unsigned        frac_w;
    int signed          bias;
    logic signed [12:0] emin;
    logic signed [12:0] emax;
    logic [52:0]        raw_sig;
    logic [SUM_W-1:0]   mag;
    logic signed [12:0] exp;
    logic signed [12:0] exp_pre_tiny;
    logic               guard;
    logic               round_b;
    logic               sticky;
    logic               round_up;
    logic [53:0]        rounded_sig; // 54 bits so carry-out of rounding survives
    logic               inexact;
    logic               overflow_ovf;
    logic               tiny;
    int unsigned        shift_right_amt;
    int unsigned        normal_shift;
    int unsigned        i;
    logic [SUM_W-1:0]   pre_mag;
    logic [52:0]        final_sig;
    logic signed [12:0] final_exp;
    logic [10:0]        exp_field_d;
    logic [7:0]         exp_field_s;
    // IEEE 754(b) normal-scale rounding (for UF detection):
    //   "tininess after rounding" uses rounding with unbounded exponent
    //   range.  If normal-scale rounding carries from all-1s mantissa up
    //   to 2.0, the rounded value sits at exactly 2^emin and is NOT tiny.
    logic [52:0]        raw_sig_n;
    logic               guard_n, round_n, sticky_n;
    logic               round_up_n;
    logic               carry_n;
    logic [SUM_W-1:0]   pre_mag_n;

    frac_w        = 0;
    bias          = 0;
    emin          = '0;
    emax          = '0;
    raw_sig       = '0;
    mag           = '0;
    exp           = '0;
    exp_pre_tiny  = '0;
    guard         = 1'b0;
    round_b       = 1'b0;
    sticky        = 1'b0;
    round_up      = 1'b0;
    rounded_sig   = '0;
    inexact       = 1'b0;
    overflow_ovf  = 1'b0;
    tiny          = 1'b0;
    shift_right_amt = 0;
    normal_shift  = 0;
    i             = 0;
    pre_mag       = '0;
    final_sig     = '0;
    final_exp     = '0;
    exp_field_d   = '0;
    exp_field_s   = '0;
    raw_sig_n     = '0;
    guard_n       = 1'b0;
    round_n       = 1'b0;
    sticky_n      = 1'b0;
    round_up_n    = 1'b0;
    carry_n       = 1'b0;
    pre_mag_n     = '0;

    s5_result_comb = '0;
    s5_flags_comb  = s5_special_flags;

    if (s5_special) begin
      s5_result_comb = s5_special_result;
    end else if (s5_zero) begin
      // Exact zero result. Sign rules:
      //   - same-sign add: sign = prod_sign (== addend_sign)
      //   - exact cancellation (eff_sub): +0 in all modes except RDN which is -0
      if (s5_eff_sub) begin
        if (s5_rm == FP_RM_RDN) begin
          s5_result_comb = s5_fmt_d ? {1'b1, 63'd0}
                                    : {FP_NANBOX_UPPER, 1'b1, 31'd0};
        end else begin
          s5_result_comb = s5_fmt_d ? 64'd0
                                    : {FP_NANBOX_UPPER, 32'd0};
        end
      end else begin
        // Both lanes zero or same-sign add of zeros: sign = prod_sign
        if (s5_prod_sign) begin
          s5_result_comb = s5_fmt_d ? {1'b1, 63'd0}
                                    : {FP_NANBOX_UPPER, 1'b1, 31'd0};
        end else begin
          s5_result_comb = s5_fmt_d ? 64'd0
                                    : {FP_NANBOX_UPPER, 32'd0};
        end
      end
    end else begin
      // Format-dependent parameters
      if (s5_fmt_d) begin
        frac_w = 52;
        bias   = D_BIAS;
        emax   = 13'sd2046; // largest finite biased exp
      end else begin
        frac_w = 23;
        bias   = S_BIAS;
        emax   = 13'sd254;
      end
      emin = 13'sd1;

      mag = s5_norm_mag;
      exp = s5_norm_exp;

      // Hidden bit (MSB of mag) is at index s5_msb_pos.  Shift it down to
      // position frac_w: shift_right_amt = msb_pos - frac_w.  For subnormal
      // outputs (exp < emin), shift by an extra (emin - exp) and force exp=0.
      if ({1'b0, s5_msb_pos} >= 10'(frac_w))
        normal_shift = {23'd0, s5_msb_pos} - frac_w;
      else
        normal_shift = 0;
      shift_right_amt = normal_shift;

      tiny = 1'b0;
      exp_pre_tiny = exp;
      if (exp < emin) begin
        shift_right_amt = shift_right_amt + 32'(emin - exp);
        exp  = 0;
        tiny = 1'b1;
      end

      if (shift_right_amt >= SUM_W) begin
        // Entire mag is sub-ulp sticky.
        raw_sig = '0;
        guard   = 1'b0;
        round_b = 1'b0;
        sticky  = (mag != '0);
      end else begin
        // raw_sig = mag[shift_right_amt + frac_w : shift_right_amt]
        // guard   = mag[shift_right_amt - 1]
        // round_b = mag[shift_right_amt - 2]
        // sticky  = OR(mag[shift_right_amt-3 : 0])
        pre_mag = mag >> shift_right_amt;
        raw_sig = pre_mag[52:0];

        if (shift_right_amt == 0) begin
          guard  = 1'b0;
          round_b = 1'b0;
          sticky = 1'b0;
        end else if (shift_right_amt == 1) begin
          guard  = mag[0];
          round_b = 1'b0;
          sticky = 1'b0;
        end else if (shift_right_amt == 2) begin
          guard  = mag[1];
          round_b = mag[0];
          sticky = 1'b0;
        end else begin
          guard  = mag[shift_right_amt - 1];
          round_b = mag[shift_right_amt - 2];
          sticky = 1'b0;
          for (i = 0; i < SUM_W; i = i + 1) begin
            if (i + 2 < shift_right_amt) begin
              sticky = sticky | mag[i];
            end
          end
        end
      end

      // Round decision
      inexact = guard | round_b | sticky;
      round_up = 1'b0;
      unique case (s5_rm)
        FP_RM_RNE: round_up = guard & (round_b | sticky | raw_sig[0]);
        FP_RM_RTZ: round_up = 1'b0;
        FP_RM_RDN: round_up = inexact & s5_res_sign;
        FP_RM_RUP: round_up = inexact & ~s5_res_sign;
        FP_RM_RMM: round_up = guard; // round to nearest, ties away
        default: round_up = 1'b0;
      endcase

      rounded_sig = {1'b0, raw_sig} + (round_up ? 54'd1 : 54'd0);
      final_exp   = exp;
      final_sig   = rounded_sig[52:0];

      // If rounding overflowed the significand (now has bit frac_w+1),
      // shift right by 1 and bump exponent.
      if (rounded_sig[frac_w + 1]) begin
        final_sig = rounded_sig[53:1];
        final_exp = exp + 1;
      end

      // If subnormal rounded up to a normal number, the hidden bit will now
      // be set at position frac_w and exponent should become emin.
      if (tiny && final_sig[frac_w]) begin
        final_exp = emin;
      end

      // Overflow: final_exp >= emax+1 (i.e. all-ones field)
      overflow_ovf = 1'b0;
      if (final_exp >= (emax + 13'sd1)) begin
        overflow_ovf = 1'b1;
      end

      // Underflow flag: RISC-V uses "tininess after rounding" (IEEE 754
      // alternative (b) -- round with the format precision but unbounded
      // exponent range, then check if the rounded magnitude is strictly
      // below 2^emin).  When the subnormal-scale rounding differs from
      // the normal-scale rounding (i.e. when the 24/53-bit normal-scale
      // mantissa is all ones and rounds up, carrying to 2.0), the
      // unbounded-exponent rounded value lands exactly at 2^emin and is
      // NOT tiny -- even though the subnormal encoding bumps to the
      // smallest normal.
      if (tiny && inexact) begin
        // Extract normal-scale round bits from mag at normal_shift.
        if (normal_shift >= SUM_W) begin
          raw_sig_n = '0;
          guard_n   = 1'b0;
          round_n   = 1'b0;
          sticky_n  = (mag != '0);
        end else begin
          pre_mag_n = mag >> normal_shift;
          raw_sig_n = pre_mag_n[52:0];
          if (normal_shift == 0) begin
            guard_n  = 1'b0;
            round_n  = 1'b0;
            sticky_n = 1'b0;
          end else if (normal_shift == 1) begin
            guard_n  = mag[0];
            round_n  = 1'b0;
            sticky_n = 1'b0;
          end else if (normal_shift == 2) begin
            guard_n  = mag[1];
            round_n  = mag[0];
            sticky_n = 1'b0;
          end else begin
            guard_n  = mag[normal_shift - 1];
            round_n  = mag[normal_shift - 2];
            sticky_n = 1'b0;
            for (i = 0; i < SUM_W; i = i + 1) begin
              if (i + 2 < normal_shift) begin
                sticky_n = sticky_n | mag[i];
              end
            end
          end
        end

        unique case (s5_rm)
          FP_RM_RNE: round_up_n = guard_n & (round_n | sticky_n | raw_sig_n[0]);
          FP_RM_RTZ: round_up_n = 1'b0;
          FP_RM_RDN: round_up_n = (guard_n | round_n | sticky_n) &  s5_res_sign;
          FP_RM_RUP: round_up_n = (guard_n | round_n | sticky_n) & ~s5_res_sign;
          FP_RM_RMM: round_up_n = guard_n;
          default:   round_up_n = 1'b0;
        endcase

        // Carry-out: mantissa (hidden+fraction) is all ones and rounds up.
        if (s5_fmt_d)
          carry_n = round_up_n & (&raw_sig_n[52:0]);
        else
          carry_n = round_up_n & (&raw_sig_n[23:0]);

        // Tiny after rounding iff exp_pre_tiny + carry_n < emin.
        // `tiny` means exp_pre_tiny < emin already, so this collapses to
        // "NOT (carry_n AND exp_pre_tiny == emin - 1)".
        if (!(carry_n && (exp_pre_tiny + 13'sd1 == emin))) begin
          s5_flags_comb[FP_FFLAG_UF] = 1'b1;
        end
      end

      if (inexact) s5_flags_comb[FP_FFLAG_NX] = 1'b1;

      if (overflow_ovf) begin
        s5_flags_comb[FP_FFLAG_OF] = 1'b1;
        s5_flags_comb[FP_FFLAG_NX] = 1'b1;
        // Round-to-nearest and RMM: +/-inf
        // RTZ: +/-max
        // RDN: -inf for negative, +max for positive
        // RUP: +inf for positive, -max for negative
        unique case (s5_rm)
          FP_RM_RTZ: begin
            if (s5_fmt_d) s5_result_comb = {s5_res_sign, 11'd2046, {52{1'b1}}};
            else          s5_result_comb = {FP_NANBOX_UPPER,
                                            s5_res_sign, 8'd254, {23{1'b1}}};
          end
          FP_RM_RDN: begin
            if (s5_res_sign) begin
              if (s5_fmt_d) s5_result_comb = {1'b1, 11'h7FF, 52'd0};
              else          s5_result_comb = {FP_NANBOX_UPPER, 1'b1, 8'hFF, 23'd0};
            end else begin
              if (s5_fmt_d) s5_result_comb = {1'b0, 11'd2046, {52{1'b1}}};
              else          s5_result_comb = {FP_NANBOX_UPPER,
                                              1'b0, 8'd254, {23{1'b1}}};
            end
          end
          FP_RM_RUP: begin
            if (s5_res_sign) begin
              if (s5_fmt_d) s5_result_comb = {1'b1, 11'd2046, {52{1'b1}}};
              else          s5_result_comb = {FP_NANBOX_UPPER,
                                              1'b1, 8'd254, {23{1'b1}}};
            end else begin
              if (s5_fmt_d) s5_result_comb = {1'b0, 11'h7FF, 52'd0};
              else          s5_result_comb = {FP_NANBOX_UPPER, 1'b0, 8'hFF, 23'd0};
            end
          end
          default: begin
            // RNE, RMM, reserved: +/-inf
            if (s5_fmt_d) s5_result_comb = {s5_res_sign, 11'h7FF, 52'd0};
            else          s5_result_comb = {FP_NANBOX_UPPER,
                                            s5_res_sign, 8'hFF, 23'd0};
          end
        endcase
      end else begin
        // Normal encoding
        if (s5_fmt_d) begin
          exp_field_d = final_exp[10:0];
          s5_result_comb = {s5_res_sign, exp_field_d, final_sig[51:0]};
        end else begin
          exp_field_s = final_exp[7:0];
          s5_result_comb = {FP_NANBOX_UPPER, s5_res_sign, exp_field_s,
                            final_sig[22:0]};
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 5 register -> outputs
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s5_valid;
      result_o    <= s5_result_comb;
      fflags_o    <= s5_flags_comb;
      tag_o       <= s5_tag;
    end
  end

endmodule
