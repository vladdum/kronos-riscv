// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_fpu_fadd — 6-cycle pipelined FADD/FSUB unit (S and D precision).
//
// Pipeline layout:
//   S1   decompose/unbox operands, classify specials, apply FSUB sign flip
//   S2   exponent difference, align smaller operand, capture G/R/S
//   S3   add / subtract significands, normalize (leading-zero count)
//   S3b  subnormal barrel shift, G/R/S extraction (timing split from S4)
//   S4   rounding mode decision, round-up increment, overflow detection
//   S5   pack IEEE 754, generate flags, NaN-box single result
//
// Internal representation uses a 56-bit significand (MSB is hidden 1 + mantissa
// + 2 alignment bits) — enough to hold both S (24-bit) and D (53-bit) values
// left-justified. Exponent is tracked as an unbiased 13-bit signed integer.

module kronos_fpu_fadd
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
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // ---------------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------------
  // Significand carries: 1 hidden bit + 52 mantissa = 53. We extend on the right
  // by 3 bits for G/R/S collection during alignment/rounding.
  localparam int unsigned SIG_W = 56;
  // Signed exponent width, wide enough for +/-2048 plus shift margin.
  localparam int unsigned EXP_W = 13;

  // ---------------------------------------------------------------------------
  // Helper functions
  // ---------------------------------------------------------------------------
  // NaN classifiers ignore the sign bit (and the payload for QNaN);
  // helper sinks on `x` keep lint quiet without changing the predicate.
  function automatic logic is_snan_s(input logic [31:0] x);
    logic _unused; _unused = ^x;
    return (x[30:23] == 8'hFF) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(input logic [31:0] x);
    logic _unused; _unused = ^x;
    return (x[30:23] == 8'hFF) && (x[22] == 1'b1);
  endfunction
  function automatic logic is_snan_d(input logic [63:0] x);
    logic _unused; _unused = ^x;
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction
  function automatic logic is_qnan_d(input logic [63:0] x);
    logic _unused; _unused = ^x;
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b1);
  endfunction

  // Leading-zero count over SIG_W bits (returns 0..SIG_W).
  function automatic int unsigned clz_sig(input logic [SIG_W-1:0] x);
    int unsigned i;
    clz_sig = SIG_W;
    for (i = 0; i < SIG_W; i++) begin
      if (x[SIG_W-1-i] && (clz_sig == SIG_W)) begin
        clz_sig = i;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Payload typedefs for pipeline registers
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                valid;
    logic                fmt_d;
    logic [2:0]          rm;
    fpu_tag_t            tag;
    // Operand A decomposition
    logic                a_sign;
    logic signed [EXP_W-1:0] a_exp;   // unbiased exponent
    logic [SIG_W-1:0]    a_sig;      // left-justified significand (1.xxx... 000)
    logic                a_zero, a_inf, a_nan, a_snan;
    // Operand B decomposition (sign already flipped for FSUB)
    logic                b_sign;
    logic signed [EXP_W-1:0] b_exp;
    logic [SIG_W-1:0]    b_sig;
    logic                b_zero, b_inf, b_nan, b_snan;
    // Special-case result bits (early resolution)
    logic                is_special;
    logic [63:0]         special_res;
    logic [4:0]          special_flg;
  } s1_t;

  typedef struct packed {
    logic                valid;
    logic                fmt_d;
    logic [2:0]          rm;
    fpu_tag_t            tag;
    logic                is_special;
    logic [63:0]         special_res;
    logic [4:0]          special_flg;
    // After alignment: two same-exponent operands (larger exp wins), each with
    // G/R/S attached in the low 3 bits of sig for the "small" operand.
    logic                res_sign;    // tentative sign (from larger operand)
    logic                eff_sub;
    logic                op_sub;      // effective subtract after sign analysis
    logic signed [EXP_W-1:0] res_exp;
    logic [SIG_W-1:0]    big_sig;
    logic [SIG_W-1:0]    small_sig;
    logic                small_sticky_extra;
    // Signs of the two source operands (needed for zero-result sign in RDN).
    logic                a_sign;
    logic                b_sign;
    logic                both_zero;
  } s2_t;

  // S2b: after the 56-bit add/subtract, before LZC + normalize. Inserted to
  // split the long add/sub -> LZC -> barrel-shift -> sticky cone that was
  // the critical path at 200 MHz on KV260.
  typedef struct packed {
    logic                valid;
    logic                fmt_d;
    logic [2:0]          rm;
    fpu_tag_t            tag;
    logic                is_special;
    logic [63:0]         special_res;
    logic [4:0]          special_flg;
    logic                res_sign;
    logic                op_sub;
    logic signed [EXP_W-1:0] res_exp;   // exponent possibly bumped by add carry
    // Post-add/sub significand. For ADD: already shifted right by the
    // carry-out if one occurred (exp bumped). For SUB: the full |big-small|.
    logic [SIG_W-1:0]    sum_sig;
    logic                small_sticky; // final sticky contribution forwarded to S3
  } s2b_t;

  typedef struct packed {
    logic                valid;
    logic                fmt_d;
    logic [2:0]          rm;
    fpu_tag_t            tag;
    logic                is_special;
    logic [63:0]         special_res;
    logic [4:0]          special_flg;
    logic                res_sign;
    logic signed [EXP_W-1:0] res_exp;  // exponent after add/normalize
    logic [SIG_W-1:0]    res_sig;      // normalized significand, hidden bit
                                       // at MSB (bit SIG_W-1)
    logic                guard;
    logic                round_b;
    logic                sticky;
    logic                result_zero;
  } s3_t;

  // S3b: after subnormal barrel shift and G/R/S extraction, before rounding.
  typedef struct packed {
    logic                     valid;
    logic                     fmt_d;
    logic [2:0]               rm;
    fpu_tag_t                 tag;
    logic                     is_special;
    logic [63:0]              special_res;
    logic [4:0]               special_flg;
    logic                     res_sign;
    logic                     result_zero;
    logic signed [EXP_W-1:0]  cur_exp;   // exponent after subnormal shift
    logic [SIG_W-1:0]         cur_sig;   // significand after subnormal shift
    logic                     g_bit;     // guard bit
    logic                     r_bit;     // round bit
    logic                     st_bit;    // sticky bit
    logic                     lsb;       // LSB of kept significand (for RNE tie)
  } s3b_t;

  typedef struct packed {
    logic                     valid;
    logic                     fmt_d;
    logic [2:0]               rm;
    fpu_tag_t                 tag;
    logic                     is_special;
    logic [63:0]              special_res;
    logic [4:0]               special_flg;
    logic                     res_sign;
    logic                     result_zero;
    logic signed [EXP_W-1:0]  cur_exp;
    logic [SIG_W-1:0]         rounded_sig;
    logic                     inexact;
    logic                     overflow;
    logic                     is_subnormal_out;
  } s4_t;

  // ---------------------------------------------------------------------------
  // Pipeline registers
  // ---------------------------------------------------------------------------
  s1_t  s1_q;
  s2_t  s2_q;
  s2b_t s2b_q;
  s3_t  s3_q;
  s3b_t s3b_q;
  s4_t  s4_q;

  // Lint sinks for fields of the pipeline pack-structs that the next stage
  // reads only via narrower projections (s5 mantissa-width selector,
  // bias offsets), and bias values that fed the now-removed pre-rounding
  // path.  Driven by an OR-reduction at the bottom of the module.
  logic _unused;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 1: decompose / classify)
  // ---------------------------------------------------------------------------
  s1_t s1_d;

  // Double operand fields
  logic        a_d_sign, b_d_sign;
  logic [kronos_pkg::FP_D_EXP_W-1:0]  a_d_expf, b_d_expf;
  logic [kronos_pkg::FP_D_MANT_W-1:0] a_d_mant, b_d_mant;
  logic        a_d_zero, b_d_zero, a_d_inf, b_d_inf;
  logic        a_d_subn, b_d_subn;
  logic        a_d_snan, b_d_snan, a_d_qnan, b_d_qnan, a_d_nan, b_d_nan;

  // Unboxed single operands
  logic [kronos_pkg::FP_S_TOTAL_W-1:0] a_s_bits, b_s_bits;
  logic        a_s_sign, b_s_sign;
  logic [kronos_pkg::FP_S_EXP_W-1:0]  a_s_expf, b_s_expf;
  logic [kronos_pkg::FP_S_MANT_W-1:0] a_s_mant, b_s_mant;
  logic        a_s_zero, b_s_zero, a_s_inf, b_s_inf;
  logic        a_s_subn, b_s_subn;
  logic        a_s_snan, b_s_snan, a_s_qnan, b_s_qnan, a_s_nan, b_s_nan;

  // Selected per-format fields
  logic                    a_sign_sel, b_sign_sel;
  logic signed [EXP_W-1:0] a_exp_sel, b_exp_sel;
  logic [SIG_W-1:0]        a_sig_sel, b_sig_sel;
  logic                    a_zero_sel, b_zero_sel;
  logic                    a_inf_sel, b_inf_sel;
  logic                    a_nan_sel, b_nan_sel;
  logic                    a_snan_sel, b_snan_sel;

  logic b_sign_pre;  // sign of b after FSUB flip

  // S1 specials sub-block locals (promoted from block scope)
  logic s1_zero_sign;
  logic s1_eff_sub_early;
  logic s1_both_inf_opposite;
  logic s1_both_zero_early;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 2: align)
  // ---------------------------------------------------------------------------
  s2_t s2_d;
  logic signed [EXP_W-1:0] s2_exp_diff;
  logic                    s2_a_is_big;
  logic [SIG_W-1:0]        s2_big_raw;
  logic [SIG_W-1:0]        s2_small_raw;
  int unsigned             s2_shift_amt;
  logic [SIG_W-1:0]        s2_shifted;
  logic                    s2_sticky_extra;
  int unsigned             s2_max_shift;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 2b: add/subtract)
  // ---------------------------------------------------------------------------
  s2b_t s2b_d;
  logic [SIG_W:0] s2b_sum_ext;
  logic           s2b_small_sticky;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 3: LZC + normalize)
  // ---------------------------------------------------------------------------
  s3_t s3_d;
  int unsigned             s3_lzc;
  logic [SIG_W-1:0]        s3_norm_sig;
  logic signed [EXP_W-1:0] s3_norm_exp;
  logic                    s3_result_zero;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 3b: subnormal shift + G/R/S)
  // ---------------------------------------------------------------------------
  s3b_t s3b_d;
  int unsigned             s3b_mant_w;
  logic signed [EXP_W-1:0] s3b_emin;
  logic signed [EXP_W-1:0] s3b_cur_exp;
  logic [SIG_W-1:0]        s3b_cur_sig;
  logic                    s3b_g, s3b_r, s3b_st;
  logic [2:0]              s3b_grs_vec;
  int unsigned             s3b_sh;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 4: rounding)
  // ---------------------------------------------------------------------------
  s4_t s4_d;
  int unsigned             s4_mant_w;
  logic signed [EXP_W-1:0] s4_emax;
  logic signed [EXP_W-1:0] s4_cur_exp;
  logic [SIG_W-1:0]        s4_cur_sig;
  logic                    s4_round_up;
  logic [SIG_W-1:0]        s4_rounded_sig;
  logic                    s4_carry_up;
  logic [SIG_W:0]          s4_incremented;
  logic [SIG_W-1:0]        s4_mask_one;

  // ---------------------------------------------------------------------------
  // Combinational signals (Stage 5: pack)
  // ---------------------------------------------------------------------------
  logic [kronos_pkg::FP_D_TOTAL_W-1:0] s5_result;
  logic [4:0]              s5_flags;
  int unsigned             s5_mant_w;
  logic signed [EXP_W-1:0] s5_bias;
  logic [kronos_pkg::FP_D_MANT_W-1:0]  s5_out_mant_d;
  logic [kronos_pkg::FP_S_MANT_W-1:0]  s5_out_mant_s;
  logic [kronos_pkg::FP_D_EXP_W-1:0]   s5_out_expf_d;
  logic [kronos_pkg::FP_S_EXP_W-1:0]   s5_out_expf_s;
  logic                    s5_to_inf;

  // ===========================================================================
  // Stage 1: decompose / classify
  // ===========================================================================
  always_comb begin
    // --- Defaults ---
    s1_zero_sign         = 1'b0;
    s1_eff_sub_early     = 1'b0;
    s1_both_inf_opposite = 1'b0;
    s1_both_zero_early   = 1'b0;

    // --- Double decomposition ---
    a_d_sign = a_i[kronos_pkg::FP_D_TOTAL_W-1];
    b_d_sign = b_i[kronos_pkg::FP_D_TOTAL_W-1];
    a_d_expf = a_i[kronos_pkg::FP_D_TOTAL_W-2 -: kronos_pkg::FP_D_EXP_W];
    b_d_expf = b_i[kronos_pkg::FP_D_TOTAL_W-2 -: kronos_pkg::FP_D_EXP_W];
    a_d_mant = a_i[kronos_pkg::FP_D_MANT_W-1:0];
    b_d_mant = b_i[kronos_pkg::FP_D_MANT_W-1:0];
    a_d_zero = (a_d_expf == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (a_d_mant == {kronos_pkg::FP_D_MANT_W{1'b0}});
    b_d_zero = (b_d_expf == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (b_d_mant == {kronos_pkg::FP_D_MANT_W{1'b0}});
    a_d_inf  = (a_d_expf == kronos_pkg::FP_D_EXP_MAX) && (a_d_mant == {kronos_pkg::FP_D_MANT_W{1'b0}});
    b_d_inf  = (b_d_expf == kronos_pkg::FP_D_EXP_MAX) && (b_d_mant == {kronos_pkg::FP_D_MANT_W{1'b0}});
    a_d_subn = (a_d_expf == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (a_d_mant != {kronos_pkg::FP_D_MANT_W{1'b0}});
    b_d_subn = (b_d_expf == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (b_d_mant != {kronos_pkg::FP_D_MANT_W{1'b0}});
    a_d_snan = is_snan_d(a_i);
    b_d_snan = is_snan_d(b_i);
    a_d_qnan = is_qnan_d(a_i);
    b_d_qnan = is_qnan_d(b_i);
    a_d_nan  = a_d_snan || a_d_qnan;
    b_d_nan  = b_d_snan || b_d_qnan;

    // --- Single decomposition (with NaN-unbox) ---
    a_s_bits = (a_i[kronos_pkg::FP_D_TOTAL_W-1:FP_S_TOTAL_W] == kronos_pkg::FP_NANBOX_UPPER)
                 ? a_i[kronos_pkg::FP_S_TOTAL_W-1:0] : kronos_pkg::FP_CANON_QNAN_S;
    b_s_bits = (b_i[kronos_pkg::FP_D_TOTAL_W-1:FP_S_TOTAL_W] == kronos_pkg::FP_NANBOX_UPPER)
                 ? b_i[kronos_pkg::FP_S_TOTAL_W-1:0] : kronos_pkg::FP_CANON_QNAN_S;
    a_s_sign = a_s_bits[kronos_pkg::FP_S_TOTAL_W-1];
    b_s_sign = b_s_bits[kronos_pkg::FP_S_TOTAL_W-1];
    a_s_expf = a_s_bits[kronos_pkg::FP_S_TOTAL_W-2 -: kronos_pkg::FP_S_EXP_W];
    b_s_expf = b_s_bits[kronos_pkg::FP_S_TOTAL_W-2 -: kronos_pkg::FP_S_EXP_W];
    a_s_mant = a_s_bits[kronos_pkg::FP_S_MANT_W-1:0];
    b_s_mant = b_s_bits[kronos_pkg::FP_S_MANT_W-1:0];
    a_s_zero = (a_s_expf == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (a_s_mant == {kronos_pkg::FP_S_MANT_W{1'b0}});
    b_s_zero = (b_s_expf == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (b_s_mant == {kronos_pkg::FP_S_MANT_W{1'b0}});
    a_s_inf  = (a_s_expf == kronos_pkg::FP_S_EXP_MAX) && (a_s_mant == {kronos_pkg::FP_S_MANT_W{1'b0}});
    b_s_inf  = (b_s_expf == kronos_pkg::FP_S_EXP_MAX) && (b_s_mant == {kronos_pkg::FP_S_MANT_W{1'b0}});
    a_s_subn = (a_s_expf == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (a_s_mant != {kronos_pkg::FP_S_MANT_W{1'b0}});
    b_s_subn = (b_s_expf == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (b_s_mant != {kronos_pkg::FP_S_MANT_W{1'b0}});
    a_s_snan = is_snan_s(a_s_bits);
    b_s_snan = is_snan_s(b_s_bits);
    a_s_qnan = is_qnan_s(a_s_bits);
    b_s_qnan = is_qnan_s(b_s_bits);
    a_s_nan  = a_s_snan || a_s_qnan;
    b_s_nan  = b_s_snan || b_s_qnan;

    // --- Select format-specific values (left-justify significand in SIG_W) ---
    if (fmt_d_i) begin
      a_sign_sel  = a_d_sign;
      b_sign_sel  = b_d_sign;
      a_zero_sel  = a_d_zero;
      b_zero_sel  = b_d_zero;
      a_inf_sel   = a_d_inf;
      b_inf_sel   = b_d_inf;
      a_nan_sel   = a_d_nan;
      b_nan_sel   = b_d_nan;
      a_snan_sel  = a_d_snan;
      b_snan_sel  = b_d_snan;
      // Unbiased exponent: subnormal uses exp=1-bias, hidden bit = 0.
      a_exp_sel = a_d_subn ? -13'sd1022
                           : (13'(a_d_expf) - 13'(kronos_pkg::FP_D_BIAS));
      b_exp_sel = b_d_subn ? -13'sd1022
                           : (13'(b_d_expf) - 13'(kronos_pkg::FP_D_BIAS));
      // Hidden bit: 0 for subnormal/zero, 1 otherwise.
      a_sig_sel = {(a_d_subn || a_d_zero) ? 1'b0 : 1'b1, a_d_mant, 3'd0};
      b_sig_sel = {(b_d_subn || b_d_zero) ? 1'b0 : 1'b1, b_d_mant, 3'd0};
    end else begin
      a_sign_sel  = a_s_sign;
      b_sign_sel  = b_s_sign;
      a_zero_sel  = a_s_zero;
      b_zero_sel  = b_s_zero;
      a_inf_sel   = a_s_inf;
      b_inf_sel   = b_s_inf;
      a_nan_sel   = a_s_nan;
      b_nan_sel   = b_s_nan;
      a_snan_sel  = a_s_snan;
      b_snan_sel  = b_s_snan;
      a_exp_sel = a_s_subn ? -13'sd126
                           : (13'(a_s_expf) - 13'(kronos_pkg::FP_S_BIAS));
      b_exp_sel = b_s_subn ? -13'sd126
                           : (13'(b_s_expf) - 13'(kronos_pkg::FP_S_BIAS));
      // Left-justify a 24-bit significand into SIG_W (56-bit) field.
      // For S, 53-bit equivalent: put the 24 bits at the top, zeros below.
      a_sig_sel = {(a_s_subn || a_s_zero) ? 1'b0 : 1'b1, a_s_mant,
                   {(SIG_W-1-kronos_pkg::FP_S_MANT_W){1'b0}}};
      b_sig_sel = {(b_s_subn || b_s_zero) ? 1'b0 : 1'b1, b_s_mant,
                   {(SIG_W-1-kronos_pkg::FP_S_MANT_W){1'b0}}};
    end

    // FSUB: logical sign flip on b at this stage.
    b_sign_pre = b_sign_sel ^ (op_i == FP_FSUB);

    // --- Compose S1 payload ---
    s1_d            = s1_t'({($bits(s1_t)){1'b0}});
    s1_d.valid      = in_valid_i;
    s1_d.fmt_d      = fmt_d_i;
    s1_d.rm         = rm_i;
    s1_d.tag        = tag_i;
    s1_d.a_sign     = a_sign_sel;
    s1_d.a_exp      = a_exp_sel;
    s1_d.a_sig      = a_sig_sel;
    s1_d.a_zero     = a_zero_sel;
    s1_d.a_inf      = a_inf_sel;
    s1_d.a_nan      = a_nan_sel;
    s1_d.a_snan     = a_snan_sel;
    s1_d.b_sign     = b_sign_pre;
    s1_d.b_exp      = b_exp_sel;
    s1_d.b_sig      = b_sig_sel;
    s1_d.b_zero     = b_zero_sel;
    s1_d.b_inf      = b_inf_sel;
    s1_d.b_nan      = b_nan_sel;
    s1_d.b_snan     = b_snan_sel;

    // --- Early special-case handling ---
    // NaN input -> canonical qNaN; sNaN sets NV.
    // Inf + -Inf -> canonical qNaN + NV.
    // Inf + finite -> that infinity.
    // Zero + zero: depends on sign/RM.
    s1_eff_sub_early     = a_sign_sel ^ b_sign_pre;  // magnitudes subtract
    s1_both_inf_opposite = a_inf_sel && b_inf_sel && s1_eff_sub_early;
    s1_both_zero_early   = a_zero_sel && b_zero_sel;

    s1_d.is_special  = 1'b0;
    s1_d.special_res = {kronos_pkg::FP_D_TOTAL_W{1'b0}};
    s1_d.special_flg = 5'd0;

    if (a_nan_sel || b_nan_sel) begin
      s1_d.is_special  = 1'b1;
      s1_d.special_res = fmt_d_i ? kronos_pkg::FP_CANON_QNAN_D
                                 : {kronos_pkg::FP_NANBOX_UPPER, kronos_pkg::FP_CANON_QNAN_S};
      if (a_snan_sel || b_snan_sel) begin
        s1_d.special_flg[kronos_pkg::FP_FFLAG_NV] = 1'b1;
      end
    end else if (s1_both_inf_opposite) begin
      s1_d.is_special  = 1'b1;
      s1_d.special_res = fmt_d_i ? kronos_pkg::FP_CANON_QNAN_D
                                 : {kronos_pkg::FP_NANBOX_UPPER, kronos_pkg::FP_CANON_QNAN_S};
      s1_d.special_flg[kronos_pkg::FP_FFLAG_NV] = 1'b1;
    end else if (a_inf_sel || b_inf_sel) begin
      s1_d.is_special = 1'b1;
      // Propagate the infinity that's present; same sign as it (b sign already
      // flipped for FSUB).
      if (a_inf_sel) begin
        s1_d.special_res = fmt_d_i
            ? {a_sign_sel, kronos_pkg::FP_D_EXP_MAX, {kronos_pkg::FP_D_MANT_W{1'b0}}}
            : {kronos_pkg::FP_NANBOX_UPPER, a_sign_sel, kronos_pkg::FP_S_EXP_MAX, {kronos_pkg::FP_S_MANT_W{1'b0}}};
      end else begin
        s1_d.special_res = fmt_d_i
            ? {b_sign_pre, kronos_pkg::FP_D_EXP_MAX, {kronos_pkg::FP_D_MANT_W{1'b0}}}
            : {kronos_pkg::FP_NANBOX_UPPER, b_sign_pre, kronos_pkg::FP_S_EXP_MAX, {kronos_pkg::FP_S_MANT_W{1'b0}}};
      end
    end else if (s1_both_zero_early) begin
      // 0 + 0: sign(result) = sign(a) & sign(b) for eff_sub=0; else for RDN,
      // it's -0; else +0.
      s1_d.is_special = 1'b1;
      if (!s1_eff_sub_early) begin
        // Additive zero: both signs must match for a signed zero; otherwise
        // the sign is +0 except in RDN.
        s1_zero_sign = a_sign_sel & b_sign_pre;
      end else begin
        s1_zero_sign = (rm_i == FP_RM_RDN);
      end
      s1_d.special_res = fmt_d_i
          ? {s1_zero_sign, {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}}
          : {kronos_pkg::FP_NANBOX_UPPER, s1_zero_sign, {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}}};
    end
  end

  // ===========================================================================
  // Stage 2: exponent difference, align, collect G/R/S
  // ===========================================================================
  always_comb begin
    // Defaults
    s2_d            = s2_t'({($bits(s2_t)){1'b0}});
    s2_exp_diff     = {EXP_W{1'b0}};
    s2_a_is_big     = 1'b0;
    s2_big_raw      = {SIG_W{1'b0}};
    s2_small_raw    = {SIG_W{1'b0}};
    s2_shift_amt    = 32'd0;
    s2_shifted      = {SIG_W{1'b0}};
    s2_sticky_extra = 1'b0;
    s2_max_shift    = SIG_W + 2;

    s2_d.valid       = s1_q.valid;
    s2_d.fmt_d       = s1_q.fmt_d;
    s2_d.rm          = s1_q.rm;
    s2_d.tag         = s1_q.tag;
    s2_d.is_special  = s1_q.is_special;
    s2_d.special_res = s1_q.special_res;
    s2_d.special_flg = s1_q.special_flg;
    s2_d.a_sign      = s1_q.a_sign;
    s2_d.b_sign      = s1_q.b_sign;
    s2_d.both_zero   = s1_q.a_zero && s1_q.b_zero;
    s2_d.eff_sub     = s1_q.a_sign ^ s1_q.b_sign;
    s2_d.op_sub      = s2_d.eff_sub;

    s2_exp_diff = s1_q.a_exp - s1_q.b_exp;

    // Decide which operand has the larger exponent. Tie broken by
    // significand magnitude.
    if (s1_q.a_exp > s1_q.b_exp) s2_a_is_big = 1'b1;
    else if (s1_q.a_exp < s1_q.b_exp) s2_a_is_big = 1'b0;
    else s2_a_is_big = (s1_q.a_sig >= s1_q.b_sig);

    if (s2_a_is_big) begin
      s2_big_raw    = s1_q.a_sig;
      s2_small_raw  = s1_q.b_sig;
      s2_shift_amt  = (s2_exp_diff >= 0) ? int'(s2_exp_diff) : -(int'(s2_exp_diff));
      s2_d.res_exp  = s1_q.a_exp;
      s2_d.res_sign = s1_q.a_sign;
    end else begin
      s2_big_raw    = s1_q.b_sig;
      s2_small_raw  = s1_q.a_sig;
      s2_shift_amt  = (s2_exp_diff >= 0) ? int'(s2_exp_diff) : -(int'(s2_exp_diff));
      s2_d.res_exp  = s1_q.b_exp;
      s2_d.res_sign = s1_q.b_sign;
    end

    // Clamp shift: beyond SIG_W+2, the small operand effectively contributes
    // only sticky.
    if (s2_shift_amt > s2_max_shift) begin
      s2_shifted      = {SIG_W{1'b0}};
      s2_sticky_extra = (s2_small_raw != {SIG_W{1'b0}});
    end else begin
      // Shift right, OR-collect the bits that fall off into s2_sticky_extra.
      s2_shifted      = s2_small_raw >> s2_shift_amt;
      s2_sticky_extra = 1'b0;
      for (int i = 0; i < SIG_W; i++) begin
        if (i < s2_shift_amt) begin
          if (s2_small_raw[i]) s2_sticky_extra = 1'b1;
        end
      end
    end

    s2_d.big_sig            = s2_big_raw;
    s2_d.small_sig          = s2_shifted;
    s2_d.small_sticky_extra = s2_sticky_extra;
  end

  // ===========================================================================
  // add / subtract only.  LZC and normalize moved to Stage 3 so the
  // 56-bit carry chain no longer shares a clock period with the CLZ + barrel
  // shift + sticky extraction.  Resolves the S2->S3 critical path.
  // ===========================================================================
  always_comb begin
    // Defaults
    s2b_d            = s2b_t'({($bits(s2b_t)){1'b0}});
    s2b_sum_ext      = {(SIG_W+1){1'b0}};
    s2b_small_sticky = 1'b0;

    s2b_d.valid       = s2_q.valid;
    s2b_d.fmt_d       = s2_q.fmt_d;
    s2b_d.rm          = s2_q.rm;
    s2b_d.tag         = s2_q.tag;
    s2b_d.is_special  = s2_q.is_special;
    s2b_d.special_res = s2_q.special_res;
    s2b_d.special_flg = s2_q.special_flg;
    s2b_d.res_sign    = s2_q.res_sign;
    s2b_d.op_sub      = s2_q.op_sub;
    s2b_d.res_exp     = s2_q.res_exp;

    s2b_small_sticky = s2_q.small_sticky_extra;

    if (!s2_q.op_sub) begin
      // Addition of magnitudes.
      s2b_sum_ext = {1'b0, s2_q.big_sig} + {1'b0, s2_q.small_sig};
      if (s2b_sum_ext[SIG_W]) begin
        // Carry-out: shift right by 1, bump exponent, fold LSB into sticky.
        s2b_d.sum_sig      = s2b_sum_ext[SIG_W:1];
        s2b_d.res_exp      = s2_q.res_exp + 13'sd1;
        s2b_d.small_sticky = s2b_small_sticky | s2b_sum_ext[0];
      end else begin
        s2b_d.sum_sig      = s2b_sum_ext[SIG_W-1:0];
        s2b_d.small_sticky = s2b_small_sticky;
      end
    end else begin
      // Subtraction: big - small - borrow-for-sticky.
      s2b_sum_ext = {1'b0, s2_q.big_sig} - {1'b0, s2_q.small_sig}
                    - {{(SIG_W){1'b0}}, s2b_small_sticky};
      s2b_d.sum_sig      = s2b_sum_ext[SIG_W-1:0];
      s2b_d.small_sticky = s2b_small_sticky;
    end
  end

  // ===========================================================================
  // Stage 3: LZC + normalize + G/R/S extraction (reads from s2b_q)
  // ===========================================================================
  always_comb begin
    // Defaults
    s3_d           = s3_t'({($bits(s3_t)){1'b0}});
    s3_lzc         = 32'd0;
    s3_norm_sig    = {SIG_W{1'b0}};
    s3_norm_exp    = {EXP_W{1'b0}};
    s3_result_zero = 1'b0;

    s3_d.valid       = s2b_q.valid;
    s3_d.fmt_d       = s2b_q.fmt_d;
    s3_d.rm          = s2b_q.rm;
    s3_d.tag         = s2b_q.tag;
    s3_d.is_special  = s2b_q.is_special;
    s3_d.special_res = s2b_q.special_res;
    s3_d.special_flg = s2b_q.special_flg;
    s3_d.res_sign    = s2b_q.res_sign;
    s3_d.res_exp     = s2b_q.res_exp;

    if (!s2b_q.op_sub) begin
      // Addition path: sum_sig already normalized in S2b.  Just extract
      // G/R/S from the low 3 bits and merge with the carried sticky.
      s3_norm_sig  = s2b_q.sum_sig;
      s3_norm_exp  = s2b_q.res_exp;
      s3_d.res_sig = s3_norm_sig;
      s3_d.guard   = s3_norm_sig[2];
      s3_d.round_b = s3_norm_sig[1];
      s3_d.sticky  = s3_norm_sig[0] | s2b_q.small_sticky;
      s3_d.res_sig[2:0] = 3'd0;
      s3_result_zero = (s3_norm_sig == {SIG_W{1'b0}});
    end else begin
      // Subtraction path: LZC on the raw |big-small|, then left-shift to
      // normalize.
      s3_lzc = clz_sig(s2b_q.sum_sig);
      if (s3_lzc == SIG_W) begin
        s3_result_zero = 1'b1;
        s3_norm_sig    = {SIG_W{1'b0}};
        s3_norm_exp    = {EXP_W{1'b0}};
      end else begin
        s3_result_zero = 1'b0;
        s3_norm_sig    = s2b_q.sum_sig << s3_lzc;
        s3_norm_exp    = s2b_q.res_exp - 13'($signed(s3_lzc));
      end
      s3_d.res_sig = s3_norm_sig;
      s3_d.res_exp = s3_norm_exp;
      s3_d.guard   = s3_norm_sig[2];
      s3_d.round_b = s3_norm_sig[1];
      // Close-path sticky: when lzc shifted out the alignment bits, sticky
      // from the pre-subtract borrow is no longer meaningful.  Preserve the
      // original conservative-OR semantics.
      s3_d.sticky  = s3_norm_sig[0] | (s2b_q.small_sticky & (s3_lzc == 0));
      s3_d.res_sig[2:0] = 3'd0;
    end

    s3_d.result_zero = s3_result_zero;
    if (s3_result_zero) begin
      // Cancellation-to-zero sign rule (non-special path): RDN -> -0 else +0.
      s3_d.res_sign = (s2b_q.rm == FP_RM_RDN);
    end
  end

  // ===========================================================================
  // subnormal barrel shift + G/R/S bit collection
  // ===========================================================================
  always_comb begin
    // Defaults
    s3b_d         = s3b_t'({($bits(s3b_t)){1'b0}});
    s3b_mant_w    = 32'd0;
    s3b_emin      = {EXP_W{1'b0}};
    s3b_cur_exp   = {EXP_W{1'b0}};
    s3b_cur_sig   = {SIG_W{1'b0}};
    s3b_g         = 1'b0;
    s3b_r         = 1'b0;
    s3b_st        = 1'b0;
    s3b_grs_vec   = 3'b000;
    s3b_sh        = 32'd0;

    s3b_d.valid       = s3_q.valid;
    s3b_d.fmt_d       = s3_q.fmt_d;
    s3b_d.rm          = s3_q.rm;
    s3b_d.tag         = s3_q.tag;
    s3b_d.is_special  = s3_q.is_special;
    s3b_d.special_res = s3_q.special_res;
    s3b_d.special_flg = s3_q.special_flg;
    s3b_d.res_sign    = s3_q.res_sign;
    s3b_d.result_zero = s3_q.result_zero;

    if (!s3_q.is_special && !s3_q.result_zero) begin
      if (s3_q.fmt_d) begin
        s3b_mant_w = kronos_pkg::FP_D_MANT_W;
        s3b_emin   = -13'sd1022;
      end else begin
        s3b_mant_w = kronos_pkg::FP_S_MANT_W;
        s3b_emin   = -13'sd126;
      end

      s3b_cur_exp = s3_q.res_exp;
      s3b_cur_sig = s3_q.res_sig;
      s3b_g  = s3_q.guard;
      s3b_r  = s3_q.round_b;
      s3b_st = s3_q.sticky;

      if (s3b_cur_exp < s3b_emin) begin
        s3b_grs_vec = {s3b_g, s3b_r, s3b_st};
        s3b_sh = {19'd0, 13'(s3b_emin - s3b_cur_exp)};
        for (int i = 0; i < SIG_W + 3; i++) if (i < s3b_sh) begin
          s3b_grs_vec[0] = s3b_grs_vec[0] | s3b_grs_vec[1];
          s3b_grs_vec[1] = s3b_grs_vec[2];
          s3b_grs_vec[2] = s3b_cur_sig[0];
          s3b_cur_sig    = {1'b0, s3b_cur_sig[SIG_W-1:1]};
        end
        s3b_g  = s3b_grs_vec[2];
        s3b_r  = s3b_grs_vec[1];
        s3b_st = s3b_grs_vec[0];
        s3b_cur_exp = s3b_emin;
      end

      // For single precision, re-extract G/R/S from the left-justified 24-bit
      // significand stored in the upper bits of the SIG_W-wide s3b_cur_sig.
      if (!s3_q.fmt_d) begin
        s3b_g  = s3b_cur_sig[SIG_W - 1 - s3b_mant_w - 1];
        s3b_r  = s3b_cur_sig[SIG_W - 1 - s3b_mant_w - 2];
        for (int i = 0; i < SIG_W - 1 - kronos_pkg::FP_S_MANT_W - 2; i++)
          if (i < SIG_W - 1 - s3b_mant_w - 2) begin
            if (s3b_cur_sig[i]) s3b_st = 1'b1;
          end
      end

      s3b_d.cur_exp = s3b_cur_exp;
      s3b_d.cur_sig = s3b_cur_sig;
      s3b_d.g_bit   = s3b_g;
      s3b_d.r_bit   = s3b_r;
      s3b_d.st_bit  = s3b_st;
      s3b_d.lsb     = s3b_cur_sig[SIG_W - 1 - s3b_mant_w];
    end
  end

  // ===========================================================================
  // Stage 4: rounding decision + increment
  // ===========================================================================
  always_comb begin
    // Defaults
    s4_d           = s4_t'({($bits(s4_t)){1'b0}});
    s4_mant_w      = 32'd0;
    s4_emax        = {EXP_W{1'b0}};
    s4_cur_exp     = {EXP_W{1'b0}};
    s4_cur_sig     = {SIG_W{1'b0}};
    s4_round_up    = 1'b0;
    s4_rounded_sig = {SIG_W{1'b0}};
    s4_carry_up    = 1'b0;
    s4_incremented = {(SIG_W+1){1'b0}};
    s4_mask_one    = {SIG_W{1'b0}};

    s4_d.valid       = s3b_q.valid;
    s4_d.fmt_d       = s3b_q.fmt_d;
    s4_d.rm          = s3b_q.rm;
    s4_d.tag         = s3b_q.tag;
    s4_d.is_special  = s3b_q.is_special;
    s4_d.special_res = s3b_q.special_res;
    s4_d.special_flg = s3b_q.special_flg;
    s4_d.res_sign    = s3b_q.res_sign;
    s4_d.result_zero = s3b_q.result_zero;

    if (!s3b_q.is_special && !s3b_q.result_zero) begin
      if (s3b_q.fmt_d) begin
        s4_mant_w = kronos_pkg::FP_D_MANT_W;
        s4_emax   = 13'(kronos_pkg::FP_D_BIAS);
      end else begin
        s4_mant_w = kronos_pkg::FP_S_MANT_W;
        s4_emax   = 13'(kronos_pkg::FP_S_BIAS);
      end

      s4_cur_exp = s3b_q.cur_exp;
      s4_cur_sig = s3b_q.cur_sig;

      s4_round_up = 1'b0;
      unique case (s3b_q.rm)
        FP_RM_RNE: s4_round_up = s3b_q.g_bit && (s3b_q.r_bit || s3b_q.st_bit || s3b_q.lsb);
        FP_RM_RTZ: s4_round_up = 1'b0;
        FP_RM_RDN: s4_round_up = s3b_q.res_sign && (s3b_q.g_bit | s3b_q.r_bit | s3b_q.st_bit);
        FP_RM_RUP: s4_round_up = (!s3b_q.res_sign) && (s3b_q.g_bit | s3b_q.r_bit | s3b_q.st_bit);
        FP_RM_RMM: s4_round_up = s3b_q.g_bit;
        default:   s4_round_up = 1'b0;
      endcase

      s4_mask_one = {SIG_W{1'b0}};
      s4_mask_one[SIG_W - 1 - s4_mant_w] = 1'b1;
      if (s4_round_up) begin
        s4_incremented = {1'b0, s4_cur_sig} + {1'b0, s4_mask_one};
      end else begin
        s4_incremented = {1'b0, s4_cur_sig};
      end
      s4_carry_up    = s4_incremented[SIG_W];
      s4_rounded_sig = s4_incremented[SIG_W-1:0];

      if (s4_carry_up) begin
        s4_rounded_sig = {1'b1, s4_rounded_sig[SIG_W-1:1]};
        s4_cur_exp     = s4_cur_exp + 13'sd1;
      end

      s4_d.cur_exp          = s4_cur_exp;
      s4_d.rounded_sig      = s4_rounded_sig;
      s4_d.inexact          = s3b_q.g_bit | s3b_q.r_bit | s3b_q.st_bit;
      s4_d.overflow         = (s4_cur_exp > s4_emax);
      s4_d.is_subnormal_out = (s4_rounded_sig[SIG_W-1] == 1'b0);
    end
  end

  // ===========================================================================
  // Stage 5: pack IEEE result
  // ===========================================================================
  always_comb begin
    // Defaults
    s5_result     = {kronos_pkg::FP_D_TOTAL_W{1'b0}};
    s5_flags      = 5'd0;
    s5_mant_w     = 32'd0;
    s5_bias       = {EXP_W{1'b0}};
    s5_out_mant_d = {kronos_pkg::FP_D_MANT_W{1'b0}};
    s5_out_mant_s = {kronos_pkg::FP_S_MANT_W{1'b0}};
    s5_out_expf_d = {kronos_pkg::FP_D_EXP_W{1'b0}};
    s5_out_expf_s = {kronos_pkg::FP_S_EXP_W{1'b0}};
    s5_to_inf     = 1'b0;

    if (s4_q.is_special) begin
      s5_result = s4_q.special_res;
      s5_flags  = s4_q.special_flg;
    end else if (s4_q.result_zero) begin
      if (s4_q.fmt_d) s5_result = {s4_q.res_sign, {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}};
      else            s5_result = {kronos_pkg::FP_NANBOX_UPPER, s4_q.res_sign, {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}}};
    end else begin
      if (s4_q.fmt_d) begin
        s5_mant_w = kronos_pkg::FP_D_MANT_W;
        s5_bias   = 13'(kronos_pkg::FP_D_BIAS);
      end else begin
        s5_mant_w = kronos_pkg::FP_S_MANT_W;
        s5_bias   = 13'(kronos_pkg::FP_S_BIAS);
      end

      if (s4_q.overflow) begin
        s5_flags[kronos_pkg::FP_FFLAG_OF] = 1'b1;
        s5_flags[kronos_pkg::FP_FFLAG_NX] = 1'b1;
        unique case (s4_q.rm)
          FP_RM_RNE: s5_to_inf = 1'b1;
          FP_RM_RTZ: s5_to_inf = 1'b0;
          FP_RM_RDN: s5_to_inf = s4_q.res_sign;
          FP_RM_RUP: s5_to_inf = !s4_q.res_sign;
          FP_RM_RMM: s5_to_inf = 1'b1;
          default:   s5_to_inf = 1'b1;
        endcase
        if (s4_q.fmt_d) begin
          if (s5_to_inf) s5_result = {s4_q.res_sign, kronos_pkg::FP_D_EXP_MAX, {kronos_pkg::FP_D_MANT_W{1'b0}}};
          else           s5_result = {s4_q.res_sign, 11'h7FE, {kronos_pkg::FP_D_MANT_W{1'b1}}};
        end else begin
          if (s5_to_inf) s5_result = {kronos_pkg::FP_NANBOX_UPPER, s4_q.res_sign,
                                      kronos_pkg::FP_S_EXP_MAX, {kronos_pkg::FP_S_MANT_W{1'b0}}};
          else           s5_result = {kronos_pkg::FP_NANBOX_UPPER, s4_q.res_sign,
                                      8'hFE, {kronos_pkg::FP_S_MANT_W{1'b1}}};
        end
      end else begin
        if (s4_q.fmt_d) begin
          s5_out_mant_d = s4_q.rounded_sig[SIG_W-2 -: kronos_pkg::FP_D_MANT_W];
          if (s4_q.is_subnormal_out) s5_out_expf_d = {kronos_pkg::FP_D_EXP_W{1'b0}};
          else                       s5_out_expf_d = 11'(s4_q.cur_exp + s5_bias);
          s5_result = {s4_q.res_sign, s5_out_expf_d, s5_out_mant_d};
        end else begin
          s5_out_mant_s = s4_q.rounded_sig[SIG_W-2 -: kronos_pkg::FP_S_MANT_W];
          if (s4_q.is_subnormal_out) s5_out_expf_s = {kronos_pkg::FP_S_EXP_W{1'b0}};
          else                       s5_out_expf_s = 8'(s4_q.cur_exp + s5_bias);
          s5_result = {kronos_pkg::FP_NANBOX_UPPER, s4_q.res_sign, s5_out_expf_s, s5_out_mant_s};
        end

        if (s4_q.inexact) s5_flags[kronos_pkg::FP_FFLAG_NX] = 1'b1;
        if (s4_q.is_subnormal_out && s4_q.inexact) s5_flags[kronos_pkg::FP_FFLAG_UF] = 1'b1;
      end
    end
  end

  // ===========================================================================
  // Pipeline registers / flush
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_q  <= s1_t'({($bits(s1_t)){1'b0}});
      s2_q  <= s2_t'({($bits(s2_t)){1'b0}});
      s2b_q <= s2b_t'({($bits(s2b_t)){1'b0}});
      s3_q  <= s3_t'({($bits(s3_t)){1'b0}});
      s3b_q <= s3b_t'({($bits(s3b_t)){1'b0}});
      s4_q  <= s4_t'({($bits(s4_t)){1'b0}});
    end else begin
      s1_q  <= s1_d;
      s2_q  <= s2_d;
      s2b_q <= s2b_d;
      s3_q  <= s3_d;
      s3b_q <= s3b_d;
      s4_q  <= s4_d;
      if (flush_i) begin
        s1_q.valid  <= 1'b0;
        s2_q.valid  <= 1'b0;
        s2b_q.valid <= 1'b0;
        s3_q.valid  <= 1'b0;
        s3b_q.valid <= 1'b0;
        s4_q.valid  <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= {kronos_pkg::FP_D_TOTAL_W{1'b0}};
      fflags_o    <= 5'd0;
      tag_o       <= fpu_tag_t'({($bits(fpu_tag_t)){1'b0}});
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s4_q.valid;
      result_o    <= s5_result;
      fflags_o    <= s5_flags;
      tag_o       <= s4_q.tag;
    end
  end

  // OR-reduce dropped pipeline-register slices and the s5_mant_w mux selector
  // (the per-format width is folded into the s5_out_*_d/s widths instead).
  assign _unused = ^{s1_q, s2_q, s5_mant_w};

endmodule
