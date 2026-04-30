// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Single-rounded fused multiply-add for binary32 and binary64.
// Computes +/-(a*b) +/- c with a single rounding step applied after the
// full-precision multiply-add.  Pipelined over 9 cycles:
// S1(decompose) -> S2(mul operand reg) -> S2b(mul operand re-latch) ->
//   S3(product reg + alignment compute) -> S3b(160-bit alignment shift) ->
//   S4(add) -> S4b(LZC) -> S5(shift) -> S5b(round+pack) -> output
//
// S2 and S2b give Vivado two flops between the S2 multiplicand source and
// the DSP cascade output, letting retiming (global_retiming on) place one
// in the DSP48 internal MREG to close the 53x53 multiply.
//
// S3 computes the alignment shift amount and the pre-shift operands; S3b
// performs the 160-bit variable right-shift + sticky collection. Splitting
// alignment into two cycles breaks the s3_c_exp -> shift_amt -> barrel-shift
// critical path at 220 MHz.
//
// Subnormal inputs are treated like normals with zero leading bit and the
// biased exponent bumped to the subnormal emin.  Subnormal outputs fall out of
// the normal normalize + round path via the tininess-after-rounding rule used
// across the rest of the FPU.

module kronos_fpu_fma
  import kronos_pkg::*;
(
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            flush_i,
  input  logic            in_valid_i,
  input  fp_op_e          op_i,
  input  logic            fmt_d_i,
  input  logic [2:0]      rm_i,
  input  logic [FLEN-1:0] a_i,
  input  logic [FLEN-1:0] b_i,
  input  logic [FLEN-1:0] c_i,
  input  fpu_tag_t        tag_i,
  output logic            out_valid_o,
  output logic [FLEN-1:0] result_o,
  output logic [4:0]      fflags_o,
  output fpu_tag_t        tag_o
);

  // ---------------------------------------------------------------------------
  // Datapath widths
  //   - Unified 53-bit significand (hidden bit + 52-bit fraction)
  //   - Product significand: 106 bits (full 53x53)
  //   - Aligned addend lane: PROD_W + PAD_W (= 160b), addend sits just under
  //     the product and spills into the low pad for sticky bits.
  // ---------------------------------------------------------------------------
  localparam int unsigned SIG_W  = FP_D_MANT_W + 1;     // 53 (incl. hidden)
  localparam int unsigned PROD_W = 2 * SIG_W;           // 106
  localparam int unsigned PAD_W  = 54;                  // headroom for shift-out
  localparam int unsigned SUM_W  = PROD_W + PAD_W;      // 160

  // ---------------------------------------------------------------------------
  // Helpers: classification
  // ---------------------------------------------------------------------------
  function automatic logic is_snan_s(logic [FP_S_TOTAL_W-1:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(logic [FP_S_TOTAL_W-1:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22] == 1'b1);
  endfunction
  function automatic logic is_inf_s(logic [FP_S_TOTAL_W-1:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22:0] == 23'd0);
  endfunction
  function automatic logic is_zero_s(logic [FP_S_TOTAL_W-1:0] x);
    return (x[30:0] == 31'd0);
  endfunction

  function automatic logic is_snan_d(logic [FP_D_TOTAL_W-1:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction
  function automatic logic is_qnan_d(logic [FP_D_TOTAL_W-1:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51] == 1'b1);
  endfunction
  function automatic logic is_inf_d(logic [FP_D_TOTAL_W-1:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51:0] == 52'd0);
  endfunction
  function automatic logic is_zero_d(logic [FP_D_TOTAL_W-1:0] x);
    return (x[62:0] == 63'd0);
  endfunction

  // ---------------------------------------------------------------------------
  // Stage 1 combinational: decompose, detect specials
  // ---------------------------------------------------------------------------
  logic [FP_S_TOTAL_W-1:0] a_s, b_s, c_s;
  logic [FP_D_TOTAL_W-1:0] a_d, b_d, c_d;

  // Common signal shape per operand
  logic               s1_a_sign, s1_b_sign, s1_c_sign;
  logic signed [12:0] s1_a_exp, s1_b_exp, s1_c_exp; // biased exponent
  logic [SIG_W-1:0]   s1_a_sig, s1_b_sig, s1_c_sig;
  logic               s1_a_zero, s1_b_zero, s1_c_zero;
  logic               s1_a_inf, s1_b_inf, s1_c_inf;
  logic               s1_a_nan, s1_b_nan, s1_c_nan;
  logic               s1_a_snan, s1_b_snan, s1_c_snan;

  logic               s1_negate_product, s1_negate_addend;
  logic               s1_prod_sign, s1_addend_sign;
  logic signed [12:0] s1_prod_exp;  // biased exponent of product
  logic               s1_prod_zero;

  // Special result flags
  logic               s1_special;
  logic [FLEN-1:0]    s1_special_result;
  logic [4:0]         s1_special_flags;

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
    s1_prod_exp = s1_a_exp + s1_b_exp - 13'(fmt_d_i ? FP_D_BIAS : FP_S_BIAS);
    s1_prod_zero = s1_a_zero || s1_b_zero;

    // ---------- Special-case resolution ----------
    s1_special        = 1'b0;
    s1_special_result = 64'h0;
    s1_special_flags  = 5'h0;

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
        s1_special_result = {s1_prod_sign, FP_D_EXP_MAX, 52'd0};
      end else begin
        s1_special_result = {FP_NANBOX_UPPER, s1_prod_sign, FP_S_EXP_MAX, 23'd0};
      end
    end else if (s1_c_inf) begin
      // finite * finite + inf -> +/- inf (sign = addend sign)
      s1_special        = 1'b1;
      if (fmt_d_i) begin
        s1_special_result = {s1_addend_sign, FP_D_EXP_MAX, 52'd0};
      end else begin
        s1_special_result = {FP_NANBOX_UPPER, s1_addend_sign, FP_S_EXP_MAX, 23'd0};
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 1 -> Stage 2 register
  // ---------------------------------------------------------------------------
  logic               s2_valid;
  logic               s2_special;
  logic [FLEN-1:0]    s2_special_result;
  logic [4:0]         s2_special_flags;
  logic               s2_fmt_d;
  logic [2:0]         s2_rm;
  logic               s2_prod_sign;
  logic               s2_addend_sign;
  logic signed [12:0] s2_prod_exp;
  logic signed [12:0] s2_c_exp;
  logic [SIG_W-1:0]   s2_a_sig;
  logic [SIG_W-1:0]   s2_b_sig;
  logic [SIG_W-1:0]   s2_c_sig;
  logic               s2_prod_zero;
  logic               s2_c_zero;
  fpu_tag_t           s2_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s2_regs
    if (!rst_ni) begin
      s2_valid          <= 1'b0;
      s2_special        <= 1'b0;
      s2_special_result <= 64'h0;
      s2_special_flags  <= 5'h0;
      s2_fmt_d          <= 1'b0;
      s2_rm             <= 3'h0;
      s2_prod_sign      <= 1'b0;
      s2_addend_sign    <= 1'b0;
      s2_prod_exp       <= 13'h0;
      s2_c_exp          <= 13'h0;
      s2_a_sig          <= {SIG_W{1'b0}};
      s2_b_sig          <= {SIG_W{1'b0}};
      s2_c_sig          <= {SIG_W{1'b0}};
      s2_prod_zero      <= 1'b0;
      s2_c_zero         <= 1'b0;
      s2_tag            <= fpu_tag_t'(0);
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
  // re-latch all S2 signals. This is the pure-pipelining stage that
  // gives Vivado retiming room inside the 53x53 DSP cascade. No new functional
  // content.
  // ---------------------------------------------------------------------------
  logic               s2b_valid;
  logic               s2b_special;
  logic [FLEN-1:0]    s2b_special_result;
  logic [4:0]         s2b_special_flags;
  logic               s2b_fmt_d;
  logic [2:0]         s2b_rm;
  logic               s2b_prod_sign;
  logic               s2b_addend_sign;
  logic signed [12:0] s2b_prod_exp;
  logic signed [12:0] s2b_c_exp;
  logic [SIG_W-1:0]   s2b_a_sig;
  logic [SIG_W-1:0]   s2b_b_sig;
  logic [SIG_W-1:0]   s2b_c_sig;
  logic               s2b_prod_zero;
  logic               s2b_c_zero;
  fpu_tag_t           s2b_tag;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s2b_regs
    if (!rst_ni) begin
      s2b_valid          <= 1'b0;
      s2b_special        <= 1'b0;
      s2b_special_result <= 64'h0;
      s2b_special_flags  <= 5'h0;
      s2b_fmt_d          <= 1'b0;
      s2b_rm             <= 3'h0;
      s2b_prod_sign      <= 1'b0;
      s2b_addend_sign    <= 1'b0;
      s2b_prod_exp       <= 13'h0;
      s2b_c_exp          <= 13'h0;
      s2b_a_sig          <= {SIG_W{1'b0}};
      s2b_b_sig          <= {SIG_W{1'b0}};
      s2b_c_sig          <= {SIG_W{1'b0}};
      s2b_prod_zero      <= 1'b0;
      s2b_c_zero         <= 1'b0;
      s2b_tag            <= fpu_tag_t'(0);
    end else begin
      s2b_valid          <= flush_i ? 1'b0 : s2_valid;
      s2b_special        <= s2_special;
      s2b_special_result <= s2_special_result;
      s2b_special_flags  <= s2_special_flags;
      s2b_fmt_d          <= s2_fmt_d;
      s2b_rm             <= s2_rm;
      s2b_prod_sign      <= s2_prod_sign;
      s2b_addend_sign    <= s2_addend_sign;
      s2b_prod_exp       <= s2_prod_exp;
      s2b_c_exp          <= s2_c_exp;
      s2b_a_sig          <= s2_a_sig;
      s2b_b_sig          <= s2_b_sig;
      s2b_c_sig          <= s2_c_sig;
      s2b_prod_zero      <= s2_prod_zero;
      s2b_c_zero         <= s2_c_zero;
      s2b_tag            <= s2_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // multiply significands (reads from s2b to break DSP cascade path)
  // ---------------------------------------------------------------------------
  logic [PROD_W-1:0]  s2_product_comb;

  // Stage 2b -> Stage 3 register
  logic               s3_valid;
  logic               s3_special;
  logic [FLEN-1:0]    s3_special_result;
  logic [4:0]         s3_special_flags;
  logic               s3_fmt_d;
  logic [2:0]         s3_rm;
  logic               s3_prod_sign;
  logic               s3_addend_sign;
  logic signed [12:0] s3_prod_exp;
  logic signed [12:0] s3_c_exp;
  logic [PROD_W-1:0]  s3_product;
  logic [SIG_W-1:0]   s3_c_sig;
  logic               s3_prod_zero;
  logic               s3_c_zero;
  fpu_tag_t           s3_tag;

  // Pre-shift outputs (written in S3 comb, read by proc_s3b_regs).
  logic signed [12:0] s3a_base_exp_comb;
  logic               s3a_eff_sub_comb;
  logic [7:0]         s3a_sh_comb;          // clamped shift amount (0..159)
  logic [SUM_W-1:0]   s3a_shift_src_comb;   // operand to be shifted right
  logic [SUM_W-1:0]   s3a_passthrough_comb; // operand to pass through unshifted
  // s3a_shift_is_c_comb=1 -> s3_c_lane = shifted, s3_prod_lane = passthrough.
  // s3a_shift_is_c_comb=0 -> s3_c_lane = passthrough, s3_prod_lane = shifted.
  logic               s3a_shift_is_c_comb;
  logic               s3a_zero_shift_comb;  // 1 when one side is zero
  logic               s3a_prod_zero_comb;   // 1 -> output s3_prod_lane forced to 0
  logic               s3a_c_zero_comb;      // 1 -> output s3_c_lane forced to 0

  // S3 align comb scratch (promoted to module scope per RTL guidelines).
  logic signed [13:0] s3a_exp_diff;
  logic signed [13:0] s3a_shift_amt;
  logic [SUM_W-1:0]   s3a_c_extended;
  logic [SUM_W-1:0]   s3a_p_extended;
  int unsigned        s3a_sh;

  // ---------------------------------------------------------------------------
  // Stage 3 -> Stage 3b register
  // ---------------------------------------------------------------------------
  logic               s3b_valid;
  logic               s3b_special;
  logic [FLEN-1:0]    s3b_special_result;
  logic [4:0]         s3b_special_flags;
  logic               s3b_fmt_d;
  logic [2:0]         s3b_rm;
  logic               s3b_prod_sign;
  logic               s3b_addend_sign;
  logic signed [12:0] s3b_base_exp;
  logic               s3b_eff_sub;
  logic [7:0]         s3b_sh;
  logic [SUM_W-1:0]   s3b_shift_src;
  logic [SUM_W-1:0]   s3b_passthrough;
  logic               s3b_shift_is_c;
  logic               s3b_zero_shift;
  logic               s3b_prod_zero_flag;
  logic               s3b_c_zero_flag;
  fpu_tag_t           s3b_tag;

  // S3b combinational outputs
  logic [SUM_W-1:0]   s3b_prod_lane_comb;
  logic [SUM_W-1:0]   s3b_c_lane_comb;
  logic signed [12:0] s3b_base_exp_out_comb;
  logic               s3b_eff_sub_out_comb;

  // S3b shift scratch
  logic [SUM_W-1:0]   s3b_shifted;
  logic               s3b_sticky;
  int unsigned        s3b_sh_int;

  // ---------------------------------------------------------------------------
  // Stage 3b -> Stage 4 register
  // ---------------------------------------------------------------------------
  logic               s4_valid;
  logic               s4_special;
  logic [FLEN-1:0]    s4_special_result;
  logic [4:0]         s4_special_flags;
  logic               s4_fmt_d;
  logic [2:0]         s4_rm;
  logic               s4_prod_sign;
  logic               s4_addend_sign;
  logic signed [12:0] s4_base_exp;
  logic [SUM_W-1:0]   s4_prod_lane;
  logic [SUM_W-1:0]   s4_c_lane;
  logic               s4_eff_sub;
  fpu_tag_t           s4_tag;

  // ---------------------------------------------------------------------------
  // Stage 4 -> 4b register (after 160-bit add, before LZC)
  // ---------------------------------------------------------------------------
  logic               s4b_valid;
  logic               s4b_special;
  logic [FLEN-1:0]    s4b_special_result;
  logic [4:0]         s4b_special_flags;
  logic               s4b_fmt_d;
  logic [2:0]         s4b_rm;
  logic               s4b_res_sign;
  logic               s4b_zero;
  logic signed [12:0] s4b_base_exp;
  logic [SUM_W-1:0]   s4b_mag;
  logic               s4b_eff_sub;
  logic               s4b_prod_sign;
  fpu_tag_t           s4b_tag;

  // Stage 4 combinational outputs
  logic [SUM_W:0]     s4_sum_comb;
  logic               s4_res_sign_comb;
  logic               s4_zero_comb;
  logic [SUM_W-1:0]   s4_mag_comb;
  logic [SUM_W-1:0]   s4_diff;

  // Stage 4b LZC outputs
  logic [8:0]         s4b_msb_pos_comb;
  logic signed [12:0] s4b_norm_exp_comb;
  // S4b LZC scratch
  int                 s4b_lzc_m;
  logic signed [12:0] s4b_ref_pos_s;

  // ---------------------------------------------------------------------------
  // Stage 4b -> Stage 5 register
  // ---------------------------------------------------------------------------
  logic               s5_valid;
  logic               s5_special;
  logic [FLEN-1:0]    s5_special_result;
  logic [4:0]         s5_special_flags;
  logic               s5_fmt_d;
  logic [2:0]         s5_rm;
  logic               s5_res_sign;
  logic               s5_zero;
  logic signed [12:0] s5_norm_exp;
  logic [SUM_W-1:0]   s5_norm_mag;
  logic               s5_eff_sub;
  logic               s5_prod_sign;
  logic [8:0]         s5_msb_pos;
  fpu_tag_t           s5_tag;

  // Stage 5 combinational outputs (barrel shift + GRS)
  logic [SIG_W-1:0]   s5_raw_sig_comb;
  logic               s5_guard_comb;
  logic               s5_round_b_comb;
  logic               s5_sticky_comb;
  logic signed [12:0] s5_exp_comb;
  logic signed [12:0] s5_exp_pre_tiny_comb;
  logic               s5_tiny_comb;
  logic [31:0]        s5_normal_shift_comb;

  // S5 scratch
  int unsigned        s5_frac_w;
  int signed          s5_bias;
  logic signed [12:0] s5_emin;
  logic [SUM_W-1:0]   s5_mag;
  logic signed [12:0] s5_exp;
  logic signed [12:0] s5_exp_pre_tiny;
  logic               s5_tiny;
  int unsigned        s5_shift_right_amt;
  int unsigned        s5_normal_shift;
  logic [SUM_W-1:0]   s5_pre_mag;

  // ---------------------------------------------------------------------------
  // Stage 5 -> 5b register (after barrel shift, before round)
  // ---------------------------------------------------------------------------
  logic               s5b_valid;
  logic               s5b_special;
  logic [FLEN-1:0]    s5b_special_result;
  logic [4:0]         s5b_special_flags;
  logic               s5b_fmt_d;
  logic [2:0]         s5b_rm;
  logic               s5b_res_sign;
  logic               s5b_zero;
  logic               s5b_eff_sub;
  logic               s5b_prod_sign;
  logic signed [12:0] s5b_exp;
  logic signed [12:0] s5b_exp_pre_tiny;
  logic [SIG_W-1:0]   s5b_raw_sig;
  logic               s5b_guard;
  logic               s5b_round_b;
  logic               s5b_sticky;
  logic               s5b_tiny;
  logic [SUM_W-1:0]   s5b_mag;
  logic [31:0]        s5b_normal_shift;
  fpu_tag_t           s5b_tag;

  // Stage 5b combinational outputs (round, pack)
  logic [FLEN-1:0]    s5b_result_comb;
  logic [4:0]         s5b_flags_comb;

  // S5b scratch
  int unsigned                s5b_frac_w;
  int signed                  s5b_bias;
  logic signed [12:0]         s5b_emin;
  logic signed [12:0]         s5b_emax;
  logic [SIG_W:0]             s5b_rounded_sig;
  logic                       s5b_inexact;
  logic                       s5b_overflow_ovf;
  logic                       s5b_round_up;
  logic signed [12:0]         s5b_final_exp;
  logic [SIG_W-1:0]           s5b_final_sig;
  logic [FP_D_EXP_W-1:0]      s5b_exp_field_d;
  logic [FP_S_EXP_W-1:0]      s5b_exp_field_s;
  // Tininess-after-rounding scratch ("_n" here = "narrow" per file convention).
  logic [SIG_W-1:0]           s5b_raw_sig_n;
  logic                       s5b_guard_n, s5b_round_n, s5b_sticky_n;
  logic                       s5b_round_up_n;
  logic                       s5b_carry_n;
  logic [SUM_W-1:0]           s5b_pre_mag_n;
  int unsigned                s5b_normal_shift_local;
  int unsigned                s5b_lzc_i;

  // ---------------------------------------------------------------------------
  // Stage 1 multiply (combinational, output of S2b operand registers)
  // ---------------------------------------------------------------------------
  always_comb begin
    s2_product_comb = s2b_a_sig * s2b_b_sig;
  end

  // ---------------------------------------------------------------------------
  // Stage 2b -> Stage 3 register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s3_regs
    if (!rst_ni) begin
      s3_valid          <= 1'b0;
      s3_special        <= 1'b0;
      s3_special_result <= 64'h0;
      s3_special_flags  <= 5'h0;
      s3_fmt_d          <= 1'b0;
      s3_rm             <= 3'h0;
      s3_prod_sign      <= 1'b0;
      s3_addend_sign    <= 1'b0;
      s3_prod_exp       <= 13'h0;
      s3_c_exp          <= 13'h0;
      s3_product        <= {PROD_W{1'b0}};
      s3_c_sig          <= {SIG_W{1'b0}};
      s3_prod_zero      <= 1'b0;
      s3_c_zero         <= 1'b0;
      s3_tag            <= fpu_tag_t'(0);
    end else begin
      s3_valid          <= flush_i ? 1'b0 : s2b_valid;
      s3_special        <= s2b_special;
      s3_special_result <= s2b_special_result;
      s3_special_flags  <= s2b_special_flags;
      s3_fmt_d          <= s2b_fmt_d;
      s3_rm             <= s2b_rm;
      s3_prod_sign      <= s2b_prod_sign;
      s3_addend_sign    <= s2b_addend_sign;
      s3_prod_exp       <= s2b_prod_exp;
      s3_c_exp          <= s2b_c_exp;
      s3_product        <= s2_product_comb;
      s3_c_sig          <= s2b_c_sig;
      s3_prod_zero      <= s2b_prod_zero;
      s3_c_zero         <= s2b_c_zero;
      s3_tag            <= s2b_tag;
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
  always_comb begin : proc_s3_align_amt
    // Defaults.
    s3a_exp_diff          = 14'h0;
    s3a_shift_amt         = 14'h0;
    s3a_sh                = 0;
    s3a_base_exp_comb     = 13'h0;
    s3a_eff_sub_comb      = 1'b0;
    s3a_sh_comb           = 8'h0;
    s3a_shift_src_comb    = {SUM_W{1'b0}};
    s3a_passthrough_comb  = {SUM_W{1'b0}};
    s3a_shift_is_c_comb   = 1'b0;
    s3a_zero_shift_comb   = 1'b0;
    s3a_prod_zero_comb    = 1'b0;
    s3a_c_zero_comb       = 1'b0;

    s3a_eff_sub_comb = s3_prod_sign ^ s3_addend_sign;

    // Place product so its top bit sits at SUM_W-2 (matches original comment).
    s3a_p_extended = {1'b0, s3_product, {(PAD_W-1){1'b0}}};

    // Place addend's hidden bit at SUM_W-3, left-justified with s3_c_sig.
    s3a_c_extended = {SUM_W{1'b0}};
    s3a_c_extended[(SUM_W-3) -: SIG_W] = s3_c_sig;

    s3a_exp_diff = s3_prod_exp - s3_c_exp;

    if (s3_prod_zero) begin
      // Product is zero: result is just the addend. No shift; pass c through.
      s3a_prod_zero_comb    = 1'b1;
      s3a_zero_shift_comb   = 1'b1;
      s3a_shift_src_comb    = {SUM_W{1'b0}};
      s3a_passthrough_comb  = s3a_c_extended;
      s3a_shift_is_c_comb   = 1'b0;  // passthrough goes to c_lane; prod_lane forced 0
      s3a_base_exp_comb     = s3_c_exp;
    end else if (s3_c_zero) begin
      s3a_c_zero_comb       = 1'b1;
      s3a_zero_shift_comb   = 1'b1;
      s3a_shift_src_comb    = {SUM_W{1'b0}};
      s3a_passthrough_comb  = s3a_p_extended;
      s3a_shift_is_c_comb   = 1'b1;  // passthrough goes to prod_lane
      s3a_base_exp_comb     = s3_prod_exp;
    end else if (s3a_exp_diff >= 0) begin
      // product >= addend: keep product unshifted, shift c right by exp_diff.
      s3a_shift_amt = s3a_exp_diff;
      if (s3a_shift_amt > 14'(SUM_W - 1)) s3a_sh = SUM_W - 1;
      else                                s3a_sh = {22'd0, s3a_shift_amt[9:0]};
      s3a_sh_comb           = 8'(s3a_sh);
      s3a_shift_src_comb    = s3a_c_extended;
      s3a_passthrough_comb  = s3a_p_extended;
      s3a_shift_is_c_comb   = 1'b1;
      s3a_base_exp_comb     = s3_prod_exp;
    end else begin
      // addend > product: keep c unshifted, shift product right by -exp_diff.
      s3a_shift_amt = -s3a_exp_diff;
      if (s3a_shift_amt > 14'(SUM_W - 1)) s3a_sh = SUM_W - 1;
      else                                s3a_sh = {22'd0, s3a_shift_amt[9:0]};
      s3a_sh_comb           = 8'(s3a_sh);
      s3a_shift_src_comb    = s3a_p_extended;
      s3a_passthrough_comb  = s3a_c_extended;
      s3a_shift_is_c_comb   = 1'b0;
      s3a_base_exp_comb     = s3_c_exp;
    end
  end

  // -------------------------------------------------------------------------
  // S3 -> S3b register: latches pre-shift inputs so the 160-bit right-shift
  // runs in its own clock cycle. Breaks the s3_c_exp -> barrel-shift cone.
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s3b_regs
    if (!rst_ni) begin
      s3b_valid          <= 1'b0;
      s3b_special        <= 1'b0;
      s3b_special_result <= 64'h0;
      s3b_special_flags  <= 5'h0;
      s3b_fmt_d          <= 1'b0;
      s3b_rm             <= 3'h0;
      s3b_prod_sign      <= 1'b0;
      s3b_addend_sign    <= 1'b0;
      s3b_base_exp       <= 13'h0;
      s3b_eff_sub        <= 1'b0;
      s3b_sh             <= 8'h0;
      s3b_shift_src      <= {SUM_W{1'b0}};
      s3b_passthrough    <= {SUM_W{1'b0}};
      s3b_shift_is_c     <= 1'b0;
      s3b_zero_shift     <= 1'b0;
      s3b_prod_zero_flag <= 1'b0;
      s3b_c_zero_flag    <= 1'b0;
      s3b_tag            <= fpu_tag_t'(0);
    end else begin
      s3b_valid          <= flush_i ? 1'b0 : s3_valid;
      s3b_special        <= s3_special;
      s3b_special_result <= s3_special_result;
      s3b_special_flags  <= s3_special_flags;
      s3b_fmt_d          <= s3_fmt_d;
      s3b_rm             <= s3_rm;
      s3b_prod_sign      <= s3_prod_sign;
      s3b_addend_sign    <= s3_addend_sign;
      s3b_base_exp       <= s3a_base_exp_comb;
      s3b_eff_sub        <= s3a_eff_sub_comb;
      s3b_sh             <= s3a_sh_comb;
      s3b_shift_src      <= s3a_shift_src_comb;
      s3b_passthrough    <= s3a_passthrough_comb;
      s3b_shift_is_c     <= s3a_shift_is_c_comb;
      s3b_zero_shift     <= s3a_zero_shift_comb;
      s3b_prod_zero_flag <= s3a_prod_zero_comb;
      s3b_c_zero_flag    <= s3a_c_zero_comb;
      s3b_tag            <= s3_tag;
    end
  end

  // -------------------------------------------------------------------------
  // S3b combinational: perform the 160-bit right-shift + sticky collection.
  // Outputs s3b_prod_lane_comb / s3b_c_lane_comb consumed by the S4 register.
  // -------------------------------------------------------------------------
  always_comb begin : proc_s3b_shift
    s3b_shifted = {SUM_W{1'b0}};
    s3b_sticky  = 1'b0;
    s3b_sh_int  = {24'd0, s3b_sh};

    s3b_eff_sub_out_comb  = s3b_eff_sub;
    s3b_base_exp_out_comb = s3b_base_exp;
    s3b_prod_lane_comb    = {SUM_W{1'b0}};
    s3b_c_lane_comb       = {SUM_W{1'b0}};

    if (s3b_zero_shift) begin
      // One side was zero: no shift; route passthrough, force the other side to 0.
      if (s3b_prod_zero_flag) begin
        s3b_prod_lane_comb = {SUM_W{1'b0}};
        s3b_c_lane_comb    = s3b_passthrough;
      end else begin
        // Treated as c_zero
        s3b_prod_lane_comb = s3b_passthrough;
        s3b_c_lane_comb    = {SUM_W{1'b0}};
      end
    end else begin
      // Perform the shift and collect sticky.
      s3b_shifted = s3b_shift_src >> s3b_sh_int;
      if (s3b_sh_int > 0) begin
        for (int i = 0; i < SUM_W; i = i + 1) begin
          if (i < s3b_sh_int) s3b_sticky = s3b_sticky | s3b_shift_src[i];
        end
      end

      if (s3b_shift_is_c) begin
        // Shifted operand is c; product is passthrough.
        s3b_prod_lane_comb = s3b_passthrough;
        s3b_c_lane_comb    = s3b_shifted | {{(SUM_W-1){1'b0}}, s3b_sticky};
      end else begin
        // Shifted operand is product; c is passthrough.
        s3b_prod_lane_comb = s3b_shifted | {{(SUM_W-1){1'b0}}, s3b_sticky};
        s3b_c_lane_comb    = s3b_passthrough;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3b -> Stage 4 register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s4_regs
    if (!rst_ni) begin
      s4_valid          <= 1'b0;
      s4_special        <= 1'b0;
      s4_special_result <= 64'h0;
      s4_special_flags  <= 5'h0;
      s4_fmt_d          <= 1'b0;
      s4_rm             <= 3'h0;
      s4_prod_sign      <= 1'b0;
      s4_addend_sign    <= 1'b0;
      s4_base_exp       <= 13'h0;
      s4_prod_lane      <= {SUM_W{1'b0}};
      s4_c_lane         <= {SUM_W{1'b0}};
      s4_eff_sub        <= 1'b0;
      s4_tag            <= fpu_tag_t'(0);
    end else begin
      s4_valid          <= flush_i ? 1'b0 : s3b_valid;
      s4_special        <= s3b_special;
      s4_special_result <= s3b_special_result;
      s4_special_flags  <= s3b_special_flags;
      s4_fmt_d          <= s3b_fmt_d;
      s4_rm             <= s3b_rm;
      s4_prod_sign      <= s3b_prod_sign;
      s4_addend_sign    <= s3b_addend_sign;
      s4_base_exp       <= s3b_base_exp_out_comb;
      s4_prod_lane      <= s3b_prod_lane_comb;
      s4_c_lane         <= s3b_c_lane_comb;
      s4_eff_sub        <= s3b_eff_sub_out_comb;
      s4_tag            <= s3b_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 4: add/subtract only (LZC moves to s4b stage)
  // ---------------------------------------------------------------------------
  always_comb begin
    s4_diff          = {SUM_W{1'b0}};
    s4_sum_comb      = {(SUM_W+1){1'b0}};
    s4_res_sign_comb = 1'b0;
    s4_zero_comb     = 1'b0;
    s4_mag_comb      = {SUM_W{1'b0}};

    if (!s4_eff_sub) begin
      s4_sum_comb = {1'b0, s4_prod_lane} + {1'b0, s4_c_lane};
      s4_mag_comb = s4_sum_comb[SUM_W-1:0];
      s4_res_sign_comb = s4_prod_sign;
    end else begin
      if (s4_prod_lane >= s4_c_lane) begin
        s4_diff = s4_prod_lane - s4_c_lane;
        s4_res_sign_comb = s4_prod_sign;
      end else begin
        s4_diff = s4_c_lane - s4_prod_lane;
        s4_res_sign_comb = s4_addend_sign;
      end
      s4_sum_comb = {1'b0, s4_diff};
      s4_mag_comb = s4_diff;
    end

    s4_zero_comb = (s4_mag_comb == {SUM_W{1'b0}});
  end

  // Stage 4 -> Stage 4b register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s4b_valid          <= 1'b0;
      s4b_special        <= 1'b0;
      s4b_special_result <= 64'h0;
      s4b_special_flags  <= 5'h0;
      s4b_fmt_d          <= 1'b0;
      s4b_rm             <= 3'h0;
      s4b_res_sign       <= 1'b0;
      s4b_zero           <= 1'b0;
      s4b_base_exp       <= 13'h0;
      s4b_mag            <= {SUM_W{1'b0}};
      s4b_eff_sub        <= 1'b0;
      s4b_prod_sign      <= 1'b0;
      s4b_tag            <= fpu_tag_t'(0);
    end else begin
      s4b_valid          <= flush_i ? 1'b0 : s4_valid;
      s4b_special        <= s4_special;
      s4b_special_result <= s4_special_result;
      s4b_special_flags  <= s4_special_flags;
      s4b_fmt_d          <= s4_fmt_d;
      s4b_rm             <= s4_rm;
      s4b_res_sign       <= s4_res_sign_comb;
      s4b_zero           <= s4_zero_comb;
      s4b_base_exp       <= s4_base_exp;
      s4b_mag            <= s4_mag_comb;
      s4b_eff_sub        <= s4_eff_sub;
      s4b_prod_sign      <= s4_prod_sign;
      s4b_tag            <= s4_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // leading-zero count on registered 160-bit magnitude
  // ---------------------------------------------------------------------------
  always_comb begin
    s4b_lzc_m         = -1;
    s4b_ref_pos_s     = 13'(SUM_W - 3);  // 157
    s4b_msb_pos_comb  = 9'd0;
    s4b_norm_exp_comb = 13'h0;

    for (int i = 0; i < SUM_W; i = i + 1) begin
      if (s4b_mag[i] && (s4b_lzc_m < $signed(i))) s4b_lzc_m = i;
    end

    if (s4b_lzc_m < 0) begin
      s4b_msb_pos_comb  = 9'd0;
      s4b_norm_exp_comb = 13'h0;
    end else begin
      s4b_msb_pos_comb  = s4b_lzc_m[8:0];
      s4b_norm_exp_comb = s4b_base_exp + 13'(s4b_lzc_m) - s4b_ref_pos_s;
    end
  end

  // Stage 4b -> Stage 5 register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s5_valid          <= 1'b0;
      s5_special        <= 1'b0;
      s5_special_result <= 64'h0;
      s5_special_flags  <= 5'h0;
      s5_fmt_d          <= 1'b0;
      s5_rm             <= 3'h0;
      s5_res_sign       <= 1'b0;
      s5_zero           <= 1'b0;
      s5_norm_exp       <= 13'h0;
      s5_norm_mag       <= {SUM_W{1'b0}};
      s5_eff_sub        <= 1'b0;
      s5_prod_sign      <= 1'b0;
      s5_msb_pos        <= 9'h0;
      s5_tag            <= fpu_tag_t'(0);
    end else begin
      s5_valid          <= flush_i ? 1'b0 : s4b_valid;
      s5_special        <= s4b_special;
      s5_special_result <= s4b_special_result;
      s5_special_flags  <= s4b_special_flags;
      s5_fmt_d          <= s4b_fmt_d;
      s5_rm             <= s4b_rm;
      s5_res_sign       <= s4b_res_sign;
      s5_zero           <= s4b_zero;
      s5_norm_exp       <= s4b_norm_exp_comb;
      s5_norm_mag       <= s4b_mag;
      s5_eff_sub        <= s4b_eff_sub;
      s5_prod_sign      <= s4b_prod_sign;
      s5_msb_pos        <= s4b_msb_pos_comb;
      s5_tag            <= s4b_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 5: barrel shift + GRS extraction (round moves to s5b stage)
  // ---------------------------------------------------------------------------
  always_comb begin
    s5_frac_w          = 0;
    s5_bias            = 0;
    s5_emin            = 13'h0;
    s5_mag             = {SUM_W{1'b0}};
    s5_exp             = 13'h0;
    s5_exp_pre_tiny    = 13'h0;
    s5_tiny            = 1'b0;
    s5_shift_right_amt = 0;
    s5_normal_shift    = 0;
    s5_pre_mag         = {SUM_W{1'b0}};

    s5_raw_sig_comb       = {SIG_W{1'b0}};
    s5_guard_comb         = 1'b0;
    s5_round_b_comb       = 1'b0;
    s5_sticky_comb        = 1'b0;
    s5_exp_comb           = 13'h0;
    s5_exp_pre_tiny_comb  = 13'h0;
    s5_tiny_comb          = 1'b0;
    s5_normal_shift_comb  = 32'h0;

    if (!s5_special && !s5_zero) begin
      if (s5_fmt_d) begin
        s5_frac_w = FP_D_MANT_W;
        s5_bias   = FP_D_BIAS;
      end else begin
        s5_frac_w = FP_S_MANT_W;
        s5_bias   = FP_S_BIAS;
      end
      s5_emin = 13'sd1;

      s5_mag = s5_norm_mag;
      s5_exp = s5_norm_exp;

      if ({1'b0, s5_msb_pos} >= 10'(s5_frac_w))
        s5_normal_shift = {23'd0, s5_msb_pos} - s5_frac_w;
      else
        s5_normal_shift = 0;
      s5_shift_right_amt = s5_normal_shift;

      s5_exp_pre_tiny = s5_exp;
      s5_tiny = 1'b0;
      if (s5_exp < s5_emin) begin
        s5_shift_right_amt = s5_shift_right_amt
                             + (32'($signed(s5_emin)) - 32'($signed(s5_exp)));
        s5_exp  = 13'sd0;
        s5_tiny = 1'b1;
      end

      if (s5_shift_right_amt >= SUM_W) begin
        s5_raw_sig_comb  = {SIG_W{1'b0}};
        s5_guard_comb    = 1'b0;
        s5_round_b_comb  = 1'b0;
        s5_sticky_comb   = (s5_mag != {SUM_W{1'b0}});
      end else begin
        s5_pre_mag = s5_mag >> s5_shift_right_amt;
        s5_raw_sig_comb = s5_pre_mag[SIG_W-1:0];

        // verilator coverage_off
        if (s5_shift_right_amt == 0) begin
          s5_guard_comb   = 1'b0;
          s5_round_b_comb = 1'b0;
          s5_sticky_comb  = 1'b0;
        // verilator coverage_on
        end else if (s5_shift_right_amt == 1) begin
          s5_guard_comb   = s5_mag[0];
          s5_round_b_comb = 1'b0;
          s5_sticky_comb  = 1'b0;
        end else if (s5_shift_right_amt == 2) begin
          s5_guard_comb   = s5_mag[1];
          s5_round_b_comb = s5_mag[0];
          s5_sticky_comb  = 1'b0;
        end else begin
          s5_guard_comb   = s5_mag[s5_shift_right_amt - 1];
          s5_round_b_comb = s5_mag[s5_shift_right_amt - 2];
          s5_sticky_comb  = 1'b0;
          for (int i = 0; i < SUM_W; i = i + 1) begin
            if (i + 2 < s5_shift_right_amt) begin
              s5_sticky_comb = s5_sticky_comb | s5_mag[i];
            end
          end
        end
      end

      s5_exp_comb          = s5_exp;
      s5_exp_pre_tiny_comb = s5_exp_pre_tiny;
      s5_tiny_comb         = s5_tiny;
      s5_normal_shift_comb = s5_normal_shift;
    end
  end

  // Stage 5 -> Stage 5b register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s5b_valid          <= 1'b0;
      s5b_special        <= 1'b0;
      s5b_special_result <= 64'h0;
      s5b_special_flags  <= 5'h0;
      s5b_fmt_d          <= 1'b0;
      s5b_rm             <= 3'h0;
      s5b_res_sign       <= 1'b0;
      s5b_zero           <= 1'b0;
      s5b_eff_sub        <= 1'b0;
      s5b_prod_sign      <= 1'b0;
      s5b_exp            <= 13'h0;
      s5b_exp_pre_tiny   <= 13'h0;
      s5b_raw_sig        <= {SIG_W{1'b0}};
      s5b_guard          <= 1'b0;
      s5b_round_b        <= 1'b0;
      s5b_sticky         <= 1'b0;
      s5b_tiny           <= 1'b0;
      s5b_mag            <= {SUM_W{1'b0}};
      s5b_normal_shift   <= 32'h0;
      s5b_tag            <= fpu_tag_t'(0);
    end else begin
      s5b_valid          <= flush_i ? 1'b0 : s5_valid;
      s5b_special        <= s5_special;
      s5b_special_result <= s5_special_result;
      s5b_special_flags  <= s5_special_flags;
      s5b_fmt_d          <= s5_fmt_d;
      s5b_rm             <= s5_rm;
      s5b_res_sign       <= s5_res_sign;
      s5b_zero           <= s5_zero;
      s5b_eff_sub        <= s5_eff_sub;
      s5b_prod_sign      <= s5_prod_sign;
      s5b_exp            <= s5_exp_comb;
      s5b_exp_pre_tiny   <= s5_exp_pre_tiny_comb;
      s5b_raw_sig        <= s5_raw_sig_comb;
      s5b_guard          <= s5_guard_comb;
      s5b_round_b        <= s5_round_b_comb;
      s5b_sticky         <= s5_sticky_comb;
      s5b_tiny           <= s5_tiny_comb;
      s5b_mag            <= s5_norm_mag;
      s5b_normal_shift   <= s5_normal_shift_comb;
      s5b_tag            <= s5_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // round, pack, overflow/underflow (old stage 5 second half)
  // ---------------------------------------------------------------------------
  always_comb begin
    s5b_frac_w             = 0;
    s5b_bias               = 0;
    s5b_emin               = 13'h0;
    s5b_emax               = 13'h0;
    s5b_rounded_sig        = {(SIG_W+1){1'b0}};
    s5b_inexact            = 1'b0;
    s5b_overflow_ovf       = 1'b0;
    s5b_round_up           = 1'b0;
    s5b_final_exp          = 13'h0;
    s5b_final_sig          = {SIG_W{1'b0}};
    s5b_exp_field_d        = {FP_D_EXP_W{1'b0}};
    s5b_exp_field_s        = {FP_S_EXP_W{1'b0}};
    s5b_raw_sig_n          = {SIG_W{1'b0}};
    s5b_guard_n            = 1'b0;
    s5b_round_n            = 1'b0;
    s5b_sticky_n           = 1'b0;
    s5b_round_up_n         = 1'b0;
    s5b_carry_n            = 1'b0;
    s5b_pre_mag_n          = {SUM_W{1'b0}};
    s5b_normal_shift_local = 0;
    s5b_lzc_i              = 0;

    s5b_result_comb = 64'h0;
    s5b_flags_comb  = s5b_special_flags;

    if (s5b_special) begin
      s5b_result_comb = s5b_special_result;
    end else if (s5b_zero) begin
      if (s5b_eff_sub) begin
        if (s5b_rm == FP_RM_RDN) begin
          s5b_result_comb = s5b_fmt_d ? {1'b1, 63'd0}
                                      : {FP_NANBOX_UPPER, 1'b1, 31'd0};
        end else begin
          s5b_result_comb = s5b_fmt_d ? 64'd0
                                      : {FP_NANBOX_UPPER, 32'd0};
        end
      end else begin
        if (s5b_prod_sign) begin
          s5b_result_comb = s5b_fmt_d ? {1'b1, 63'd0}
                                      : {FP_NANBOX_UPPER, 1'b1, 31'd0};
        end else begin
          s5b_result_comb = s5b_fmt_d ? 64'd0
                                      : {FP_NANBOX_UPPER, 32'd0};
        end
      end
    end else begin
      if (s5b_fmt_d) begin
        s5b_frac_w = FP_D_MANT_W;
        s5b_bias   = FP_D_BIAS;
        s5b_emax   = 13'sd2046;
      end else begin
        s5b_frac_w = FP_S_MANT_W;
        s5b_bias   = FP_S_BIAS;
        s5b_emax   = 13'sd254;
      end
      s5b_emin = 13'sd1;

      s5b_inexact = s5b_guard | s5b_round_b | s5b_sticky;
      s5b_round_up = 1'b0;
      unique case (s5b_rm)
        FP_RM_RNE: s5b_round_up = s5b_guard & (s5b_round_b | s5b_sticky | s5b_raw_sig[0]);
        FP_RM_RTZ: s5b_round_up = 1'b0;
        FP_RM_RDN: s5b_round_up = s5b_inexact & s5b_res_sign;
        FP_RM_RUP: s5b_round_up = s5b_inexact & ~s5b_res_sign;
        FP_RM_RMM: s5b_round_up = s5b_guard;
        default:   s5b_round_up = 1'b0;
      endcase

      s5b_rounded_sig = {1'b0, s5b_raw_sig}
                        + (s5b_round_up ? {{(SIG_W){1'b0}}, 1'b1} : {(SIG_W+1){1'b0}});
      s5b_final_exp   = s5b_exp;
      s5b_final_sig   = s5b_rounded_sig[SIG_W-1:0];

      if (s5b_rounded_sig[s5b_frac_w + 1]) begin
        s5b_final_sig = s5b_rounded_sig[SIG_W:1];
        s5b_final_exp = s5b_exp + 13'sd1;
      end

      if (s5b_tiny && s5b_final_sig[s5b_frac_w]) begin
        s5b_final_exp = s5b_emin;
      end

      s5b_overflow_ovf = 1'b0;
      if (s5b_final_exp >= (s5b_emax + 13'sd1)) begin
        s5b_overflow_ovf = 1'b1;
      end

      // Tininess-after-rounding using carried s5b_mag and s5b_normal_shift
      if (s5b_tiny && s5b_inexact) begin
        s5b_normal_shift_local = s5b_normal_shift;
        // verilator coverage_off
        if (s5b_normal_shift_local >= SUM_W) begin
          s5b_raw_sig_n = {SIG_W{1'b0}};
          s5b_guard_n   = 1'b0;
          s5b_round_n   = 1'b0;
          s5b_sticky_n  = (s5b_mag != {SUM_W{1'b0}});
        end else begin
          // verilator coverage_on
          s5b_pre_mag_n = s5b_mag >> s5b_normal_shift_local;
          s5b_raw_sig_n = s5b_pre_mag_n[SIG_W-1:0];
          // verilator coverage_off
          if (s5b_normal_shift_local == 0) begin
            s5b_guard_n  = 1'b0;
            s5b_round_n  = 1'b0;
            s5b_sticky_n = 1'b0;
          // verilator coverage_on
          end else if (s5b_normal_shift_local == 1) begin
            s5b_guard_n  = s5b_mag[0];
            s5b_round_n  = 1'b0;
            s5b_sticky_n = 1'b0;
          end else if (s5b_normal_shift_local == 2) begin
            s5b_guard_n  = s5b_mag[1];
            s5b_round_n  = s5b_mag[0];
            s5b_sticky_n = 1'b0;
          end else begin
            s5b_lzc_i = 0;
            s5b_guard_n  = s5b_mag[s5b_normal_shift_local - 1];
            s5b_round_n  = s5b_mag[s5b_normal_shift_local - 2];
            s5b_sticky_n = 1'b0;
            for (s5b_lzc_i = 0; s5b_lzc_i < SUM_W; s5b_lzc_i = s5b_lzc_i + 1) begin
              if (s5b_lzc_i + 2 < s5b_normal_shift_local) begin
                s5b_sticky_n = s5b_sticky_n | s5b_mag[s5b_lzc_i];
              end
            end
          end
        end

        unique case (s5b_rm)
          FP_RM_RNE: s5b_round_up_n = s5b_guard_n
                                      & (s5b_round_n | s5b_sticky_n | s5b_raw_sig_n[0]);
          FP_RM_RTZ: s5b_round_up_n = 1'b0;
          FP_RM_RDN: s5b_round_up_n = (s5b_guard_n | s5b_round_n | s5b_sticky_n)
                                      &  s5b_res_sign;
          FP_RM_RUP: s5b_round_up_n = (s5b_guard_n | s5b_round_n | s5b_sticky_n)
                                      & ~s5b_res_sign;
          FP_RM_RMM: s5b_round_up_n = s5b_guard_n;
          default:   s5b_round_up_n = 1'b0;
        endcase

        if (s5b_fmt_d) begin
          s5b_carry_n = s5b_round_up_n & (&s5b_raw_sig_n[FP_D_MANT_W:0]);
        end else begin
          s5b_carry_n = s5b_round_up_n & (&s5b_raw_sig_n[FP_S_MANT_W:0]);
        end

        if (!(s5b_carry_n && (s5b_exp_pre_tiny + 13'sd1 == s5b_emin))) begin
          s5b_flags_comb[FP_FFLAG_UF] = 1'b1;
        end
      end

      if (s5b_inexact) s5b_flags_comb[FP_FFLAG_NX] = 1'b1;

      if (s5b_overflow_ovf) begin
        s5b_flags_comb[FP_FFLAG_OF] = 1'b1;
        s5b_flags_comb[FP_FFLAG_NX] = 1'b1;
        unique case (s5b_rm)
          FP_RM_RTZ: begin
            if (s5b_fmt_d) s5b_result_comb = {s5b_res_sign, 11'd2046, {52{1'b1}}};
            else           s5b_result_comb = {FP_NANBOX_UPPER,
                                              s5b_res_sign, 8'd254, {23{1'b1}}};
          end
          FP_RM_RDN: begin
            if (s5b_res_sign) begin
              if (s5b_fmt_d) s5b_result_comb = {1'b1, FP_D_EXP_MAX, 52'd0};
              else           s5b_result_comb = {FP_NANBOX_UPPER, 1'b1, FP_S_EXP_MAX, 23'd0};
            end else begin
              if (s5b_fmt_d) s5b_result_comb = {1'b0, 11'd2046, {52{1'b1}}};
              else           s5b_result_comb = {FP_NANBOX_UPPER,
                                               1'b0, 8'd254, {23{1'b1}}};
            end
          end
          FP_RM_RUP: begin
            if (s5b_res_sign) begin
              if (s5b_fmt_d) s5b_result_comb = {1'b1, 11'd2046, {52{1'b1}}};
              else           s5b_result_comb = {FP_NANBOX_UPPER,
                                               1'b1, 8'd254, {23{1'b1}}};
            end else begin
              if (s5b_fmt_d) s5b_result_comb = {1'b0, FP_D_EXP_MAX, 52'd0};
              else           s5b_result_comb = {FP_NANBOX_UPPER, 1'b0, FP_S_EXP_MAX, 23'd0};
            end
          end
          default: begin
            if (s5b_fmt_d) s5b_result_comb = {s5b_res_sign, FP_D_EXP_MAX, 52'd0};
            else           s5b_result_comb = {FP_NANBOX_UPPER,
                                             s5b_res_sign, FP_S_EXP_MAX, 23'd0};
          end
        endcase
      end else begin
        if (s5b_fmt_d) begin
          s5b_exp_field_d = s5b_final_exp[FP_D_EXP_W-1:0];
          s5b_result_comb = {s5b_res_sign, s5b_exp_field_d, s5b_final_sig[FP_D_MANT_W-1:0]};
        end else begin
          s5b_exp_field_s = s5b_final_exp[FP_S_EXP_W-1:0];
          s5b_result_comb = {FP_NANBOX_UPPER, s5b_res_sign, s5b_exp_field_s,
                             s5b_final_sig[FP_S_MANT_W-1:0]};
        end
      end
    end
  end

  // Stage 5b register -> outputs
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= 64'h0;
      fflags_o    <= 5'h0;
      tag_o       <= fpu_tag_t'(0);
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s5b_valid;
      result_o    <= s5b_result_comb;
      fflags_o    <= s5b_flags_comb;
      tag_o       <= s5b_tag;
    end
  end

endmodule
