// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_fpu_fadd — 4-cycle pipelined FADD/FSUB unit (S and D precision).
//
// Pipeline layout:
//   S1  decompose/unbox operands, classify specials, apply FSUB sign flip
//   S2  exponent difference, align smaller operand, capture G/R/S
//   S3  add / subtract significands, normalize (leading-zero count)
//   S4  round, pack IEEE 754, generate flags, NaN-box single result
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
  input  logic [63:0] c_i,        // unused
  input  fpu_tag_t    tag_i,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // Suppress unused warning for c_i.
  logic [63:0] unused_c;
  assign unused_c = c_i;

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
  function automatic logic is_snan_s(input logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(input logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22] == 1'b1);
  endfunction
  function automatic logic is_snan_d(input logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction
  function automatic logic is_qnan_d(input logic [63:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b1);
  endfunction

  // Leading-zero count over SIG_W bits (returns 0..SIG_W).
  function automatic int unsigned clz_sig(input logic [SIG_W-1:0] x);
    int unsigned i;
    clz_sig = SIG_W;
    for (i = 0; i < SIG_W; i++) begin
      if (x[SIG_W-1-i]) begin
        clz_sig = i;
        break;
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

  // ---------------------------------------------------------------------------
  // Pipeline registers
  // ---------------------------------------------------------------------------
  s1_t s1_q;
  s2_t s2_q;
  s3_t s3_q;

  // ===========================================================================
  // Stage 1: decompose / classify
  // ===========================================================================
  s1_t s1_d;

  // Double operand fields
  logic        a_d_sign, b_d_sign;
  logic [10:0] a_d_expf, b_d_expf;
  logic [51:0] a_d_mant, b_d_mant;
  logic        a_d_zero, b_d_zero, a_d_inf, b_d_inf;
  logic        a_d_subn, b_d_subn;
  logic        a_d_snan, b_d_snan, a_d_qnan, b_d_qnan, a_d_nan, b_d_nan;

  // Unboxed single operands
  logic [31:0] a_s_bits, b_s_bits;
  logic        a_s_sign, b_s_sign;
  logic [7:0]  a_s_expf, b_s_expf;
  logic [22:0] a_s_mant, b_s_mant;
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

  always_comb begin
    // Block-local hoisted from specials sub-block
    logic zero_sign;
    zero_sign = 1'b0;

    // --- Double decomposition ---
    a_d_sign = a_i[63];
    b_d_sign = b_i[63];
    a_d_expf = a_i[62:52];
    b_d_expf = b_i[62:52];
    a_d_mant = a_i[51:0];
    b_d_mant = b_i[51:0];
    a_d_zero = (a_d_expf == 11'd0) && (a_d_mant == 52'd0);
    b_d_zero = (b_d_expf == 11'd0) && (b_d_mant == 52'd0);
    a_d_inf  = (a_d_expf == 11'h7FF) && (a_d_mant == 52'd0);
    b_d_inf  = (b_d_expf == 11'h7FF) && (b_d_mant == 52'd0);
    a_d_subn = (a_d_expf == 11'd0) && (a_d_mant != 52'd0);
    b_d_subn = (b_d_expf == 11'd0) && (b_d_mant != 52'd0);
    a_d_snan = is_snan_d(a_i);
    b_d_snan = is_snan_d(b_i);
    a_d_qnan = is_qnan_d(a_i);
    b_d_qnan = is_qnan_d(b_i);
    a_d_nan  = a_d_snan || a_d_qnan;
    b_d_nan  = b_d_snan || b_d_qnan;

    // --- Single decomposition (with NaN-unbox) ---
    a_s_bits = (a_i[63:32] == FP_NANBOX_UPPER) ? a_i[31:0] : FP_CANON_QNAN_S;
    b_s_bits = (b_i[63:32] == FP_NANBOX_UPPER) ? b_i[31:0] : FP_CANON_QNAN_S;
    a_s_sign = a_s_bits[31];
    b_s_sign = b_s_bits[31];
    a_s_expf = a_s_bits[30:23];
    b_s_expf = b_s_bits[30:23];
    a_s_mant = a_s_bits[22:0];
    b_s_mant = b_s_bits[22:0];
    a_s_zero = (a_s_expf == 8'd0) && (a_s_mant == 23'd0);
    b_s_zero = (b_s_expf == 8'd0) && (b_s_mant == 23'd0);
    a_s_inf  = (a_s_expf == 8'hFF) && (a_s_mant == 23'd0);
    b_s_inf  = (b_s_expf == 8'hFF) && (b_s_mant == 23'd0);
    a_s_subn = (a_s_expf == 8'd0) && (a_s_mant != 23'd0);
    b_s_subn = (b_s_expf == 8'd0) && (b_s_mant != 23'd0);
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
                           : (13'(a_d_expf) - 13'sd1023);
      b_exp_sel = b_d_subn ? -13'sd1022
                           : (13'(b_d_expf) - 13'sd1023);
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
                           : (13'(a_s_expf) - 13'sd127);
      b_exp_sel = b_s_subn ? -13'sd126
                           : (13'(b_s_expf) - 13'sd127);
      // Left-justify a 24-bit significand into SIG_W (56-bit) field.
      // For S, 53-bit equivalent: put the 24 bits at the top, zeros below.
      a_sig_sel = {(a_s_subn || a_s_zero) ? 1'b0 : 1'b1, a_s_mant,
                   (SIG_W - 1 - 23)'('0)};
      b_sig_sel = {(b_s_subn || b_s_zero) ? 1'b0 : 1'b1, b_s_mant,
                   (SIG_W - 1 - 23)'('0)};
    end

    // FSUB: logical sign flip on b at this stage.
    b_sign_pre = b_sign_sel ^ (op_i == FP_FSUB);

    // --- Compose S1 payload ---
    s1_d = '0;
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
    // NaN input → canonical qNaN; sNaN sets NV.
    // Inf + -Inf → canonical qNaN + NV.
    // Inf + finite → that infinity.
    // Zero + zero: depends on sign/RM.
    begin : specials
      logic eff_sub_early;
      logic both_inf_opposite;
      logic both_zero_early;
      eff_sub_early = a_sign_sel ^ b_sign_pre;  // magnitudes subtract
      both_inf_opposite = a_inf_sel && b_inf_sel && eff_sub_early;
      both_zero_early   = a_zero_sel && b_zero_sel;

      s1_d.is_special  = 1'b0;
      s1_d.special_res = '0;
      s1_d.special_flg = 5'd0;

      if (a_nan_sel || b_nan_sel) begin
        s1_d.is_special  = 1'b1;
        s1_d.special_res = fmt_d_i ? FP_CANON_QNAN_D
                                   : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
        if (a_snan_sel || b_snan_sel)
          s1_d.special_flg[FP_FFLAG_NV] = 1'b1;
      end else if (both_inf_opposite) begin
        s1_d.is_special  = 1'b1;
        s1_d.special_res = fmt_d_i ? FP_CANON_QNAN_D
                                   : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
        s1_d.special_flg[FP_FFLAG_NV] = 1'b1;
      end else if (a_inf_sel || b_inf_sel) begin
        s1_d.is_special = 1'b1;
        // Propagate the infinity that's present; same sign as it (b sign already
        // flipped for FSUB).
        if (a_inf_sel) begin
          s1_d.special_res = fmt_d_i ? {a_sign_sel, 11'h7FF, 52'd0}
                                     : {FP_NANBOX_UPPER, a_sign_sel, 8'hFF, 23'd0};
        end else begin
          s1_d.special_res = fmt_d_i ? {b_sign_pre, 11'h7FF, 52'd0}
                                     : {FP_NANBOX_UPPER, b_sign_pre, 8'hFF, 23'd0};
        end
      end else if (both_zero_early) begin
        // 0 + 0: sign(result) = sign(a) & sign(b) for eff_sub=0; else for RDN,
        // it's -0; else +0.
        s1_d.is_special = 1'b1;
        begin
          if (!eff_sub_early) begin
            // Additive zero: both signs must match for a signed zero; otherwise
            // the sign is +0 except in RDN.
            zero_sign = a_sign_sel & b_sign_pre;
          end else begin
            zero_sign = (rm_i == FP_RM_RDN);
          end
          s1_d.special_res = fmt_d_i ? {zero_sign, 63'd0}
                                     : {FP_NANBOX_UPPER, zero_sign, 31'd0};
        end
      end
    end
  end

  // ===========================================================================
  // Stage 2: exponent difference, align, collect G/R/S
  // ===========================================================================
  s2_t s2_d;

  always_comb begin
    s2_d = '0;
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

    begin : align_blk
      logic signed [EXP_W-1:0] exp_diff;
      logic                    a_is_big;
      logic [SIG_W-1:0]        big_raw;
      logic [SIG_W-1:0]        small_raw;
      int unsigned             shift_amt;
      logic [SIG_W-1:0]        shifted;
      logic                    sticky_extra;
      int unsigned             i;
      int unsigned             max_shift;

      exp_diff = s1_q.a_exp - s1_q.b_exp;

      // Decide which operand has the larger exponent. Tie broken by
      // significand magnitude.
      if (s1_q.a_exp > s1_q.b_exp) a_is_big = 1'b1;
      else if (s1_q.a_exp < s1_q.b_exp) a_is_big = 1'b0;
      else a_is_big = (s1_q.a_sig >= s1_q.b_sig);

      if (a_is_big) begin
        big_raw   = s1_q.a_sig;
        small_raw = s1_q.b_sig;
        shift_amt = (exp_diff >= 0) ? int'(exp_diff) : -(int'(exp_diff));
        s2_d.res_exp  = s1_q.a_exp;
        s2_d.res_sign = s1_q.a_sign;
      end else begin
        big_raw   = s1_q.b_sig;
        small_raw = s1_q.a_sig;
        shift_amt = (exp_diff >= 0) ? int'(exp_diff) : -(int'(exp_diff));
        s2_d.res_exp  = s1_q.b_exp;
        s2_d.res_sign = s1_q.b_sign;
      end

      // Clamp shift: beyond SIG_W+2, the small operand effectively contributes
      // only sticky.
      max_shift = SIG_W + 2;
      if (shift_amt > max_shift) begin
        shifted      = '0;
        sticky_extra = (small_raw != '0);
      end else begin
        // Shift right, OR-collect the bits that fall off into sticky_extra.
        shifted      = small_raw >> shift_amt;
        sticky_extra = 1'b0;
        for (i = 0; i < SIG_W; i++) begin
          if (i < shift_amt) begin
            if (small_raw[i]) sticky_extra = 1'b1;
          end
        end
      end

      s2_d.big_sig            = big_raw;
      s2_d.small_sig          = shifted;
      s2_d.small_sticky_extra = sticky_extra;
    end
  end

  // ===========================================================================
  // Stage 3: add / subtract, normalize
  // ===========================================================================
  s3_t s3_d;

  always_comb begin
    s3_d = '0;
    s3_d.valid       = s2_q.valid;
    s3_d.fmt_d       = s2_q.fmt_d;
    s3_d.rm          = s2_q.rm;
    s3_d.tag         = s2_q.tag;
    s3_d.is_special  = s2_q.is_special;
    s3_d.special_res = s2_q.special_res;
    s3_d.special_flg = s2_q.special_flg;
    s3_d.res_sign    = s2_q.res_sign;
    s3_d.res_exp     = s2_q.res_exp;

    begin : addsub_blk
      logic [SIG_W:0]          sum_ext;      // one extra bit for carry
      logic [SIG_W-1:0]        sum_sig;
      logic                    carry_out;
      int unsigned             lzc;
      logic [SIG_W-1:0]        norm_sig;
      logic signed [EXP_W-1:0] norm_exp;
      logic                    result_zero;
      logic                    small_sticky;

      sum_sig      = '0;
      carry_out    = 1'b0;
      lzc          = 0;
      norm_sig     = '0;
      norm_exp     = '0;
      result_zero  = 1'b0;
      small_sticky = s2_q.small_sticky_extra;

      if (!s2_q.op_sub) begin
        // Addition of magnitudes.
        sum_ext   = {1'b0, s2_q.big_sig} + {1'b0, s2_q.small_sig};
        carry_out = sum_ext[SIG_W];
        if (carry_out) begin
          // Overflow: shift right by 1, increment exponent. LSB goes into
          // sticky (since it was a post-alignment bit).
          norm_sig = sum_ext[SIG_W:1];
          norm_exp = s3_d.res_exp + 13'sd1;
          small_sticky = small_sticky | sum_ext[0];
        end else begin
          norm_sig = sum_ext[SIG_W-1:0];
          norm_exp = s3_d.res_exp;
        end
        s3_d.res_sig = norm_sig;
        s3_d.res_exp = norm_exp;
        // Extract G/R/S from the low 3 bits of norm_sig (the reserved alignment
        // bits) merged with incoming small_sticky.
        s3_d.guard   = norm_sig[2];
        s3_d.round_b = norm_sig[1];
        s3_d.sticky  = norm_sig[0] | small_sticky;
        // Clear the sub-ULP bits in the stored significand (they were G/R/S).
        s3_d.res_sig[2:0] = 3'd0;
        result_zero = (norm_sig == '0);
      end else begin
        // Subtraction: big - small. Include the extra sticky in the subtract as
        // a "borrow that would be used by sticky" — we handle it by subtracting
        // at full precision and keeping the extra bit as the sticky.
        sum_ext   = {1'b0, s2_q.big_sig} - {1'b0, s2_q.small_sig}
                    - {{(SIG_W){1'b0}}, small_sticky};
        sum_sig   = sum_ext[SIG_W-1:0];
        // Leading-zero count for normalization.
        lzc = clz_sig(sum_sig);
        if (lzc == SIG_W) begin
          result_zero = 1'b1;
          norm_sig    = '0;
          norm_exp    = '0;
        end else begin
          result_zero = 1'b0;
          norm_sig    = sum_sig << lzc;
          norm_exp    = s3_d.res_exp - 13'($signed(lzc));
        end
        s3_d.res_sig = norm_sig;
        s3_d.res_exp = norm_exp;
        s3_d.guard   = norm_sig[2];
        s3_d.round_b = norm_sig[1];
        // After a cancellation-shift the bits that fed sticky via small_sticky
        // are no longer meaningful if lzc shifted them in — but for RNE-correct
        // subtraction in the close-path, sticky=0 when lzc>0 because only one
        // bit differs. Conservative: keep OR.
        s3_d.sticky  = norm_sig[0] | (small_sticky & (lzc == 0));
        s3_d.res_sig[2:0] = 3'd0;
      end

      s3_d.result_zero = result_zero;
      if (result_zero) begin
        // Cancellation-to-zero sign rule (non-special path): RDN→-0 else +0.
        s3_d.res_sign = (s2_q.rm == FP_RM_RDN);
      end
    end
  end

  // ===========================================================================
  // Stage 4: round, pack, flags
  // ===========================================================================
  logic [63:0] s4_result;
  logic [4:0]  s4_flags;

  always_comb begin
    // Hoisted locals from pack / subnormal / round / overflow sub-blocks
    int unsigned             mant_w;
    int unsigned             exp_w;
    logic signed [EXP_W-1:0] emin;
    logic signed [EXP_W-1:0] emax;
    logic signed [EXP_W-1:0] bias;
    logic signed [EXP_W-1:0] cur_exp;
    logic [SIG_W-1:0]        cur_sig;
    logic                    g, r, st;
    int unsigned             sub_shift;
    int unsigned             i;
    logic                    lsb;
    logic                    round_up;
    logic [SIG_W-1:0]        rounded_sig;
    logic                    carry_up;
    logic [51:0]             out_mant_d;
    logic [22:0]             out_mant_s;
    logic [10:0]             out_expf_d;
    logic [7:0]              out_expf_s;
    logic                    overflow;
    logic                    is_subnormal_out;
    logic                    inexact;
    int unsigned             sh;
    logic [2:0]              grs_vec;
    logic [SIG_W:0]          incremented;
    logic [SIG_W-1:0]        mask_one;
    logic                    to_inf;

    // Defaults
    s4_result        = '0;
    s4_flags         = 5'd0;
    mant_w           = 0;
    exp_w            = 0;
    emin             = '0;
    emax             = '0;
    bias             = '0;
    cur_exp          = '0;
    cur_sig          = '0;
    g                = 1'b0;
    r                = 1'b0;
    st               = 1'b0;
    sub_shift        = 0;
    i                = 0;
    lsb              = 1'b0;
    round_up         = 1'b0;
    rounded_sig      = '0;
    carry_up         = 1'b0;
    out_mant_d       = '0;
    out_mant_s       = '0;
    out_expf_d       = '0;
    out_expf_s       = '0;
    overflow         = 1'b0;
    is_subnormal_out = 1'b0;
    inexact          = 1'b0;
    sh               = 0;
    grs_vec          = '0;
    incremented      = '0;
    mask_one         = '0;
    to_inf           = 1'b0;

    if (s3_q.is_special) begin
      s4_result = s3_q.special_res;
      s4_flags  = s3_q.special_flg;
    end else if (s3_q.result_zero) begin
      if (s3_q.fmt_d) s4_result = {s3_q.res_sign, 63'd0};
      else            s4_result = {FP_NANBOX_UPPER, s3_q.res_sign, 31'd0};
    end else begin : pack

      if (s3_q.fmt_d) begin
        mant_w = 52;
        exp_w  = 11;
        bias   = 13'sd1023;
        emin   = -13'sd1022;
        emax   = 13'sd1023;
      end else begin
        mant_w = 23;
        exp_w  = 8;
        bias   = 13'sd127;
        emin   = -13'sd126;
        emax   = 13'sd127;
      end

      cur_exp = s3_q.res_exp;
      cur_sig = s3_q.res_sig;
      g  = s3_q.guard;
      r  = s3_q.round_b;
      st = s3_q.sticky;

      // --- Subnormal flush: if exp < emin, shift significand right until
      //     exp == emin, accumulating dropped bits into G/R/S.
      if (cur_exp < emin) begin
        grs_vec = {g, r, st};
        sh = {19'd0, 13'(emin - cur_exp)};
        // Pull guard/round/sticky back into significand LSBs so we can reuse
        // the same shifter.
        // We'll iterate shifting right 1 bit at a time.
        for (i = 0; i < sh; i++) begin
          // Capture LSB into sticky, shift GRS right, load new G from current
          // significand bit after shift.
          grs_vec[0] = grs_vec[0] | grs_vec[1];
          grs_vec[1] = grs_vec[2];
          grs_vec[2] = cur_sig[0];
          cur_sig    = {1'b0, cur_sig[SIG_W-1:1]};
        end
        g  = grs_vec[2];
        r  = grs_vec[1];
        st = grs_vec[0];
        cur_exp = emin;
      end

      // --- Round ---
      // For S, significand effective LSB sits higher in cur_sig: LSB is at bit
      // (SIG_W-1-mant_w) above the implicit 3 alignment bits. But we already
      // left-justify single operands with 3 lower zero bits... For S we must
      // treat guard/round/sticky as bits just below the 24-bit significand.
      // Because S operands were placed left-justified with zero padding in the
      // low (SIG_W-24) bits, the guard/round/sticky bits for S came from those
      // pad bits during alignment — same encoding applies. So we extract:
      //   lsb at index (SIG_W - 1 - mant_w)
      //   guard already in bit 2, round in bit 1, sticky in bit 0 for D.
      // For S, guard/round are actually stored bits inside cur_sig BELOW the
      // mantissa LSB — we must move them.
      //
      // Simplify: recompute G/R/S from cur_sig for both formats uniformly.
      // cur_sig layout: [hidden | mant | padding (for S) | G R S]
      //   D: SIG_W=56, 1 + 52 + 3 bits = 56. G=sig[2], R=sig[1], S=sig[0].
      //   S: 1 + 23 + (SIG_W-1-23) = 1 + 23 + 32 padding. The mantissa LSB is
      //      at bit 32. G=bit31, R=bit30, S=OR of bits[29:0] OR current st.
      if (!s3_q.fmt_d) begin
        g  = cur_sig[SIG_W - 1 - mant_w - 1];
        r  = cur_sig[SIG_W - 1 - mant_w - 2];
        for (i = 0; i < SIG_W - 1 - mant_w - 2; i++) begin
          if (cur_sig[i]) st = 1'b1;
        end
      end
      // LSB of kept significand.
      lsb = cur_sig[SIG_W - 1 - mant_w];

      round_up = 1'b0;
      unique case (s3_q.rm)
        FP_RM_RNE: round_up = g && (r || st || lsb);
        FP_RM_RTZ: round_up = 1'b0;
        FP_RM_RDN: round_up = s3_q.res_sign && (g | r | st);
        FP_RM_RUP: round_up = (!s3_q.res_sign) && (g | r | st);
        FP_RM_RMM: round_up = g;
        default:   round_up = 1'b0;
      endcase

      // Add 1 at position (SIG_W-1-mant_w) if rounding up.
      begin
        mask_one = '0;
        mask_one[SIG_W - 1 - mant_w] = 1'b1;
        if (round_up)
          incremented = {1'b0, cur_sig} + {1'b0, mask_one};
        else
          incremented = {1'b0, cur_sig};
        carry_up    = incremented[SIG_W];
        rounded_sig = incremented[SIG_W-1:0];
      end

      if (carry_up) begin
        rounded_sig = {1'b1, rounded_sig[SIG_W-1:1]};
        cur_exp     = cur_exp + 13'sd1;
      end

      inexact  = g | r | st;
      overflow = (cur_exp > emax);

      // Subnormal determination: hidden bit (bit SIG_W-1) = 0 after rounding.
      is_subnormal_out = (rounded_sig[SIG_W-1] == 1'b0);

      if (overflow) begin
        s4_flags[FP_FFLAG_OF] = 1'b1;
        s4_flags[FP_FFLAG_NX] = 1'b1;
        // RTZ / (RDN for pos) / (RUP for neg) → max finite; else ±Inf.
        begin
          unique case (s3_q.rm)
            FP_RM_RNE: to_inf = 1'b1;
            FP_RM_RTZ: to_inf = 1'b0;
            FP_RM_RDN: to_inf = s3_q.res_sign;
            FP_RM_RUP: to_inf = !s3_q.res_sign;
            FP_RM_RMM: to_inf = 1'b1;
            default:   to_inf = 1'b1;
          endcase
          if (s3_q.fmt_d) begin
            if (to_inf) s4_result = {s3_q.res_sign, 11'h7FF, 52'd0};
            else        s4_result = {s3_q.res_sign, 11'h7FE, {52{1'b1}}};
          end else begin
            if (to_inf) s4_result = {FP_NANBOX_UPPER, s3_q.res_sign, 8'hFF, 23'd0};
            else        s4_result = {FP_NANBOX_UPPER, s3_q.res_sign, 8'hFE, {23{1'b1}}};
          end
        end
      end else begin
        // Normal / subnormal packing.
        if (s3_q.fmt_d) begin
          out_mant_d = rounded_sig[SIG_W-2 -: 52];  // 52 bits below hidden
          if (is_subnormal_out) out_expf_d = 11'd0;
          else                  out_expf_d = 11'(cur_exp + bias);
          s4_result = {s3_q.res_sign, out_expf_d, out_mant_d};
        end else begin
          // Single: mantissa is the 23 bits just below the hidden bit.
          out_mant_s = rounded_sig[SIG_W-2 -: 23];
          if (is_subnormal_out) out_expf_s = 8'd0;
          else                  out_expf_s = 8'(cur_exp + bias);
          s4_result = {FP_NANBOX_UPPER, s3_q.res_sign, out_expf_s, out_mant_s};
        end

        if (inexact) s4_flags[FP_FFLAG_NX] = 1'b1;
        // Underflow (tininess after rounding) AND inexact → UF.
        if (is_subnormal_out && inexact) s4_flags[FP_FFLAG_UF] = 1'b1;
      end
    end
  end

  // ===========================================================================
  // Pipeline registers / flush
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_q <= '0;
      s2_q <= '0;
      s3_q <= '0;
    end else begin
      s1_q <= s1_d;
      s2_q <= s2_d;
      s3_q <= s3_d;
      if (flush_i) begin
        s1_q.valid <= 1'b0;
        s2_q.valid <= 1'b0;
        s3_q.valid <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s3_q.valid;
      result_o    <= s4_result;
      fflags_o    <= s4_flags;
      tag_o       <= s3_q.tag;
    end
  end

endmodule
