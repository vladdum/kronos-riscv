// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FCVT unit: integer<->FP conversions (W/WU/L/LU) and S<->D format conversion.
// 3-stage pipelined. Latency = 3 cycles.
//
// Pipeline split:
//   Stage 1: NaN-unbox single-precision inputs.
//   Stage 2: INT->FP negation (8xCARRY8) + CLZ + normalise + pre-round mantissa.
//            FP->INT shift + guard/sticky/round_up (before the 65-bit adder).
//            S<->D full conversion (no long carry chains; result registered here).
//   Stage 3: Rounding adders (INT->FP 54-bit, FP->INT 65-bit), sign, range-check.
//            This breaks the 15xCARRY8 chain that limited Fmax at 200 MHz.

module kronos_fpu_fcvt
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
  input  fpu_tag_t        tag_i,
  output logic            out_valid_o,
  output logic [FLEN-1:0] result_o,
  output logic [4:0]      fflags_o,
  output fpu_tag_t        tag_o
);

  // ---------------------------------------------------------------------------
  // Helper: count leading zeros (parameterised)
  // ---------------------------------------------------------------------------
  function automatic integer clz64(input logic [XLEN-1:0] x);
    integer i;
    clz64 = XLEN;
    for (i = XLEN-1; i >= 0; i = i - 1) begin
      if (x[i] && (clz64 == XLEN)) begin
        clz64 = (XLEN-1) - i;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // State registers (sequential)
  // ---------------------------------------------------------------------------
  // Stage-1
  logic            s1_valid_q;
  fp_op_e          s1_op_q;
  logic            s1_fmt_d_q;
  logic [2:0]      s1_rm_q;
  logic [FLEN-1:0] s1_a_q;
  fpu_tag_t        s1_tag_q;

  // Stage-2 control
  logic     s2_valid_q;
  fp_op_e   s2_op_q;
  logic     s2_fmt_d_q;
  fpu_tag_t s2_tag_q;

  // Stage-2 INT->FP intermediate (carry chain before the rounding adder)
  logic                  s2_ifp_isneg_q;
  logic                  s2_ifp_imag_zero_q;
  logic [FP_S_EXP_W-1:0] s2_ifp_s_exp_q;
  logic [FP_D_EXP_W-1:0] s2_ifp_d_exp_q;
  logic [FP_S_MANT_W:0]  s2_ifp_s_mant_pre_q;  // 24 bits: implicit 1 + 23 fractional
  logic [FP_D_MANT_W:0]  s2_ifp_d_mant_pre_q;  // 53 bits: implicit 1 + 52 fractional
  logic                  s2_ifp_s_round_up_q;
  logic                  s2_ifp_d_round_up_q;
  logic                  s2_ifp_s_inexact_q;
  logic                  s2_ifp_d_inexact_q;

  // Stage-2 FP->INT intermediate (before the 65-bit rounding adder)
  logic            s2_fpi_overflow_q;
  logic            s2_fpi_neg_of_q;
  logic            s2_fpi_src_is_nan_q;
  logic            s2_fpi_src_sign_q;
  logic            s2_fpi_target_is_32b_q;
  logic            s2_fpi_target_is_signed_q;
  logic [XLEN-1:0] s2_fpi_target_max_q;
  logic [XLEN-1:0] s2_fpi_target_min_q;
  logic [XLEN-1:0] s2_fpi_int_part_q;
  logic            s2_fpi_round_up_q;
  logic            s2_fpi_is_inexact_q;

  // Stage-2 S<->D full result (no long carry chains; computed in stage 2)
  logic [FP_D_TOTAL_W-1:0] s2_ds_result_q;
  logic [4:0]              s2_ds_fflags_q;

  // ---------------------------------------------------------------------------
  // Stage-1 combinational (NaN-unbox single-precision inputs)
  // ---------------------------------------------------------------------------
  logic [FLEN-1:0] s1_a_d;
  logic            s1_src_is_single;

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: source decomposition (FP->INT and S<->D)
  // ---------------------------------------------------------------------------
  logic                    src_sign;
  logic                    src_is_s;
  logic [FP_S_TOTAL_W-1:0] src_s;
  logic [FP_D_TOTAL_W-1:0] src_d;
  logic [FP_D_EXP_W-1:0]   src_exp_d;
  logic [FP_D_MANT_W-1:0]  src_mant_d;
  logic [FP_S_EXP_W-1:0]   src_exp_s;
  logic [FP_S_MANT_W-1:0]  src_mant_s;
  logic                    src_is_nan;
  logic                    src_is_inf;
  logic                    src_is_zero;

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: FP -> INT (compute int_part and round_up;
  //                                    int_rounded adder deferred to stage 3)
  // ---------------------------------------------------------------------------
  logic signed [FP_EXP_EXT_W-1:0] unbiased_exp;
  logic [XLEN-1:0]                int_part;
  logic                           rnd_g;
  logic                           rnd_s;
  logic                           rnd_lsb;
  logic                           fpi_round_up;
  logic                           is_inexact_fpi;
  logic [XLEN-1:0]                target_max;
  logic [XLEN-1:0]                target_min;
  logic                           target_is_signed;
  logic                           target_is_32b;
  logic                           fpi_overflow;
  logic                           fpi_neg_of;
  logic [XLEN-1:0]                sig64;
  logic [XLEN-1:0]                frac_mask;
  logic [6:0]                     shift_r;
  logic [FP_S_EXP_W-1:0]          frac_bits;

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: INT -> FP
  // ---------------------------------------------------------------------------
  logic                  ifp_isneg;
  logic                  ifp_imag_zero;
  logic [FP_S_EXP_W-1:0] ifp_s_exp;
  logic [FP_D_EXP_W-1:0] ifp_d_exp;
  logic [FP_S_MANT_W:0]  ifp_s_mant_pre;
  logic [FP_D_MANT_W:0]  ifp_d_mant_pre;
  logic                  ifp_s_round_up;
  logic                  ifp_d_round_up;
  logic                  ifp_s_inexact;
  logic                  ifp_d_inexact;
  logic [XLEN-1:0]       ifp_imag;
  logic                  ifp_isigned;
  logic                  ifp_is32;
  logic [XLEN-1:0]       ifp_norm;
  integer                ifp_lz;
  logic                  s_guard;
  logic                  s_round_sticky;
  logic                  s_lsb;
  logic                  d_guard;
  logic                  d_round_sticky;
  logic                  d_lsb;

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: S <-> D format conversion
  // ---------------------------------------------------------------------------
  logic [FP_D_TOTAL_W-1:0] s2c_ds_d;
  logic [4:0]              s2c_ds_fflags_d;
  logic [FP_D_TOTAL_W-1:0] d_result;
  logic [FP_S_TOTAL_W-1:0] s_result;
  logic [4:0]              fs_flags;
  logic                    sd_sign;
  logic [FP_S_EXP_W-1:0]   sd_sexp;
  logic [FP_S_MANT_W-1:0]  sd_smant;
  // D->S
  logic                           ds_sign;
  logic [FP_D_EXP_W-1:0]          ds_dexp;
  logic [FP_D_MANT_W-1:0]         ds_dmant;
  logic signed [FP_EXP_EXT_W-1:0] ds_unbiased;
  logic [FP_S_EXP_W-1:0]          ds_sexp_out;
  logic [FP_S_MANT_W:0]           ds_sig;
  logic                           ds_g;
  logic                           ds_sticky;
  logic                           ds_lsb;
  logic                           ds_round_up;
  logic [FP_S_MANT_W+1:0]         ds_rounded;
  logic [9:0]                     subn_shift_amt;
  logic [FP_S_MANT_W:0]           subn_sig24;
  logic [FP_S_MANT_W:0]           subn_sig;
  logic                           subn_g;
  logic                           subn_sticky;
  logic                           subn_round_up;
  logic [FP_S_MANT_W:0]           subn_rounded;
  logic [FP_S_MANT_W-1:0]         subn_mant;
  logic [FP_S_EXP_W-1:0]          subn_exp;
  // Subnormal S->D normalisation (used in FP_FCVT_D_S)
  integer                         sd_k;
  logic [FP_S_MANT_W-1:0]         sd_m;
  integer                         sd_shift_amt;
  logic                           sd_found_k;
  logic [FP_D_MANT_W:0]           sd_new_mant;
  logic [FP_D_EXP_W-1:0]          sd_new_exp;
  // Underflow flag intermediate (FP_FCVT_S_D normal-zero path)
  logic                           ds_nz_in;

  // ---------------------------------------------------------------------------
  // Stage-3 combinational: rounding adders + final assembly
  // ---------------------------------------------------------------------------
  logic [FLEN-1:0]         s3_final_result;
  logic [4:0]              s3_final_fflags;
  logic [FP_S_MANT_W+1:0]  s_rounded;
  logic [FP_D_MANT_W+1:0]  d_rounded;
  logic [FP_S_TOTAL_W-1:0] s_bits;
  logic [FP_D_TOTAL_W-1:0] d_bits;
  logic [FLEN-1:0]         ifp_result;
  logic [4:0]              ifp_fflags;
  logic [XLEN:0]           int_rounded;
  logic [XLEN-1:0]         mag;
  logic                    over_after_round;
  logic [XLEN-1:0]         signed_val;
  logic [XLEN-1:0]         fpi_result;
  logic [4:0]              fpi_fflags;

  // ---------------------------------------------------------------------------
  // Stage-1 combinational logic
  // ---------------------------------------------------------------------------
  always_comb begin
    s1_src_is_single = 1'b0;
    s1_a_d           = a_i;

    unique case (op_i)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: s1_src_is_single = ~fmt_d_i;
      FP_FCVT_D_S:  s1_src_is_single = 1'b1;
      default:      s1_src_is_single = 1'b0;
    endcase

    if (s1_src_is_single) begin
      if (a_i[FLEN-1 -: FP_S_TOTAL_W] == FP_NANBOX_UPPER) begin
        s1_a_d = {{(FLEN-FP_S_TOTAL_W){1'b0}}, a_i[FP_S_TOTAL_W-1:0]};
      end else begin
        s1_a_d = {{(FLEN-FP_S_TOTAL_W){1'b0}}, FP_CANON_QNAN_S};
      end
    end else begin
      s1_a_d = a_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_op_q    <= FP_FCVT_W_F;
      s1_fmt_d_q <= 1'b0;
      s1_rm_q    <= 3'd0;
      s1_a_q     <= {FLEN{1'b0}};
      s1_tag_q   <= '{default: '0};
    end else begin
      s1_valid_q <= flush_i ? 1'b0 : in_valid_i;
      if (in_valid_i) begin
        s1_op_q    <= op_i;
        s1_fmt_d_q <= fmt_d_i;
        s1_rm_q    <= rm_i;
        s1_a_q     <= s1_a_d;
        s1_tag_q   <= tag_i;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: source decomposition (FP->INT and S<->D)
  // ---------------------------------------------------------------------------
  always_comb begin
    src_s       = s1_a_q[FP_S_TOTAL_W-1:0];
    src_d       = s1_a_q;
    src_exp_s   = src_s[FP_S_TOTAL_W-2 -: FP_S_EXP_W];
    src_mant_s  = src_s[FP_S_MANT_W-1:0];
    src_exp_d   = src_d[FP_D_TOTAL_W-2 -: FP_D_EXP_W];
    src_mant_d  = src_d[FP_D_MANT_W-1:0];
    src_sign    = 1'b0;
    src_is_nan  = 1'b0;
    src_is_inf  = 1'b0;
    src_is_zero = 1'b0;
    src_is_s    = 1'b0;

    unique case (s1_op_q)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: src_is_s = ~s1_fmt_d_q;
      FP_FCVT_D_S:  src_is_s = 1'b1;
      FP_FCVT_S_D:  src_is_s = 1'b0;
      default:      src_is_s = 1'b0;
    endcase

    if (src_is_s) begin
      src_sign    = src_s[FP_S_TOTAL_W-1];
      src_is_nan  = (src_exp_s == FP_S_EXP_MAX) && (src_mant_s != {FP_S_MANT_W{1'b0}});
      src_is_inf  = (src_exp_s == FP_S_EXP_MAX) && (src_mant_s == {FP_S_MANT_W{1'b0}});
      src_is_zero = (src_exp_s == {FP_S_EXP_W{1'b0}}) && (src_mant_s == {FP_S_MANT_W{1'b0}});
    end else begin
      src_sign    = src_d[FP_D_TOTAL_W-1];
      src_is_nan  = (src_exp_d == FP_D_EXP_MAX) && (src_mant_d != {FP_D_MANT_W{1'b0}});
      src_is_inf  = (src_exp_d == FP_D_EXP_MAX) && (src_mant_d == {FP_D_MANT_W{1'b0}});
      src_is_zero = (src_exp_d == {FP_D_EXP_W{1'b0}}) && (src_mant_d == {FP_D_MANT_W{1'b0}});
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: FP -> INT (compute int_part and round_up;
  //                                    int_rounded adder deferred to stage 3)
  // ---------------------------------------------------------------------------
  always_comb begin
    sig64            = {XLEN{1'b0}};
    frac_mask        = {XLEN{1'b0}};
    shift_r          = {7{1'b0}};
    frac_bits        = {FP_S_EXP_W{1'b0}};
    unbiased_exp     = {FP_EXP_EXT_W{1'b0}};
    target_max       = {XLEN{1'b0}};
    target_min       = {XLEN{1'b0}};
    target_is_signed = 1'b0;
    target_is_32b    = 1'b0;
    int_part         = {XLEN{1'b0}};
    rnd_g            = 1'b0;
    rnd_s            = 1'b0;
    rnd_lsb          = 1'b0;
    fpi_overflow     = 1'b0;
    fpi_neg_of       = 1'b0;
    fpi_round_up     = 1'b0;
    is_inexact_fpi   = 1'b0;

    if (src_is_s) begin
      unbiased_exp = $signed({5'd0, src_exp_s}) - $signed(FP_EXP_EXT_W'(FP_S_BIAS));
      sig64 = {1'b1, src_mant_s, {(XLEN-1-FP_S_MANT_W){1'b0}}};
    end else begin
      unbiased_exp = $signed({2'd0, src_exp_d}) - $signed(FP_EXP_EXT_W'(FP_D_BIAS));
      sig64 = {1'b1, src_mant_d, {(XLEN-1-FP_D_MANT_W){1'b0}}};
    end

    target_is_signed = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_L_F);
    target_is_32b    = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_WU_F);

    if (target_is_32b && target_is_signed) begin
      target_max = {{(XLEN-INST_W){1'b0}}, 32'h7FFF_FFFF};
      target_min = {{(XLEN-INST_W){1'b1}}, 32'h8000_0000};
    end else if (target_is_32b && !target_is_signed) begin
      target_max = {32'hFFFF_FFFF, 32'hFFFF_FFFF};
      target_min = {XLEN{1'b0}};
    end else if (!target_is_32b && target_is_signed) begin
      target_max = 64'h7FFF_FFFF_FFFF_FFFF;
      target_min = 64'h8000_0000_0000_0000;
    end else begin
      target_max = 64'hFFFF_FFFF_FFFF_FFFF;
      target_min = {XLEN{1'b0}};
    end

    if (src_is_nan) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = 1'b0;
    end else if (src_is_inf) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = src_sign;
    end else if (!src_is_zero) begin
      if (unbiased_exp < 0) begin
        int_part = {XLEN{1'b0}};
        if (unbiased_exp == -13'sd1) begin
          rnd_g = 1'b1;
          rnd_s = |sig64[XLEN-2:0];
        end else begin
          rnd_g = 1'b0;
          rnd_s = 1'b1;
        end
        rnd_lsb = 1'b0;
      end else begin
        if (unbiased_exp >= 13'sd64) begin
          fpi_overflow = 1'b1;
          fpi_neg_of   = src_sign;
        end else begin
          shift_r   = 7'd63 - unbiased_exp[6:0];
          frac_bits = {1'b0, shift_r};
          int_part  = sig64 >> shift_r;
          if (shift_r == 7'd0) begin
            rnd_g = 1'b0; rnd_s = 1'b0;
          end else begin
            rnd_g = sig64[6'(shift_r - 7'd1)];
            if (shift_r >= 7'd2) begin
              frac_mask = (64'd1 << (shift_r - 7'd1)) - 64'd1;
              rnd_s     = |(sig64 & frac_mask);
            end else begin
              rnd_s = 1'b0;
            end
          end
          rnd_lsb = int_part[0];
        end
      end
    end

    if (!fpi_overflow) begin
      unique case (s1_rm_q)
        FP_RM_RNE: fpi_round_up = rnd_g && (rnd_s || rnd_lsb);
        FP_RM_RTZ: fpi_round_up = 1'b0;
        FP_RM_RDN: fpi_round_up = src_sign && (rnd_g || rnd_s);
        FP_RM_RUP: fpi_round_up = !src_sign && (rnd_g || rnd_s);
        FP_RM_RMM: fpi_round_up = rnd_g;
        default:   fpi_round_up = rnd_g && (rnd_s || rnd_lsb);
      endcase
    end

    is_inexact_fpi = rnd_g | rnd_s;
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: INT -> FP (two's complement + CLZ + normalise +
  //                                    pre-round mantissa; rounding deferred)
  // ---------------------------------------------------------------------------
  always_comb begin
    ifp_isneg      = 1'b0;
    ifp_imag       = {XLEN{1'b0}};
    ifp_isigned    = 1'b0;
    ifp_is32       = 1'b0;
    ifp_imag_zero  = 1'b0;
    ifp_lz         = 0;
    ifp_norm       = {XLEN{1'b0}};
    ifp_s_exp      = {FP_S_EXP_W{1'b0}};
    ifp_s_mant_pre = {(FP_S_MANT_W+1){1'b0}};
    s_guard        = 1'b0;
    s_round_sticky = 1'b0;
    s_lsb          = 1'b0;
    ifp_s_round_up = 1'b0;
    ifp_s_inexact  = 1'b0;
    ifp_d_exp      = {FP_D_EXP_W{1'b0}};
    ifp_d_mant_pre = {(FP_D_MANT_W+1){1'b0}};
    d_guard        = 1'b0;
    d_round_sticky = 1'b0;
    d_lsb          = 1'b0;
    ifp_d_round_up = 1'b0;
    ifp_d_inexact  = 1'b0;

    ifp_isigned = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_L);
    ifp_is32    = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_WU);

    if (ifp_is32) begin
      if (ifp_isigned) begin
        ifp_isneg = s1_a_q[INST_W-1];
        ifp_imag = ifp_isneg ? {{(XLEN-INST_W){1'b0}}, (~s1_a_q[INST_W-1:0] + INST_W'(1))}
                              : {{(XLEN-INST_W){1'b0}}, s1_a_q[INST_W-1:0]};
      end else begin
        ifp_isneg = 1'b0;
        ifp_imag = {{(XLEN-INST_W){1'b0}}, s1_a_q[INST_W-1:0]};
      end
    end else begin
      if (ifp_isigned) begin
        ifp_isneg = s1_a_q[XLEN-1];
        ifp_imag = ifp_isneg ? (~s1_a_q + XLEN'(1)) : s1_a_q;  // 8xCARRY8 critical path
      end else begin
        ifp_isneg = 1'b0;
        ifp_imag = s1_a_q;
      end
    end

    ifp_imag_zero = (ifp_imag == {XLEN{1'b0}});

    ifp_lz = clz64(ifp_imag);
    ifp_norm = ifp_imag_zero ? {XLEN{1'b0}} : (ifp_imag << ifp_lz);

    // Single-precision path
    ifp_s_exp      = FP_S_EXP_W'(FP_S_BIAS) + 8'd63 - ifp_lz[FP_S_EXP_W-1:0];
    ifp_s_mant_pre = ifp_norm[XLEN-1 -: (FP_S_MANT_W+1)];   // 24 bits (implicit 1 at [23])
    s_guard        = ifp_norm[XLEN-1-(FP_S_MANT_W+1)];
    s_round_sticky = |ifp_norm[XLEN-2-(FP_S_MANT_W+1):0];
    s_lsb          = ifp_s_mant_pre[0];
    unique case (s1_rm_q)
      FP_RM_RNE: ifp_s_round_up = s_guard && (s_round_sticky || s_lsb);
      FP_RM_RTZ: ifp_s_round_up = 1'b0;
      FP_RM_RDN: ifp_s_round_up = ifp_isneg && (s_guard || s_round_sticky);
      FP_RM_RUP: ifp_s_round_up = !ifp_isneg && (s_guard || s_round_sticky);
      FP_RM_RMM: ifp_s_round_up = s_guard;
      default:   ifp_s_round_up = s_guard && (s_round_sticky || s_lsb);
    endcase
    ifp_s_inexact = s_guard | s_round_sticky;

    // Double-precision path
    ifp_d_exp      = FP_D_EXP_W'(FP_D_BIAS) + 11'd63 - {3'd0, ifp_lz[FP_S_EXP_W-1:0]};
    ifp_d_mant_pre = ifp_norm[XLEN-1 -: (FP_D_MANT_W+1)];   // 53 bits (implicit 1 at [52])
    d_guard        = ifp_norm[XLEN-1-(FP_D_MANT_W+1)];
    d_round_sticky = |ifp_norm[XLEN-2-(FP_D_MANT_W+1):0];
    d_lsb          = ifp_d_mant_pre[0];
    unique case (s1_rm_q)
      FP_RM_RNE: ifp_d_round_up = d_guard && (d_round_sticky || d_lsb);
      FP_RM_RTZ: ifp_d_round_up = 1'b0;
      FP_RM_RDN: ifp_d_round_up = ifp_isneg && (d_guard || d_round_sticky);
      FP_RM_RUP: ifp_d_round_up = !ifp_isneg && (d_guard || d_round_sticky);
      FP_RM_RMM: ifp_d_round_up = d_guard;
      default:   ifp_d_round_up = d_guard && (d_round_sticky || d_lsb);
    endcase
    ifp_d_inexact = d_guard | d_round_sticky;
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: S <-> D format conversion (full result; no long chains)
  // ---------------------------------------------------------------------------
  always_comb begin
    fs_flags        = {5{1'b0}};
    d_result        = {FP_D_TOTAL_W{1'b0}};
    s_result        = {FP_S_TOTAL_W{1'b0}};
    sd_sign         = 1'b0;
    sd_sexp         = {FP_S_EXP_W{1'b0}};
    sd_smant        = {FP_S_MANT_W{1'b0}};
    ds_sign         = 1'b0;
    ds_dexp         = {FP_D_EXP_W{1'b0}};
    ds_dmant        = {FP_D_MANT_W{1'b0}};
    ds_unbiased     = {FP_EXP_EXT_W{1'b0}};
    ds_sexp_out     = {FP_S_EXP_W{1'b0}};
    ds_sig          = {(FP_S_MANT_W+1){1'b0}};
    ds_g            = 1'b0;
    ds_sticky       = 1'b0;
    ds_lsb          = 1'b0;
    ds_round_up     = 1'b0;
    ds_rounded      = {(FP_S_MANT_W+2){1'b0}};
    ds_nz_in        = 1'b0;
    subn_shift_amt  = {10{1'b0}};
    subn_sig24      = {(FP_S_MANT_W+1){1'b0}};
    subn_sig        = {(FP_S_MANT_W+1){1'b0}};
    subn_g          = 1'b0;
    subn_sticky     = 1'b0;
    subn_round_up   = 1'b0;
    subn_rounded    = {(FP_S_MANT_W+1){1'b0}};
    subn_mant       = {FP_S_MANT_W{1'b0}};
    subn_exp        = {FP_S_EXP_W{1'b0}};
    sd_k            = 0;
    sd_m            = {FP_S_MANT_W{1'b0}};
    sd_shift_amt    = 22;
    sd_found_k      = 1'b0;
    sd_new_mant     = {(FP_D_MANT_W+1){1'b0}};
    sd_new_exp      = {FP_D_EXP_W{1'b0}};
    s2c_ds_d        = {FP_D_TOTAL_W{1'b0}};
    s2c_ds_fflags_d = {5{1'b0}};

    if (s1_op_q == FP_FCVT_D_S) begin
      // Single -> Double (exact)
      sd_sign  = s1_a_q[FP_S_TOTAL_W-1];
      sd_sexp  = s1_a_q[FP_S_TOTAL_W-2 -: FP_S_EXP_W];
      sd_smant = s1_a_q[FP_S_MANT_W-1:0];
      if ((sd_sexp == {FP_S_EXP_W{1'b0}}) && (sd_smant == {FP_S_MANT_W{1'b0}})) begin
        d_result = {sd_sign, {(FP_D_TOTAL_W-1){1'b0}}};
      end else if ((sd_sexp == FP_S_EXP_MAX) && (sd_smant == {FP_S_MANT_W{1'b0}})) begin
        d_result = {sd_sign, FP_D_EXP_MAX, {FP_D_MANT_W{1'b0}}};
      end else if (sd_sexp == FP_S_EXP_MAX) begin
        if (sd_smant[FP_S_MANT_W-1] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        d_result = FP_CANON_QNAN_D;
      end else if (sd_sexp == {FP_S_EXP_W{1'b0}}) begin
        sd_m         = sd_smant;
        sd_found_k   = 1'b0;
        sd_shift_amt = 22;
        for (sd_k = 22; sd_k >= 0; sd_k = sd_k - 1) begin
          if (sd_m[sd_k] && !sd_found_k) begin
            sd_shift_amt = 22 - sd_k;
            sd_found_k   = 1'b1;
          end
        end
        sd_new_mant = {sd_m, {(FP_D_MANT_W+1-FP_S_MANT_W){1'b0}}} << sd_shift_amt;
        sd_new_exp  = FP_D_EXP_W'(FP_D_BIAS - FP_S_BIAS) - sd_shift_amt[FP_D_EXP_W-1:0];
        d_result    = {sd_sign, sd_new_exp, sd_new_mant[FP_D_MANT_W-1:0]};
      end else begin
        d_result = {sd_sign, ({3'd0, sd_sexp} + FP_D_EXP_W'(FP_D_BIAS - FP_S_BIAS)),
                    sd_smant, {(FP_D_MANT_W-FP_S_MANT_W){1'b0}}};
      end
      s2c_ds_d        = d_result;
      s2c_ds_fflags_d = fs_flags;
    end else begin
      // FP_FCVT_S_D: Double -> Single with rounding
      ds_sign     = s1_a_q[FP_D_TOTAL_W-1];
      ds_dexp     = s1_a_q[FP_D_TOTAL_W-2 -: FP_D_EXP_W];
      ds_dmant    = s1_a_q[FP_D_MANT_W-1:0];
      ds_unbiased = $signed({2'd0, ds_dexp}) - $signed(FP_EXP_EXT_W'(FP_D_BIAS));

      if ((ds_dexp == {FP_D_EXP_W{1'b0}}) && (ds_dmant == {FP_D_MANT_W{1'b0}})) begin
        s_result = {ds_sign, {(FP_S_TOTAL_W-1){1'b0}}};
      end else if ((ds_dexp == FP_D_EXP_MAX) && (ds_dmant == {FP_D_MANT_W{1'b0}})) begin
        s_result = {ds_sign, FP_S_EXP_MAX, {FP_S_MANT_W{1'b0}}};
      end else if (ds_dexp == FP_D_EXP_MAX) begin
        if (ds_dmant[FP_D_MANT_W-1] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        s_result = FP_CANON_QNAN_S;
      end else begin
        if (ds_dexp == {FP_D_EXP_W{1'b0}}) begin
          ds_nz_in = |ds_dmant;
          unique case (s1_rm_q)
            FP_RM_RDN: s_result = (ds_sign  && ds_nz_in)
                                  ? {1'b1, {FP_S_EXP_W{1'b0}}, {(FP_S_MANT_W-1){1'b0}}, 1'b1}
                                  : {ds_sign, {(FP_S_TOTAL_W-1){1'b0}}};
            FP_RM_RUP: s_result = (!ds_sign && ds_nz_in)
                                  ? {1'b0, {FP_S_EXP_W{1'b0}}, {(FP_S_MANT_W-1){1'b0}}, 1'b1}
                                  : {ds_sign, {(FP_S_TOTAL_W-1){1'b0}}};
            default:   s_result = {ds_sign, {(FP_S_TOTAL_W-1){1'b0}}};
          endcase
          if (ds_nz_in) begin
            fs_flags[FP_FFLAG_UF] = 1'b1;
            fs_flags[FP_FFLAG_NX] = 1'b1;
          end
        end else if (ds_unbiased > $signed(FP_EXP_EXT_W'(FP_S_BIAS))) begin
          fs_flags[FP_FFLAG_OF] = 1'b1;
          fs_flags[FP_FFLAG_NX] = 1'b1;
          unique case (s1_rm_q)
            FP_RM_RTZ: s_result = {ds_sign, FP_S_EXP_PENULT, 23'h7FFFFF};
            FP_RM_RDN: s_result = ds_sign ? {1'b1, FP_S_EXP_MAX, {FP_S_MANT_W{1'b0}}}
                                          : {1'b0, FP_S_EXP_PENULT, 23'h7FFFFF};
            FP_RM_RUP: s_result = ds_sign ? {1'b1, FP_S_EXP_PENULT, 23'h7FFFFF}
                                          : {1'b0, FP_S_EXP_MAX, {FP_S_MANT_W{1'b0}}};
            default:   s_result = {ds_sign, FP_S_EXP_MAX, {FP_S_MANT_W{1'b0}}};
          endcase
        end else if (ds_unbiased < $signed(FP_EXP_EXT_W'(FP_S_EMIN_NORM))) begin
          subn_shift_amt = 10'(-(ds_unbiased + $signed(FP_EXP_EXT_W'(-FP_S_EMIN_NORM))));
          subn_sig24     = {1'b1, ds_dmant[FP_D_MANT_W-1 -: FP_S_MANT_W]};

          if (subn_shift_amt >= 10'd25) begin
            subn_sig    = {(FP_S_MANT_W+1){1'b0}};
            subn_g      = 1'b0;
            subn_sticky = (subn_sig24 != {(FP_S_MANT_W+1){1'b0}})
                          | (|ds_dmant[FP_D_MANT_W-FP_S_MANT_W-1:0]);
          end else begin
            subn_sig    = subn_sig24 >> subn_shift_amt;
            subn_g      = (subn_shift_amt == 10'd0)
                          ? 1'b0
                          : subn_sig24[subn_shift_amt[4:0] - 5'd1];
            subn_sticky = (subn_shift_amt < 10'd2)
                          ? (|ds_dmant[FP_D_MANT_W-FP_S_MANT_W-1:0])
                          : (|(subn_sig24
                                 & ((24'd1 << (subn_shift_amt - 10'd1)) - 24'd1)))
                            | (|ds_dmant[FP_D_MANT_W-FP_S_MANT_W-1:0]);
          end

          unique case (s1_rm_q)
            FP_RM_RNE: subn_round_up = subn_g && (subn_sticky || subn_sig[0]);
            FP_RM_RTZ: subn_round_up = 1'b0;
            FP_RM_RDN: subn_round_up = ds_sign && (subn_g || subn_sticky);
            FP_RM_RUP: subn_round_up = !ds_sign && (subn_g || subn_sticky);
            FP_RM_RMM: subn_round_up = subn_g;
            default:   subn_round_up = subn_g && (subn_sticky || subn_sig[0]);
          endcase

          subn_rounded = subn_sig + (subn_round_up ? 24'd1 : 24'd0);
          if (subn_g | subn_sticky) fs_flags[FP_FFLAG_NX] = 1'b1;

          if (subn_rounded[FP_S_MANT_W]) begin
            subn_mant = {FP_S_MANT_W{1'b0}};
            subn_exp  = 8'd1;
          end else begin
            subn_mant = subn_rounded[FP_S_MANT_W-1:0];
            subn_exp  = {FP_S_EXP_W{1'b0}};
          end
          s_result = {ds_sign, subn_exp, subn_mant};

          if ((subn_g | subn_sticky) && (subn_exp == {FP_S_EXP_W{1'b0}}))
            fs_flags[FP_FFLAG_UF] = 1'b1;
        end else begin
          // Normal range: round 52-bit mantissa to 23 bits
          ds_sig    = {1'b1, ds_dmant[FP_D_MANT_W-1 -: FP_S_MANT_W]};
          ds_g      = ds_dmant[FP_D_MANT_W-FP_S_MANT_W-1];
          ds_sticky = |ds_dmant[FP_D_MANT_W-FP_S_MANT_W-2:0];
          ds_lsb    = ds_sig[0];
          unique case (s1_rm_q)
            FP_RM_RNE: ds_round_up = ds_g && (ds_sticky || ds_lsb);
            FP_RM_RTZ: ds_round_up = 1'b0;
            FP_RM_RDN: ds_round_up = ds_sign && (ds_g || ds_sticky);
            FP_RM_RUP: ds_round_up = !ds_sign && (ds_g || ds_sticky);
            FP_RM_RMM: ds_round_up = ds_g;
            default:   ds_round_up = ds_g && (ds_sticky || ds_lsb);
          endcase
          ds_rounded = {1'b0, ds_sig} + (ds_round_up ? 25'd1 : 25'd0);
          if (ds_g || ds_sticky) fs_flags[FP_FFLAG_NX] = 1'b1;

          ds_sexp_out = ds_unbiased[FP_S_EXP_W-1:0] + FP_S_EXP_W'(FP_S_BIAS);
          if (ds_rounded[FP_S_MANT_W+1]) begin
            if ((ds_sexp_out + 8'd1) == FP_S_EXP_MAX) begin
              s_result = {ds_sign, FP_S_EXP_MAX, {FP_S_MANT_W{1'b0}}};
              fs_flags[FP_FFLAG_OF] = 1'b1;
            end else begin
              s_result = {ds_sign, ds_sexp_out + 8'd1, {FP_S_MANT_W{1'b0}}};
            end
          end else begin
            s_result = {ds_sign, ds_sexp_out, ds_rounded[FP_S_MANT_W-1:0]};
          end
        end
      end
      s2c_ds_d        = {FP_NANBOX_UPPER, s_result};
      s2c_ds_fflags_d = fs_flags;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 registers: capture intermediate values
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid_q <= 1'b0;
      s2_op_q    <= FP_FCVT_W_F;
      s2_fmt_d_q <= 1'b0;
      s2_tag_q   <= '{default: '0};

      s2_ifp_isneg_q      <= 1'b0;
      s2_ifp_imag_zero_q  <= 1'b0;
      s2_ifp_s_exp_q      <= {FP_S_EXP_W{1'b0}};
      s2_ifp_d_exp_q      <= {FP_D_EXP_W{1'b0}};
      s2_ifp_s_mant_pre_q <= {(FP_S_MANT_W+1){1'b0}};
      s2_ifp_d_mant_pre_q <= {(FP_D_MANT_W+1){1'b0}};
      s2_ifp_s_round_up_q <= 1'b0;
      s2_ifp_d_round_up_q <= 1'b0;
      s2_ifp_s_inexact_q  <= 1'b0;
      s2_ifp_d_inexact_q  <= 1'b0;

      s2_fpi_overflow_q         <= 1'b0;
      s2_fpi_neg_of_q           <= 1'b0;
      s2_fpi_src_is_nan_q       <= 1'b0;
      s2_fpi_src_sign_q         <= 1'b0;
      s2_fpi_target_is_32b_q    <= 1'b0;
      s2_fpi_target_is_signed_q <= 1'b0;
      s2_fpi_target_max_q       <= {XLEN{1'b0}};
      s2_fpi_target_min_q       <= {XLEN{1'b0}};
      s2_fpi_int_part_q         <= {XLEN{1'b0}};
      s2_fpi_round_up_q         <= 1'b0;
      s2_fpi_is_inexact_q       <= 1'b0;

      s2_ds_result_q <= {FP_D_TOTAL_W{1'b0}};
      s2_ds_fflags_q <= {5{1'b0}};
    end else begin
      s2_valid_q <= flush_i ? 1'b0 : s1_valid_q;
      if (s1_valid_q) begin
        s2_op_q    <= s1_op_q;
        s2_fmt_d_q <= s1_fmt_d_q;
        s2_tag_q   <= s1_tag_q;

        s2_ifp_isneg_q      <= ifp_isneg;
        s2_ifp_imag_zero_q  <= ifp_imag_zero;
        s2_ifp_s_exp_q      <= ifp_s_exp;
        s2_ifp_d_exp_q      <= ifp_d_exp;
        s2_ifp_s_mant_pre_q <= ifp_s_mant_pre;
        s2_ifp_d_mant_pre_q <= ifp_d_mant_pre;
        s2_ifp_s_round_up_q <= ifp_s_round_up;
        s2_ifp_d_round_up_q <= ifp_d_round_up;
        s2_ifp_s_inexact_q  <= ifp_s_inexact;
        s2_ifp_d_inexact_q  <= ifp_d_inexact;

        s2_fpi_overflow_q         <= fpi_overflow;
        s2_fpi_neg_of_q           <= fpi_neg_of;
        s2_fpi_src_is_nan_q       <= src_is_nan;
        s2_fpi_src_sign_q         <= src_sign;
        s2_fpi_target_is_32b_q    <= target_is_32b;
        s2_fpi_target_is_signed_q <= target_is_signed;
        s2_fpi_target_max_q       <= target_max;
        s2_fpi_target_min_q       <= target_min;
        s2_fpi_int_part_q         <= int_part;
        s2_fpi_round_up_q         <= fpi_round_up;
        s2_fpi_is_inexact_q       <= is_inexact_fpi;

        s2_ds_result_q <= s2c_ds_d;
        s2_ds_fflags_q <= s2c_ds_fflags_d;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-3 combinational: rounding adders + final assembly
  // ---------------------------------------------------------------------------
  always_comb begin
    s_rounded        = {(FP_S_MANT_W+2){1'b0}};
    d_rounded        = {(FP_D_MANT_W+2){1'b0}};
    s_bits           = {FP_S_TOTAL_W{1'b0}};
    d_bits           = {FP_D_TOTAL_W{1'b0}};
    ifp_result       = {FLEN{1'b0}};
    ifp_fflags       = {5{1'b0}};
    int_rounded      = {(XLEN+1){1'b0}};
    mag              = {XLEN{1'b0}};
    over_after_round = 1'b0;
    signed_val       = {XLEN{1'b0}};
    fpi_result       = {XLEN{1'b0}};
    fpi_fflags       = {5{1'b0}};
    s3_final_result  = {FLEN{1'b0}};
    s3_final_fflags  = {5{1'b0}};

    // --- INT -> FP rounding (7xCARRY8 for double; 4xCARRY8 for single) ---
    s_rounded = {1'b0, s2_ifp_s_mant_pre_q} + (s2_ifp_s_round_up_q ? 25'd1 : 25'd0);
    d_rounded = {1'b0, s2_ifp_d_mant_pre_q} + (s2_ifp_d_round_up_q ? 54'd1 : 54'd0);

    if (s2_ifp_imag_zero_q) begin
      s_bits = {s2_ifp_isneg_q, {(FP_S_TOTAL_W-1){1'b0}}};
      d_bits = {FP_D_TOTAL_W{1'b0}};
    end else begin
      if (s_rounded[FP_S_MANT_W+1]) begin
        s_bits = {s2_ifp_isneg_q, s2_ifp_s_exp_q + 8'd1, {FP_S_MANT_W{1'b0}}};
      end else begin
        s_bits = {s2_ifp_isneg_q, s2_ifp_s_exp_q, s_rounded[FP_S_MANT_W-1:0]};
      end
      if (d_rounded[FP_D_MANT_W+1]) begin
        d_bits = {s2_ifp_isneg_q, s2_ifp_d_exp_q + 11'd1, {FP_D_MANT_W{1'b0}}};
      end else begin
        d_bits = {s2_ifp_isneg_q, s2_ifp_d_exp_q, d_rounded[FP_D_MANT_W-1:0]};
      end
    end

    if (s2_fmt_d_q) begin
      ifp_result = d_bits;
      if (!s2_ifp_imag_zero_q && s2_ifp_d_inexact_q) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end else begin
      ifp_result = {FP_NANBOX_UPPER, s_bits};
      if (!s2_ifp_imag_zero_q && s2_ifp_s_inexact_q) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end

    // --- FP -> INT rounding (65-bit conditional increment + sign + range check) ---

    int_rounded = {1'b0, s2_fpi_int_part_q} + (s2_fpi_round_up_q ? 65'd1 : 65'd0);
    mag         = int_rounded[XLEN-1:0];

    if (s2_fpi_src_is_nan_q) begin
      fpi_result               = s2_fpi_target_max_q;
      fpi_fflags[FP_FFLAG_NV]  = 1'b1;
    end else if (s2_fpi_overflow_q) begin
      if (s2_fpi_neg_of_q) fpi_result = s2_fpi_target_is_signed_q ? s2_fpi_target_min_q
                                                                  : {XLEN{1'b0}};
      else                 fpi_result = s2_fpi_target_max_q;
      fpi_fflags[FP_FFLAG_NV] = 1'b1;
    end else begin
      if (s2_fpi_target_is_32b_q && s2_fpi_target_is_signed_q) begin
        if (s2_fpi_src_sign_q) begin
          if (int_rounded > 65'h0_0000_0000_8000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_0000_0000_7FFF_FFFF) over_after_round = 1'b1;
        end
      end else if (s2_fpi_target_is_32b_q && !s2_fpi_target_is_signed_q) begin
        if (s2_fpi_src_sign_q && (mag != {XLEN{1'b0}} || s2_fpi_round_up_q)) begin
          over_after_round = 1'b1;
        end else if (int_rounded > 65'h0_0000_0000_FFFF_FFFF) begin
          over_after_round = 1'b1;
        end
      end else if (!s2_fpi_target_is_32b_q && s2_fpi_target_is_signed_q) begin
        if (s2_fpi_src_sign_q) begin
          if (int_rounded > 65'h0_8000_0000_0000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_7FFF_FFFF_FFFF_FFFF) over_after_round = 1'b1;
        end
      end else begin
        if (s2_fpi_src_sign_q && (mag != {XLEN{1'b0}} || s2_fpi_round_up_q)) begin
          over_after_round = 1'b1;
        end else if (int_rounded[XLEN]) begin
          // verilator coverage_off
          over_after_round = 1'b1;
          // verilator coverage_on
        end
      end

      if (over_after_round) begin
        if (s2_fpi_src_sign_q) fpi_result = s2_fpi_target_is_signed_q ? s2_fpi_target_min_q
                                                                      : {XLEN{1'b0}};
        else                   fpi_result = s2_fpi_target_max_q;
        fpi_fflags[FP_FFLAG_NV] = 1'b1;
      end else begin
        signed_val = s2_fpi_src_sign_q ? (~mag + XLEN'(1)) : mag;
        if (s2_fpi_target_is_32b_q) begin
          fpi_result = {{(XLEN-INST_W){signed_val[INST_W-1]}}, signed_val[INST_W-1:0]};
        end else begin
          fpi_result = signed_val;
        end
        if (s2_fpi_is_inexact_q) fpi_fflags[FP_FFLAG_NX] = 1'b1;
      end
    end

    // --- Final mux ---
    unique case (s2_op_q)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: begin
        s3_final_result = fpi_result;
        s3_final_fflags = fpi_fflags;
      end
      FP_FCVT_F_W,
      FP_FCVT_F_WU,
      FP_FCVT_F_L,
      FP_FCVT_F_LU: begin
        s3_final_result = ifp_result;
        s3_final_fflags = ifp_fflags;
      end
      FP_FCVT_S_D,
      FP_FCVT_D_S: begin
        s3_final_result = s2_ds_result_q;
        s3_final_fflags = s2_ds_fflags_q;
      end
      default: begin
        s3_final_result = {FLEN{1'b0}};
        s3_final_fflags = {5{1'b0}};
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Stage-3 output registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= {FLEN{1'b0}};
      fflags_o    <= {5{1'b0}};
      tag_o       <= '{default: '0};
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s2_valid_q;
      if (s2_valid_q) begin
        result_o <= s3_final_result;
        fflags_o <= s3_final_fflags;
        tag_o    <= s2_tag_q;
      end
    end
  end

endmodule
