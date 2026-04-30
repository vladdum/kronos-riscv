// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 9-stage pipelined IEEE 754 floating-point multiplier (single and double).
//
// Pipeline:
//   S1:  NaN-unbox single, decompose operands, classify specials, precompute
//        sign / unbiased exponent sum / extended significands.
//   S1b: Re-latch multiplicands into s1b_*_q. Pipeline register #1 into the
//        DSP48 cascade.
//   S1c: Re-latch multiplicands into s1c_*_q. Pipeline register #2 into the
//        DSP48 cascade. Together with S1b, gives Vivado three flops between
//        the multiplicand source and the start of the partial-product DSP
//        cascade, so retiming can place them in the DSP48 AREG/MREG pipeline.
//   S2a: Two partial products — split sigb into a 27-bit low half and a 26-bit
//        high half and compute 53×27 / 53×26 in parallel. Each partial fits in
//        a short DSP48E2 cascade (≤ 2 tiles), breaking the 53×53 cascade that
//        would otherwise span 3 cascaded DSP48E2 slices combinationally.
//   S2:  Sum the two registered partial products (pp_hi << 27 + pp_lo) into
//        the 106-bit product. Registered at stage boundary.
//   S3:  LZC only — compute 7-bit leading-zero count and normalized exponent
//        from the 106-bit product. Carry full product forward.
//   S3b: Normalize barrel shift — use registered LZC to shift product and
//        extract mantissa + GRS bits.
//   S4:  Subnormal shift — apply right-shift if exp_norm <= 0, refine GRS.
//   S5:  Round, handle overflow/underflow, pack, NaN-box single. Register.

module kronos_fpu_fmul
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        in_valid_i,
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

  // -------------------------------------------------------------------------
  // Format constants — shared widths pad single into the double datapath so
  // both formats share the arithmetic. Single significands are left-aligned
  // at bit [52:29].
  // -------------------------------------------------------------------------
  localparam int unsigned SIG_W     = 53;             // mantissa incl. hidden bit
  localparam int unsigned PROD_W    = 2 * SIG_W;      // 106
  localparam int unsigned EXP_EXT_W = 13;             // signed, covers both fmts

  // Partial-product split for the S2a stage. sigb is split into a 27-bit
  // low half [26:0] and a 26-bit high half [52:27]; each partial product
  // fits in a short DSP48E2 cascade.
  localparam int unsigned HALF_LO_W = 27;
  localparam int unsigned HALF_HI_W = SIG_W - HALF_LO_W;    // 26
  localparam int unsigned PP_LO_W   = SIG_W + HALF_LO_W;    // 80
  localparam int unsigned PP_HI_W   = SIG_W + HALF_HI_W;    // 79

  // -------------------------------------------------------------------------
  // Classification helpers
  // -------------------------------------------------------------------------
  function automatic logic is_snan_s(logic [31:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22] == 1'b0) && (x[21:0] != 22'd0);
  endfunction
  function automatic logic is_qnan_s(logic [31:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22] == 1'b1);
  endfunction
  function automatic logic is_nan_s(logic [31:0] x);
    return is_snan_s(x) || is_qnan_s(x);
  endfunction
  function automatic logic is_inf_s(logic [31:0] x);
    return (x[30:23] == FP_S_EXP_MAX) && (x[22:0] == 23'd0);
  endfunction
  function automatic logic is_zero_s(logic [31:0] x);
    return (x[30:0] == 31'd0);
  endfunction

  function automatic logic is_snan_d(logic [63:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction
  function automatic logic is_qnan_d(logic [63:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51] == 1'b1);
  endfunction
  function automatic logic is_nan_d(logic [63:0] x);
    return is_snan_d(x) || is_qnan_d(x);
  endfunction
  function automatic logic is_inf_d(logic [63:0] x);
    return (x[62:52] == FP_D_EXP_MAX) && (x[51:0] == 52'd0);
  endfunction
  function automatic logic is_zero_d(logic [63:0] x);
    return (x[62:0] == 63'd0);
  endfunction

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

  // -------------------------------------------------------------------------
  // S1 registers
  // -------------------------------------------------------------------------
  logic                        s1_valid_q;
  logic                        s1_fmt_d_q;
  logic [2:0]                  s1_rm_q;
  fpu_tag_t                    s1_tag_q;
  logic                        s1_sign_q;
  logic signed [EXP_EXT_W-1:0] s1_exp_sum_q;
  logic [SIG_W-1:0]            s1_siga_q;
  logic [SIG_W-1:0]            s1_sigb_q;
  logic                        s1_any_snan_q;
  logic                        s1_any_nan_q;
  logic                        s1_inf_times_zero_q;
  logic                        s1_res_is_inf_q;
  logic                        s1_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S1b registers: re-latch multiplicands to give Vivado retiming room inside
  // the 53×53 DSP cascade. No new functional content — pure pipeline depth.
  // -------------------------------------------------------------------------
  logic                        s1b_valid_q;
  logic                        s1b_fmt_d_q;
  logic [2:0]                  s1b_rm_q;
  fpu_tag_t                    s1b_tag_q;
  logic                        s1b_sign_q;
  logic signed [EXP_EXT_W-1:0] s1b_exp_sum_q;
  logic [SIG_W-1:0]            s1b_siga_q;
  logic [SIG_W-1:0]            s1b_sigb_q;
  logic                        s1b_any_snan_q;
  logic                        s1b_any_nan_q;
  logic                        s1b_inf_times_zero_q;
  logic                        s1b_res_is_inf_q;
  logic                        s1b_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S1c registers: second re-latch of multiplicands — pipeline register #2
  // into the DSP cascade.
  // -------------------------------------------------------------------------
  logic                        s1c_valid_q;
  logic                        s1c_fmt_d_q;
  logic [2:0]                  s1c_rm_q;
  fpu_tag_t                    s1c_tag_q;
  logic                        s1c_sign_q;
  logic signed [EXP_EXT_W-1:0] s1c_exp_sum_q;
  logic [SIG_W-1:0]            s1c_siga_q;
  logic [SIG_W-1:0]            s1c_sigb_q;
  logic                        s1c_any_snan_q;
  logic                        s1c_any_nan_q;
  logic                        s1c_inf_times_zero_q;
  logic                        s1c_res_is_inf_q;
  logic                        s1c_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S2a registers: register the two partial products plus forwarded metadata.
  // -------------------------------------------------------------------------
  logic                        s2a_valid_q;
  logic                        s2a_fmt_d_q;
  logic [2:0]                  s2a_rm_q;
  fpu_tag_t                    s2a_tag_q;
  logic                        s2a_sign_q;
  logic signed [EXP_EXT_W-1:0] s2a_exp_sum_q;
  logic [PP_LO_W-1:0]          s2a_pp_lo_q;
  logic [PP_HI_W-1:0]          s2a_pp_hi_q;
  logic                        s2a_any_snan_q;
  logic                        s2a_any_nan_q;
  logic                        s2a_inf_times_zero_q;
  logic                        s2a_res_is_inf_q;
  logic                        s2a_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S2 registers
  // -------------------------------------------------------------------------
  logic                        s2_valid_q;
  logic                        s2_fmt_d_q;
  logic [2:0]                  s2_rm_q;
  fpu_tag_t                    s2_tag_q;
  logic                        s2_sign_q;
  logic signed [EXP_EXT_W-1:0] s2_exp_sum_q;
  logic [PROD_W-1:0]           s2_prod_q;
  logic                        s2_any_snan_q;
  logic                        s2_any_nan_q;
  logic                        s2_inf_times_zero_q;
  logic                        s2_res_is_inf_q;
  logic                        s2_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S3 registers
  // -------------------------------------------------------------------------
  logic                        s3_valid_q;
  logic                        s3_fmt_d_q;
  logic [2:0]                  s3_rm_q;
  fpu_tag_t                    s3_tag_q;
  logic                        s3_sign_q;
  logic [6:0]                  s3_lz_q;
  logic signed [EXP_EXT_W-1:0] s3_exp_norm_q;
  logic [PROD_W-1:0]           s3_prod_q;
  logic                        s3_any_snan_q;
  logic                        s3_any_nan_q;
  logic                        s3_inf_times_zero_q;
  logic                        s3_res_is_inf_q;
  logic                        s3_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S3b registers
  // -------------------------------------------------------------------------
  logic                        s3b_valid_q;
  logic                        s3b_fmt_d_q;
  logic [2:0]                  s3b_rm_q;
  fpu_tag_t                    s3b_tag_q;
  logic                        s3b_sign_q;
  logic signed [EXP_EXT_W-1:0] s3b_exp_q;
  logic [SIG_W-1:0]            s3b_mant_q;
  logic                        s3b_g_q;
  logic                        s3b_r_q;
  logic                        s3b_s_q;
  logic                        s3b_is_subnormal_q;
  logic                        s3b_any_snan_q;
  logic                        s3b_any_nan_q;
  logic                        s3b_inf_times_zero_q;
  logic                        s3b_res_is_inf_q;
  logic                        s3b_res_is_zero_q;

  // -------------------------------------------------------------------------
  // S4 registers
  // -------------------------------------------------------------------------
  logic                        s4_valid_q;
  logic                        s4_fmt_d_q;
  logic [2:0]                  s4_rm_q;
  fpu_tag_t                    s4_tag_q;
  logic                        s4_sign_q;
  logic signed [EXP_EXT_W-1:0] s4_exp_q;
  logic [SIG_W-1:0]            s4_mant_q;
  logic                        s4_g_q;
  logic                        s4_r_q;
  logic                        s4_s_q;
  logic                        s4_is_subnormal_q;
  logic                        s4_any_snan_q;
  logic                        s4_any_nan_q;
  logic                        s4_inf_times_zero_q;
  logic                        s4_res_is_inf_q;
  logic                        s4_res_is_zero_q;

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  // S1 combinational
  logic [31:0]                 a_s_unb;
  logic [31:0]                 b_s_unb;
  logic                        s1_valid_d;
  logic                        s1_fmt_d_d;
  logic [2:0]                  s1_rm_d;
  fpu_tag_t                    s1_tag_d;
  logic                        s1_sign_d;
  logic signed [EXP_EXT_W-1:0] s1_exp_sum_d;
  logic [SIG_W-1:0]            s1_siga_d;
  logic [SIG_W-1:0]            s1_sigb_d;
  logic                        s1_any_snan_d;
  logic                        s1_any_nan_d;
  logic                        s1_inf_times_zero_d;
  logic                        s1_res_is_inf_d;
  logic                        s1_res_is_zero_d;
  logic [31:0]                 s1_a_s_l;
  logic [31:0]                 s1_b_s_l;
  logic                        s1_a_is_snan;
  logic                        s1_b_is_snan;
  logic                        s1_a_is_nan;
  logic                        s1_b_is_nan;
  logic                        s1_a_is_inf;
  logic                        s1_b_is_inf;
  logic                        s1_a_is_zero;
  logic                        s1_b_is_zero;
  logic                        s1_a_sub;
  logic                        s1_b_sub;
  logic [FP_S_EXP_W-1:0]       s1_ea_s;
  logic [FP_S_EXP_W-1:0]       s1_eb_s;
  logic [FP_D_EXP_W-1:0]       s1_ea_d;
  logic [FP_D_EXP_W-1:0]       s1_eb_d;
  logic signed [EXP_EXT_W-1:0] s1_ea_ext;
  logic signed [EXP_EXT_W-1:0] s1_eb_ext;

  // S2a combinational
  logic [PP_LO_W-1:0]          s2a_pp_lo_d;
  logic [PP_HI_W-1:0]          s2a_pp_hi_d;

  // S2 combinational
  logic [PROD_W-1:0]           s2_prod_d;

  // S3 combinational
  logic [6:0]                  s3_lz_d;
  logic signed [EXP_EXT_W-1:0] s3_exp_norm_d;
  logic [6:0]                  s3_lz_tmp;

  // S3b combinational
  logic [SIG_W-1:0]            s3b_mant_d;
  logic                        s3b_guard_d;
  logic                        s3b_round_d;
  logic                        s3b_sticky_d;
  logic                        s3b_is_subnormal_d;
  logic signed [EXP_EXT_W-1:0] s3b_exp_d;
  logic [PROD_W-1:0]           s3b_prod_norm;
  logic [6:0]                  s3b_lz_tmp;

  // S4 combinational
  logic [SIG_W-1:0]            s4_mant_d;
  logic                        s4_g_d;
  logic                        s4_r_d;
  logic                        s4_s_d;
  logic signed [EXP_EXT_W-1:0] s4_exp_d;
  logic signed [EXP_EXT_W-1:0] s4_shift_amt;
  logic [SIG_W-1:0]            s4_mant_fullw;
  logic                        s4_g_in;
  logic                        s4_r_in;
  logic                        s4_s_in;
  int unsigned                 s4_sh;
  logic [63:0]                 s4_tail;
  logic [63:0]                 s4_shifted;
  logic [63:0]                 s4_lost_mask;

  // S5 combinational
  logic [63:0]                 s5_result_d;
  logic [4:0]                  s5_fflags_d;
  logic signed [EXP_EXT_W-1:0] s5_exp_in;
  logic [SIG_W-1:0]            s5_mant_in;
  logic                        s5_g_in;
  logic                        s5_r_in;
  logic                        s5_s_in;
  logic [SIG_W-1:0]            s5_mant_kept;
  logic                        s5_g_eff;
  logic                        s5_r_eff;
  logic                        s5_s_eff;
  logic                        s5_round_inc;
  logic [SIG_W:0]              s5_mant_rnd;     // 54 bits to catch carry-out
  logic signed [EXP_EXT_W-1:0] s5_exp_rnd;
  logic                        s5_inexact;
  logic                        s5_overflow;
  logic                        s5_underflow_tiny;   // subnormal before rounding
  logic [FP_S_EXP_W-1:0]       s5_pack_exp_s;
  logic [FP_D_EXP_W-1:0]       s5_pack_exp_d;
  logic [FP_S_MANT_W-1:0]      s5_pack_frac_s;
  logic [FP_D_MANT_W-1:0]      s5_pack_frac_d;

  // -------------------------------------------------------------------------
  // S1 combinational: decompose, classify, prepare multiplicands
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults
    s1_a_s_l            = 32'h0;
    s1_b_s_l            = 32'h0;
    s1_a_is_snan        = 1'b0;
    s1_b_is_snan        = 1'b0;
    s1_a_is_nan         = 1'b0;
    s1_b_is_nan         = 1'b0;
    s1_a_is_inf         = 1'b0;
    s1_b_is_inf         = 1'b0;
    s1_a_is_zero        = 1'b0;
    s1_b_is_zero        = 1'b0;
    s1_a_sub            = 1'b0;
    s1_b_sub            = 1'b0;
    s1_ea_s             = {FP_S_EXP_W{1'b0}};
    s1_eb_s             = {FP_S_EXP_W{1'b0}};
    s1_ea_d             = {FP_D_EXP_W{1'b0}};
    s1_eb_d             = {FP_D_EXP_W{1'b0}};
    s1_ea_ext           = {EXP_EXT_W{1'b0}};
    s1_eb_ext           = {EXP_EXT_W{1'b0}};
    s1_siga_d           = {SIG_W{1'b0}};
    s1_sigb_d           = {SIG_W{1'b0}};
    s1_exp_sum_d        = {EXP_EXT_W{1'b0}};
    s1_sign_d           = 1'b0;

    // NaN-unbox single operands (mirrors kronos_fpu_fmisc).
    s1_a_s_l = (a_i[63:32] == FP_NANBOX_UPPER) ? a_i[31:0] : FP_CANON_QNAN_S;
    s1_b_s_l = (b_i[63:32] == FP_NANBOX_UPPER) ? b_i[31:0] : FP_CANON_QNAN_S;
    a_s_unb = s1_a_s_l;
    b_s_unb = s1_b_s_l;

    // Classification
    if (fmt_d_i) begin
      s1_a_is_snan = is_snan_d(a_i);
      s1_b_is_snan = is_snan_d(b_i);
      s1_a_is_nan  = is_nan_d(a_i);
      s1_b_is_nan  = is_nan_d(b_i);
      s1_a_is_inf  = is_inf_d(a_i);
      s1_b_is_inf  = is_inf_d(b_i);
      s1_a_is_zero = is_zero_d(a_i);
      s1_b_is_zero = is_zero_d(b_i);
    end else begin
      s1_a_is_snan = is_snan_s(s1_a_s_l);
      s1_b_is_snan = is_snan_s(s1_b_s_l);
      s1_a_is_nan  = is_nan_s(s1_a_s_l);
      s1_b_is_nan  = is_nan_s(s1_b_s_l);
      s1_a_is_inf  = is_inf_s(s1_a_s_l);
      s1_b_is_inf  = is_inf_s(s1_b_s_l);
      s1_a_is_zero = is_zero_s(s1_a_s_l);
      s1_b_is_zero = is_zero_s(s1_b_s_l);
    end

    s1_any_snan_d       = s1_a_is_snan || s1_b_is_snan;
    s1_any_nan_d        = s1_a_is_nan  || s1_b_is_nan;
    s1_inf_times_zero_d = (s1_a_is_inf && s1_b_is_zero) || (s1_a_is_zero && s1_b_is_inf);
    s1_res_is_inf_d     = (s1_a_is_inf || s1_b_is_inf) && !s1_inf_times_zero_d
                           && !s1_any_nan_d;
    s1_res_is_zero_d    = (s1_a_is_zero || s1_b_is_zero) && !s1_inf_times_zero_d
                           && !s1_any_nan_d && !s1_res_is_inf_d;

    // Sign
    if (fmt_d_i) s1_sign_d = a_i[63] ^ b_i[63];
    else         s1_sign_d = s1_a_s_l[31] ^ s1_b_s_l[31];

    // Exponent and significand extraction. Left-align single into the 53-bit
    // datapath so the same normalization logic handles both formats.
    s1_ea_s = s1_a_s_l[30:23];
    s1_eb_s = s1_b_s_l[30:23];
    s1_ea_d = a_i[62:52];
    s1_eb_d = b_i[62:52];

    if (fmt_d_i) begin
      s1_a_sub = (s1_ea_d == {FP_D_EXP_W{1'b0}}) && (a_i[51:0] != 52'd0);
      s1_b_sub = (s1_eb_d == {FP_D_EXP_W{1'b0}}) && (b_i[51:0] != 52'd0);
      s1_siga_d = {~s1_a_sub ? 1'b1 : 1'b0, a_i[51:0]};
      s1_sigb_d = {~s1_b_sub ? 1'b1 : 1'b0, b_i[51:0]};
      // Subnormals use true exponent 1 instead of 0.
      s1_ea_ext = s1_a_sub ? 13'sd1 : {{(EXP_EXT_W-FP_D_EXP_W){1'b0}}, s1_ea_d};
      s1_eb_ext = s1_b_sub ? 13'sd1 : {{(EXP_EXT_W-FP_D_EXP_W){1'b0}}, s1_eb_d};
      s1_exp_sum_d = s1_ea_ext + s1_eb_ext - 13'sd1023;
    end else begin
      s1_a_sub = (s1_ea_s == {FP_S_EXP_W{1'b0}}) && (s1_a_s_l[22:0] != 23'd0);
      s1_b_sub = (s1_eb_s == {FP_S_EXP_W{1'b0}}) && (s1_b_s_l[22:0] != 23'd0);
      // Left-align single mantissa at bit [52:29]: hidden bit at 52, fraction
      // at 51:29, low 29 bits zero.
      s1_siga_d = {~s1_a_sub ? 1'b1 : 1'b0, s1_a_s_l[22:0], 29'd0};
      s1_sigb_d = {~s1_b_sub ? 1'b1 : 1'b0, s1_b_s_l[22:0], 29'd0};
      s1_ea_ext = s1_a_sub ? 13'sd1 : {{(EXP_EXT_W-FP_S_EXP_W){1'b0}}, s1_ea_s};
      s1_eb_ext = s1_b_sub ? 13'sd1 : {{(EXP_EXT_W-FP_S_EXP_W){1'b0}}, s1_eb_s};
      s1_exp_sum_d = s1_ea_ext + s1_eb_ext - 13'sd127;
    end

    s1_fmt_d_d = fmt_d_i;
    s1_rm_d    = rm_i;
    s1_tag_d   = tag_i;
    s1_valid_d = in_valid_i;
  end

  // -------------------------------------------------------------------------
  // S1 registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q          <= 1'b0;
      s1_fmt_d_q          <= 1'b0;
      s1_rm_q             <= 3'd0;
      s1_tag_q            <= '{default: '0};
      s1_sign_q           <= 1'b0;
      s1_exp_sum_q        <= {EXP_EXT_W{1'b0}};
      s1_siga_q           <= {SIG_W{1'b0}};
      s1_sigb_q           <= {SIG_W{1'b0}};
      s1_any_snan_q       <= 1'b0;
      s1_any_nan_q        <= 1'b0;
      s1_inf_times_zero_q <= 1'b0;
      s1_res_is_inf_q     <= 1'b0;
      s1_res_is_zero_q    <= 1'b0;
    end else begin
      s1_valid_q          <= flush_i ? 1'b0 : s1_valid_d;
      s1_fmt_d_q          <= s1_fmt_d_d;
      s1_rm_q             <= s1_rm_d;
      s1_tag_q            <= s1_tag_d;
      s1_sign_q           <= s1_sign_d;
      s1_exp_sum_q        <= s1_exp_sum_d;
      s1_siga_q           <= s1_siga_d;
      s1_sigb_q           <= s1_sigb_d;
      s1_any_snan_q       <= s1_any_snan_d;
      s1_any_nan_q        <= s1_any_nan_d;
      s1_inf_times_zero_q <= s1_inf_times_zero_d;
      s1_res_is_inf_q     <= s1_res_is_inf_d;
      s1_res_is_zero_q    <= s1_res_is_zero_d;
    end
  end

  // -------------------------------------------------------------------------
  // S1b registers: pure pipeline depth into the DSP cascade.
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s1b_regs
    if (!rst_ni) begin
      s1b_valid_q          <= 1'b0;
      s1b_fmt_d_q          <= 1'b0;
      s1b_rm_q             <= 3'd0;
      s1b_tag_q            <= '{default: '0};
      s1b_sign_q           <= 1'b0;
      s1b_exp_sum_q        <= {EXP_EXT_W{1'b0}};
      s1b_siga_q           <= {SIG_W{1'b0}};
      s1b_sigb_q           <= {SIG_W{1'b0}};
      s1b_any_snan_q       <= 1'b0;
      s1b_any_nan_q        <= 1'b0;
      s1b_inf_times_zero_q <= 1'b0;
      s1b_res_is_inf_q     <= 1'b0;
      s1b_res_is_zero_q    <= 1'b0;
    end else begin
      s1b_valid_q          <= flush_i ? 1'b0 : s1_valid_q;
      s1b_fmt_d_q          <= s1_fmt_d_q;
      s1b_rm_q             <= s1_rm_q;
      s1b_tag_q            <= s1_tag_q;
      s1b_sign_q           <= s1_sign_q;
      s1b_exp_sum_q        <= s1_exp_sum_q;
      s1b_siga_q           <= s1_siga_q;
      s1b_sigb_q           <= s1_sigb_q;
      s1b_any_snan_q       <= s1_any_snan_q;
      s1b_any_nan_q        <= s1_any_nan_q;
      s1b_inf_times_zero_q <= s1_inf_times_zero_q;
      s1b_res_is_inf_q     <= s1_res_is_inf_q;
      s1b_res_is_zero_q    <= s1_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S1c registers: second re-latch — pipeline register #2 into the DSP
  // cascade. Together with S1b, gives Vivado retiming three flops between
  // the multiplicand source (s1_*_q) and the product (s2_prod_q).
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s1c_regs
    if (!rst_ni) begin
      s1c_valid_q          <= 1'b0;
      s1c_fmt_d_q          <= 1'b0;
      s1c_rm_q             <= 3'd0;
      s1c_tag_q            <= '{default: '0};
      s1c_sign_q           <= 1'b0;
      s1c_exp_sum_q        <= {EXP_EXT_W{1'b0}};
      s1c_siga_q           <= {SIG_W{1'b0}};
      s1c_sigb_q           <= {SIG_W{1'b0}};
      s1c_any_snan_q       <= 1'b0;
      s1c_any_nan_q        <= 1'b0;
      s1c_inf_times_zero_q <= 1'b0;
      s1c_res_is_inf_q     <= 1'b0;
      s1c_res_is_zero_q    <= 1'b0;
    end else begin
      s1c_valid_q          <= flush_i ? 1'b0 : s1b_valid_q;
      s1c_fmt_d_q          <= s1b_fmt_d_q;
      s1c_rm_q             <= s1b_rm_q;
      s1c_tag_q            <= s1b_tag_q;
      s1c_sign_q           <= s1b_sign_q;
      s1c_exp_sum_q        <= s1b_exp_sum_q;
      s1c_siga_q           <= s1b_siga_q;
      s1c_sigb_q           <= s1b_sigb_q;
      s1c_any_snan_q       <= s1b_any_snan_q;
      s1c_any_nan_q        <= s1b_any_nan_q;
      s1c_inf_times_zero_q <= s1b_inf_times_zero_q;
      s1c_res_is_inf_q     <= s1b_res_is_inf_q;
      s1c_res_is_zero_q    <= s1b_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S2a combinational: two partial products (53×27 and 53×26)
  // -------------------------------------------------------------------------
  always_comb begin
    s2a_pp_lo_d = s1c_siga_q * s1c_sigb_q[HALF_LO_W-1:0];
    s2a_pp_hi_d = s1c_siga_q * s1c_sigb_q[SIG_W-1:HALF_LO_W];
  end

  // -------------------------------------------------------------------------
  // S2a registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s2a_regs
    if (!rst_ni) begin
      s2a_valid_q          <= 1'b0;
      s2a_fmt_d_q          <= 1'b0;
      s2a_rm_q             <= 3'd0;
      s2a_tag_q            <= '{default: '0};
      s2a_sign_q           <= 1'b0;
      s2a_exp_sum_q        <= {EXP_EXT_W{1'b0}};
      s2a_pp_lo_q          <= {PP_LO_W{1'b0}};
      s2a_pp_hi_q          <= {PP_HI_W{1'b0}};
      s2a_any_snan_q       <= 1'b0;
      s2a_any_nan_q        <= 1'b0;
      s2a_inf_times_zero_q <= 1'b0;
      s2a_res_is_inf_q     <= 1'b0;
      s2a_res_is_zero_q    <= 1'b0;
    end else begin
      s2a_valid_q          <= flush_i ? 1'b0 : s1c_valid_q;
      s2a_fmt_d_q          <= s1c_fmt_d_q;
      s2a_rm_q             <= s1c_rm_q;
      s2a_tag_q            <= s1c_tag_q;
      s2a_sign_q           <= s1c_sign_q;
      s2a_exp_sum_q        <= s1c_exp_sum_q;
      s2a_pp_lo_q          <= s2a_pp_lo_d;
      s2a_pp_hi_q          <= s2a_pp_hi_d;
      s2a_any_snan_q       <= s1c_any_snan_q;
      s2a_any_nan_q        <= s1c_any_nan_q;
      s2a_inf_times_zero_q <= s1c_inf_times_zero_q;
      s2a_res_is_inf_q     <= s1c_res_is_inf_q;
      s2a_res_is_zero_q    <= s1c_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S2 combinational: sum the two partial products into the full 106-bit
  // product. pp_hi << 27 + pp_lo. Result fits in PROD_W (106) bits since
  // siga × sigb < 2^106 for any 53-bit operands.
  // -------------------------------------------------------------------------
  always_comb begin
    s2_prod_d = {s2a_pp_hi_q, {HALF_LO_W{1'b0}}}
              + {{(PROD_W - PP_LO_W){1'b0}}, s2a_pp_lo_q};
  end

  // -------------------------------------------------------------------------
  // S2 registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_s2_regs
    if (!rst_ni) begin
      s2_valid_q          <= 1'b0;
      s2_fmt_d_q          <= 1'b0;
      s2_rm_q             <= 3'd0;
      s2_tag_q            <= '{default: '0};
      s2_sign_q           <= 1'b0;
      s2_exp_sum_q        <= {EXP_EXT_W{1'b0}};
      s2_prod_q           <= {PROD_W{1'b0}};
      s2_any_snan_q       <= 1'b0;
      s2_any_nan_q        <= 1'b0;
      s2_inf_times_zero_q <= 1'b0;
      s2_res_is_inf_q     <= 1'b0;
      s2_res_is_zero_q    <= 1'b0;
    end else begin
      s2_valid_q          <= flush_i ? 1'b0 : s2a_valid_q;
      s2_fmt_d_q          <= s2a_fmt_d_q;
      s2_rm_q             <= s2a_rm_q;
      s2_tag_q            <= s2a_tag_q;
      s2_sign_q           <= s2a_sign_q;
      s2_exp_sum_q        <= s2a_exp_sum_q;
      s2_prod_q           <= s2_prod_d;
      s2_any_snan_q       <= s2a_any_snan_q;
      s2_any_nan_q        <= s2a_any_nan_q;
      s2_inf_times_zero_q <= s2a_inf_times_zero_q;
      s2_res_is_inf_q     <= s2a_res_is_inf_q;
      s2_res_is_zero_q    <= s2a_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S3 combinational: LZC only
  // -------------------------------------------------------------------------
  always_comb begin
    s3_lz_d       = 7'h0;
    s3_exp_norm_d = {EXP_EXT_W{1'b0}};
    s3_lz_tmp     = 7'h0;

    s3_lz_tmp = lzc106(s2_prod_q);
    s3_lz_d   = s3_lz_tmp;
    if (s3_lz_tmp == 7'd0) begin
      s3_exp_norm_d = s2_exp_sum_q + 13'sd1;
    end else begin
      s3_exp_norm_d = s2_exp_sum_q + 13'sd1 - {6'b0, s3_lz_tmp};
    end
  end

  // -------------------------------------------------------------------------
  // S3 registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3_valid_q          <= 1'b0;
      s3_fmt_d_q          <= 1'b0;
      s3_rm_q             <= 3'd0;
      s3_tag_q            <= '{default: '0};
      s3_sign_q           <= 1'b0;
      s3_lz_q             <= 7'h0;
      s3_exp_norm_q       <= {EXP_EXT_W{1'b0}};
      s3_prod_q           <= {PROD_W{1'b0}};
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
      s3_lz_q             <= s3_lz_d;
      s3_exp_norm_q       <= s3_exp_norm_d;
      s3_prod_q           <= s2_prod_q;
      s3_any_snan_q       <= s2_any_snan_q;
      s3_any_nan_q        <= s2_any_nan_q;
      s3_inf_times_zero_q <= s2_inf_times_zero_q;
      s3_res_is_inf_q     <= s2_res_is_inf_q;
      s3_res_is_zero_q    <= s2_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S3b combinational: normalize barrel shift using registered LZC
  // -------------------------------------------------------------------------
  always_comb begin
    s3b_prod_norm      = {PROD_W{1'b0}};
    s3b_mant_d         = {SIG_W{1'b0}};
    s3b_guard_d        = 1'b0;
    s3b_round_d        = 1'b0;
    s3b_sticky_d       = 1'b0;
    s3b_is_subnormal_d = 1'b0;
    s3b_exp_d          = s3_exp_norm_q;
    s3b_lz_tmp         = 7'h0;

    s3b_lz_tmp = s3_lz_q;

    if (s3b_lz_tmp == 7'd0) begin
      s3b_mant_d   = s3_prod_q[PROD_W-1 -: SIG_W];
      s3b_guard_d  = s3_prod_q[PROD_W-1 - SIG_W];
      s3b_round_d  = s3_prod_q[PROD_W-1 - SIG_W - 1];
      s3b_sticky_d = |s3_prod_q[PROD_W-1 - SIG_W - 2 : 0];
    end else begin
      s3b_prod_norm = s3_prod_q << (s3b_lz_tmp - 7'd1);
      s3b_mant_d    = s3b_prod_norm[PROD_W-2 -: SIG_W];
      s3b_guard_d   = s3b_prod_norm[PROD_W-2 - SIG_W];
      s3b_round_d   = s3b_prod_norm[PROD_W-2 - SIG_W - 1];
      s3b_sticky_d  = |s3b_prod_norm[PROD_W-2 - SIG_W - 2 : 0];
    end

    s3b_is_subnormal_d = (s3_exp_norm_q <= 13'sd0);
  end

  // -------------------------------------------------------------------------
  // S3b registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3b_valid_q          <= 1'b0;
      s3b_fmt_d_q          <= 1'b0;
      s3b_rm_q             <= 3'd0;
      s3b_tag_q            <= '{default: '0};
      s3b_sign_q           <= 1'b0;
      s3b_exp_q            <= {EXP_EXT_W{1'b0}};
      s3b_mant_q           <= {SIG_W{1'b0}};
      s3b_g_q              <= 1'b0;
      s3b_r_q              <= 1'b0;
      s3b_s_q              <= 1'b0;
      s3b_is_subnormal_q   <= 1'b0;
      s3b_any_snan_q       <= 1'b0;
      s3b_any_nan_q        <= 1'b0;
      s3b_inf_times_zero_q <= 1'b0;
      s3b_res_is_inf_q     <= 1'b0;
      s3b_res_is_zero_q    <= 1'b0;
    end else begin
      s3b_valid_q          <= flush_i ? 1'b0 : s3_valid_q;
      s3b_fmt_d_q          <= s3_fmt_d_q;
      s3b_rm_q             <= s3_rm_q;
      s3b_tag_q            <= s3_tag_q;
      s3b_sign_q           <= s3_sign_q;
      s3b_exp_q            <= s3_exp_norm_q;
      s3b_mant_q           <= s3b_mant_d;
      s3b_g_q              <= s3b_guard_d;
      s3b_r_q              <= s3b_round_d;
      s3b_s_q              <= s3b_sticky_d;
      s3b_is_subnormal_q   <= s3b_is_subnormal_d;
      s3b_any_snan_q       <= s3_any_snan_q;
      s3b_any_nan_q        <= s3_any_nan_q;
      s3b_inf_times_zero_q <= s3_inf_times_zero_q;
      s3b_res_is_inf_q     <= s3_res_is_inf_q;
      s3b_res_is_zero_q    <= s3_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S4 combinational: subnormal shift (if exp_norm <= 0)
  // -------------------------------------------------------------------------
  always_comb begin
    s4_shift_amt  = {EXP_EXT_W{1'b0}};
    s4_mant_fullw = s3b_mant_q;
    s4_g_in       = s3b_g_q;
    s4_r_in       = s3b_r_q;
    s4_s_in       = s3b_s_q;
    s4_sh         = 32'd0;
    s4_tail       = 64'h0;
    s4_shifted    = 64'h0;
    s4_lost_mask  = 64'h0;

    s4_mant_d = s3b_mant_q;
    s4_g_d    = s3b_g_q;
    s4_r_d    = s3b_r_q;
    s4_s_d    = s3b_s_q;
    s4_exp_d  = s3b_exp_q;

    if (s3b_is_subnormal_q) begin
      s4_shift_amt = 13'sd1 - s3b_exp_q;
      if (s4_shift_amt >= 13'sd64) s4_sh = 32'd64;
      else                         s4_sh = {25'd0, s4_shift_amt[6:0]};

      s4_tail = {s4_mant_fullw, s4_g_in, s4_r_in, s4_s_in, 8'd0};
      if (s4_sh >= 32'd64) begin
        s4_shifted   = 64'd0;
        s4_lost_mask = 64'hFFFF_FFFF_FFFF_FFFF;
      end else begin
        s4_shifted   = s4_tail >> s4_sh;
        s4_lost_mask = ~(64'hFFFF_FFFF_FFFF_FFFF << s4_sh);
      end
      s4_mant_d = s4_shifted[63:11];
      s4_g_d    = s4_shifted[10];
      s4_r_d    = s4_shifted[9];
      s4_s_d    = |s4_shifted[8:0] | (|(s4_tail & s4_lost_mask));
      s4_exp_d  = 13'sd0;
    end
  end

  // -------------------------------------------------------------------------
  // S4 registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s4_valid_q          <= 1'b0;
      s4_fmt_d_q          <= 1'b0;
      s4_rm_q             <= 3'd0;
      s4_tag_q            <= '{default: '0};
      s4_sign_q           <= 1'b0;
      s4_exp_q            <= {EXP_EXT_W{1'b0}};
      s4_mant_q           <= {SIG_W{1'b0}};
      s4_g_q              <= 1'b0;
      s4_r_q              <= 1'b0;
      s4_s_q              <= 1'b0;
      s4_is_subnormal_q   <= 1'b0;
      s4_any_snan_q       <= 1'b0;
      s4_any_nan_q        <= 1'b0;
      s4_inf_times_zero_q <= 1'b0;
      s4_res_is_inf_q     <= 1'b0;
      s4_res_is_zero_q    <= 1'b0;
    end else begin
      s4_valid_q          <= flush_i ? 1'b0 : s3b_valid_q;
      s4_fmt_d_q          <= s3b_fmt_d_q;
      s4_rm_q             <= s3b_rm_q;
      s4_tag_q            <= s3b_tag_q;
      s4_sign_q           <= s3b_sign_q;
      s4_exp_q            <= s4_exp_d;
      s4_mant_q           <= s4_mant_d;
      s4_g_q              <= s4_g_d;
      s4_r_q              <= s4_r_d;
      s4_s_q              <= s4_s_d;
      s4_is_subnormal_q   <= s3b_is_subnormal_q;
      s4_any_snan_q       <= s3b_any_snan_q;
      s4_any_nan_q        <= s3b_any_nan_q;
      s4_inf_times_zero_q <= s3b_inf_times_zero_q;
      s4_res_is_inf_q     <= s3b_res_is_inf_q;
      s4_res_is_zero_q    <= s3b_res_is_zero_q;
    end
  end

  // -------------------------------------------------------------------------
  // S5 combinational: round, overflow/underflow, pack, NaN-box
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults
    s5_result_d       = 64'h0;
    s5_fflags_d       = 5'h0;
    s5_exp_in         = {EXP_EXT_W{1'b0}};
    s5_mant_in        = {SIG_W{1'b0}};
    s5_g_in           = 1'b0;
    s5_r_in           = 1'b0;
    s5_s_in           = 1'b0;
    s5_mant_kept      = {SIG_W{1'b0}};
    s5_g_eff          = 1'b0;
    s5_r_eff          = 1'b0;
    s5_s_eff          = 1'b0;
    s5_round_inc      = 1'b0;
    s5_mant_rnd       = {(SIG_W+1){1'b0}};
    s5_exp_rnd        = {EXP_EXT_W{1'b0}};
    s5_inexact        = 1'b0;
    s5_overflow       = 1'b0;
    s5_underflow_tiny = 1'b0;
    s5_pack_exp_s     = {FP_S_EXP_W{1'b0}};
    s5_pack_exp_d     = {FP_D_EXP_W{1'b0}};
    s5_pack_frac_s    = {FP_S_MANT_W{1'b0}};
    s5_pack_frac_d    = {FP_D_MANT_W{1'b0}};

    s5_exp_in  = s4_exp_q;
    s5_mant_in = s4_mant_q;
    s5_g_in    = s4_g_q;
    s5_r_in    = s4_r_q;
    s5_s_in    = s4_s_q;

    // Extract kept mantissa + per-format GRS.
    // For single, kept fraction is bits [51:29] of mant_in, and [28:0] must
    // be folded into sticky along with g_in/r_in/s_in.
    if (s4_fmt_d_q) begin
      s5_mant_kept = s5_mant_in;       // 53 bits already
      s5_g_eff = s5_g_in;
      s5_r_eff = s5_r_in;
      s5_s_eff = s5_s_in;
    end else begin
      // Single: keep bits [52:29] (hidden + 23 frac). Next bit [28] is guard.
      s5_mant_kept = {{(SIG_W - (1 + FP_S_MANT_W)){1'b0}}, s5_mant_in[52:29]};
      s5_g_eff = s5_mant_in[28];
      s5_r_eff = s5_mant_in[27];
      s5_s_eff = |s5_mant_in[26:0] | s5_g_in | s5_r_in | s5_s_in;
    end

    // Determine if rounding increments mantissa
    s5_round_inc = round_up(s4_rm_q, s4_sign_q, s5_mant_kept[0],
                            s5_g_eff, s5_r_eff, s5_s_eff);
    s5_mant_rnd  = {1'b0, s5_mant_kept} + {{SIG_W{1'b0}}, s5_round_inc};
    s5_exp_rnd   = s5_exp_in;
    s5_inexact   = s5_g_eff | s5_r_eff | s5_s_eff;

    // Carry out of mantissa after rounding: shift right and bump exponent.
    // For single, carry means mant[24] set.
    // For double, carry means mant[53] set.
    // We also need to handle the subnormal→normal transition: when the
    // subnormal mantissa rounds up to 1.0 in the hidden-bit position, the
    // exponent becomes 1 (normal).
    if (s4_fmt_d_q) begin
      if (s5_mant_rnd[SIG_W]) begin
        // carry out of double's 53-bit field
        s5_mant_rnd = s5_mant_rnd >> 1;
        s5_exp_rnd  = s5_exp_rnd + 13'sd1;
      end
      // Subnormal that rounded into normal: mant_rnd[SIG_W-1]==1 (hidden),
      // exp was 0 (subnormal). Bump exp to 1.
      if ((s5_exp_in == 13'sd0) && s5_mant_rnd[SIG_W-1]) begin
        s5_exp_rnd = 13'sd1;
      end
    end else begin
      // For single: kept field is low 24 bits of mant_rnd.
      // verilator coverage_off
      if (s5_mant_rnd[1 + FP_S_MANT_W]) begin
        // carry out into bit 24
        s5_mant_rnd = s5_mant_rnd >> 1;
        s5_exp_rnd  = s5_exp_rnd + 13'sd1;
      end
      // verilator coverage_on
      if ((s5_exp_in == 13'sd0) && s5_mant_rnd[FP_S_MANT_W]) begin
        s5_exp_rnd = 13'sd1;
      end
    end

    s5_underflow_tiny = s4_is_subnormal_q;

    // -------- Build result --------
    if (s4_any_snan_q) begin
      // sNaN operand → invalid, canonical qNaN
      s5_fflags_d[FP_FFLAG_NV] = 1'b1;
      s5_result_d = s4_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s4_inf_times_zero_q) begin
      // inf * 0 → invalid, canonical qNaN
      s5_fflags_d[FP_FFLAG_NV] = 1'b1;
      s5_result_d = s4_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s4_any_nan_q) begin
      // qNaN propagation → canonical qNaN, no flag
      s5_result_d = s4_fmt_d_q ? FP_CANON_QNAN_D
                                : {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
    end else if (s4_res_is_inf_q) begin
      // inf * finite(non-zero) → signed infinity, no flag
      if (s4_fmt_d_q) begin
        s5_result_d = {s4_sign_q, FP_D_EXP_MAX, 52'd0};
      end else begin
        s5_result_d = {FP_NANBOX_UPPER, s4_sign_q, FP_S_EXP_MAX, 23'd0};
      end
    end else if (s4_res_is_zero_q) begin
      // zero * finite → signed zero, no flag
      if (s4_fmt_d_q) begin
        s5_result_d = {s4_sign_q, 63'd0};
      end else begin
        s5_result_d = {FP_NANBOX_UPPER, s4_sign_q, 31'd0};
      end
    end else begin
      // Normal numeric path — check overflow/underflow against format range.
      if (s4_fmt_d_q) begin
        s5_overflow = (s5_exp_rnd >= 13'sd2047);
        if (s5_overflow) begin
          s5_fflags_d[FP_FFLAG_OF] = 1'b1;
          s5_fflags_d[FP_FFLAG_NX] = 1'b1;
          // Rounding mode controls whether we produce inf or max-finite.
          unique case (s4_rm_q)
            3'b001: // RTZ → max-finite
              s5_result_d = {s4_sign_q, 11'h7FE, {FP_D_MANT_W{1'b1}}};
            3'b010: // RDN
              s5_result_d = s4_sign_q ? {1'b1, FP_D_EXP_MAX, 52'd0}
                                       : {1'b0, 11'h7FE, {FP_D_MANT_W{1'b1}}};
            3'b011: // RUP
              s5_result_d = s4_sign_q ? {1'b1, 11'h7FE, {FP_D_MANT_W{1'b1}}}
                                       : {1'b0, FP_D_EXP_MAX, 52'd0};
            default: // RNE, RMM → inf
              s5_result_d = {s4_sign_q, FP_D_EXP_MAX, 52'd0};
          endcase
        end else begin
          // Pack exponent and fraction
          if (s5_exp_rnd <= 13'sd0) begin
            s5_pack_exp_d = {FP_D_EXP_W{1'b0}};
          end else begin
            s5_pack_exp_d = s5_exp_rnd[FP_D_EXP_W-1:0];
          end
          s5_pack_frac_d = s5_mant_rnd[FP_D_MANT_W-1:0];
          s5_result_d = {s4_sign_q, s5_pack_exp_d, s5_pack_frac_d};
          s5_fflags_d[FP_FFLAG_NX] = s5_inexact;
          // Underflow: tiny before rounding AND inexact after rounding
          // (IEEE 754 "after rounding" underflow flag semantics).
          s5_fflags_d[FP_FFLAG_UF] = s5_underflow_tiny & s5_inexact
                                   & (s5_pack_exp_d == {FP_D_EXP_W{1'b0}});
        end
      end else begin
        s5_overflow = (s5_exp_rnd >= 13'sd255);
        if (s5_overflow) begin
          s5_fflags_d[FP_FFLAG_OF] = 1'b1;
          s5_fflags_d[FP_FFLAG_NX] = 1'b1;
          unique case (s4_rm_q)
            3'b001:
              s5_result_d = {FP_NANBOX_UPPER, s4_sign_q, 8'hFE, {FP_S_MANT_W{1'b1}}};
            3'b010:
              s5_result_d = s4_sign_q
                ? {FP_NANBOX_UPPER, 1'b1, FP_S_EXP_MAX, 23'd0}
                : {FP_NANBOX_UPPER, 1'b0, 8'hFE, {FP_S_MANT_W{1'b1}}};
            3'b011:
              s5_result_d = s4_sign_q
                ? {FP_NANBOX_UPPER, 1'b1, 8'hFE, {FP_S_MANT_W{1'b1}}}
                : {FP_NANBOX_UPPER, 1'b0, FP_S_EXP_MAX, 23'd0};
            default:
              s5_result_d = {FP_NANBOX_UPPER, s4_sign_q, FP_S_EXP_MAX, 23'd0};
          endcase
        end else begin
          if (s5_exp_rnd <= 13'sd0) begin
            s5_pack_exp_s = {FP_S_EXP_W{1'b0}};
          end else begin
            s5_pack_exp_s = s5_exp_rnd[FP_S_EXP_W-1:0];
          end
          s5_pack_frac_s = s5_mant_rnd[FP_S_MANT_W-1:0];
          s5_result_d = {FP_NANBOX_UPPER, s4_sign_q, s5_pack_exp_s, s5_pack_frac_s};
          s5_fflags_d[FP_FFLAG_NX] = s5_inexact;
          s5_fflags_d[FP_FFLAG_UF] = s5_underflow_tiny & s5_inexact
                                   & (s5_pack_exp_s == {FP_S_EXP_W{1'b0}});
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // S5 output registers
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= 64'h0;
      fflags_o    <= 5'h0;
      tag_o       <= '{default: '0};
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s4_valid_q;
      result_o    <= s5_result_d;
      fflags_o    <= s5_fflags_d;
      tag_o       <= s4_tag_q;
    end
  end

endmodule
