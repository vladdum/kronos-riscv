// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FCVT unit: integer<->FP conversions (W/WU/L/LU) and S<->D format conversion.
// 3-stage pipelined. Latency = 3 cycles.
//
// Pipeline split:
//   Stage 1: NaN-unbox single-precision inputs.
//   Stage 2: INT->FP negation (8×CARRY8) + CLZ + normalise + pre-round mantissa.
//            FP->INT shift + guard/sticky/round_up (before the 65-bit adder).
//            S<->D full conversion (no long carry chains; result registered here).
//   Stage 3: Rounding adders (INT->FP 54-bit, FP->INT 65-bit), sign, range-check.
//            This breaks the 15×CARRY8 chain that limited Fmax at 200 MHz.

module kronos_fpu_fcvt
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
  input  logic [63:0] b_i,     // unused
  input  logic [63:0] c_i,     // unused
  input  fpu_tag_t    tag_i,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // ---------------------------------------------------------------------------
  // Helper: count leading zeros (parameterised)
  // ---------------------------------------------------------------------------
  function automatic integer clz64(input logic [63:0] x);
    integer i;
    clz64 = 64;
    for (i = 63; i >= 0; i = i - 1) begin
      if (x[i]) begin
        // verilator coverage_off
        clz64 = 63 - i;
        break;
        // verilator coverage_on
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Stage-1 registers (latched inputs + NaN-unboxed operand)
  // ---------------------------------------------------------------------------
  logic        s1_valid_q;
  fp_op_e      s1_op_q;
  logic        s1_fmt_d_q;
  logic [2:0]  s1_rm_q;
  logic [63:0] s1_a_q;
  fpu_tag_t    s1_tag_q;

  // ---------------------------------------------------------------------------
  // Stage-1 combinational (NaN-unbox single-precision inputs)
  // ---------------------------------------------------------------------------
  logic [63:0] s1_a_next;
  logic        s1_src_is_single;

  always_comb begin
    s1_src_is_single = 1'b0;
    unique case (op_i)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: s1_src_is_single = ~fmt_d_i;
      FP_FCVT_D_S:  s1_src_is_single = 1'b1;
      default:      s1_src_is_single = 1'b0;
    endcase

    if (s1_src_is_single) begin
      if (a_i[63:32] == FP_NANBOX_UPPER)
        s1_a_next = {32'h0, a_i[31:0]};
      else
        s1_a_next = {32'h0, FP_CANON_QNAN_S};
    end else begin
      s1_a_next = a_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_op_q    <= FP_FCVT_W_F;
      s1_fmt_d_q <= 1'b0;
      s1_rm_q    <= 3'd0;
      s1_a_q     <= '0;
      s1_tag_q   <= '0;
    end else begin
      s1_valid_q <= flush_i ? 1'b0 : in_valid_i;
      if (in_valid_i) begin
        s1_op_q    <= op_i;
        s1_fmt_d_q <= fmt_d_i;
        s1_rm_q    <= rm_i;
        s1_a_q     <= s1_a_next;
        s1_tag_q   <= tag_i;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 registers
  // ---------------------------------------------------------------------------
  logic     s2_valid_q;
  fp_op_e   s2_op_q;
  logic     s2_fmt_d_q;
  fpu_tag_t s2_tag_q;

  // INT->FP intermediate (carry chain before the rounding adder)
  logic        s2_ifp_isneg;
  logic        s2_ifp_imag_zero;
  logic [7:0]  s2_ifp_s_exp;
  logic [10:0] s2_ifp_d_exp;
  logic [23:0] s2_ifp_s_mant_pre;  // 24 bits: implicit 1 + 23 fractional
  logic [52:0] s2_ifp_d_mant_pre;  // 53 bits: implicit 1 + 52 fractional
  logic        s2_ifp_s_round_up;
  logic        s2_ifp_d_round_up;
  logic        s2_ifp_s_inexact;
  logic        s2_ifp_d_inexact;

  // FP->INT intermediate (before the 65-bit rounding adder)
  logic        s2_fpi_overflow;
  logic        s2_fpi_neg_of;
  logic        s2_fpi_src_is_nan;
  logic        s2_fpi_src_sign;
  logic        s2_fpi_target_is_32b;
  logic        s2_fpi_target_is_signed;
  logic [63:0] s2_fpi_target_max;
  logic [63:0] s2_fpi_target_min;
  logic [63:0] s2_fpi_int_part;
  logic        s2_fpi_round_up;
  logic        s2_fpi_is_inexact;

  // S<->D full result (no long carry chains; computed and registered in stage 2)
  logic [63:0] s2_ds_result;
  logic [4:0]  s2_ds_fflags;

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: source decomposition (FP->INT and S<->D)
  // ---------------------------------------------------------------------------
  logic        src_sign;
  logic        src_is_s;
  logic [31:0] src_s;
  logic [63:0] src_d;
  logic [10:0] src_exp_d;
  logic [51:0] src_mant_d;
  logic [7:0]  src_exp_s;
  logic [22:0] src_mant_s;
  logic        src_is_nan;
  logic        src_is_inf;
  logic        src_is_zero;

  always_comb begin
    src_s      = s1_a_q[31:0];
    src_d      = s1_a_q;
    src_exp_s  = src_s[30:23];
    src_mant_s = src_s[22:0];
    src_exp_d  = src_d[62:52];
    src_mant_d = src_d[51:0];

    src_is_s = 1'b0;
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
      src_sign    = src_s[31];
      src_is_nan  = (src_exp_s == 8'hFF) && (src_mant_s != 23'd0);
      src_is_inf  = (src_exp_s == 8'hFF) && (src_mant_s == 23'd0);
      src_is_zero = (src_exp_s == 8'd0)  && (src_mant_s == 23'd0);
    end else begin
      src_sign    = src_d[63];
      src_is_nan  = (src_exp_d == 11'h7FF) && (src_mant_d != 52'd0);
      src_is_inf  = (src_exp_d == 11'h7FF) && (src_mant_d == 52'd0);
      src_is_zero = (src_exp_d == 11'd0)   && (src_mant_d == 52'd0);
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: FP -> INT (compute int_part and round_up;
  //                                    int_rounded adder deferred to stage 3)
  // ---------------------------------------------------------------------------
  logic signed [12:0] unbiased_exp;
  logic [63:0]  int_part;
  logic         rnd_g, rnd_s, rnd_lsb;
  logic         fpi_round_up;
  logic         is_inexact_fpi;
  logic [63:0]  target_max, target_min;
  logic         target_is_signed;
  logic         target_is_32b;
  logic         fpi_overflow;
  logic         fpi_neg_of;

  always_comb begin
    logic [63:0] sig64;
    logic [63:0] frac_mask;
    logic [6:0]  shift_r;
    logic [7:0]  frac_bits;

    sig64     = '0;
    frac_mask = '0;
    shift_r   = '0;
    frac_bits = '0;

    if (src_is_s) begin
      unbiased_exp = $signed({5'd0, src_exp_s}) - 13'sd127;
      sig64 = {1'b1, src_mant_s, 40'd0};
    end else begin
      unbiased_exp = $signed({2'd0, src_exp_d}) - 13'sd1023;
      sig64 = {1'b1, src_mant_d, 11'd0};
    end

    target_is_signed = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_L_F);
    target_is_32b    = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_WU_F);

    if (target_is_32b && target_is_signed) begin
      target_max = {{32{1'b0}}, 32'h7FFF_FFFF};
      target_min = {{32{1'b1}}, 32'h8000_0000};
    end else if (target_is_32b && !target_is_signed) begin
      target_max = {32'hFFFF_FFFF, 32'hFFFF_FFFF};
      target_min = 64'd0;
    end else if (!target_is_32b && target_is_signed) begin
      target_max = 64'h7FFF_FFFF_FFFF_FFFF;
      target_min = 64'h8000_0000_0000_0000;
    end else begin
      target_max = 64'hFFFF_FFFF_FFFF_FFFF;
      target_min = 64'd0;
    end

    int_part     = '0;
    rnd_g        = 1'b0;
    rnd_s        = 1'b0;
    rnd_lsb      = 1'b0;
    fpi_overflow = 1'b0;
    fpi_neg_of   = 1'b0;

    if (src_is_nan) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = 1'b0;
    end else if (src_is_inf) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = src_sign;
    end else if (!src_is_zero) begin
      if (unbiased_exp < 0) begin
        int_part = '0;
        if (unbiased_exp == -13'sd1) begin
          rnd_g = 1'b1;
          rnd_s = |sig64[62:0];
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
          if (shift_r == 0) begin
            rnd_g = 1'b0; rnd_s = 1'b0;
          end else begin
            rnd_g = sig64[shift_r - 1];
            if (shift_r >= 2) begin
              frac_mask = (64'd1 << (shift_r - 1)) - 64'd1;
              rnd_s     = |(sig64 & frac_mask);
            end else begin
              rnd_s = 1'b0;
            end
          end
          rnd_lsb = int_part[0];
        end
      end
    end

    fpi_round_up = 1'b0;
    if (!fpi_overflow) begin
      unique case (s1_rm_q)
        3'b000: fpi_round_up = rnd_g && (rnd_s || rnd_lsb);
        3'b001: fpi_round_up = 1'b0;
        3'b010: fpi_round_up = src_sign && (rnd_g || rnd_s);
        3'b011: fpi_round_up = !src_sign && (rnd_g || rnd_s);
        3'b100: fpi_round_up = rnd_g;
        default: fpi_round_up = rnd_g && (rnd_s || rnd_lsb);
      endcase
    end

    is_inexact_fpi = rnd_g | rnd_s;
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: INT -> FP (two's complement + CLZ + normalise +
  //                                    pre-round mantissa; rounding deferred)
  // ---------------------------------------------------------------------------
  logic        ifp_isneg;
  logic        ifp_imag_zero;
  logic [7:0]  ifp_s_exp;
  logic [10:0] ifp_d_exp;
  logic [23:0] ifp_s_mant_pre;
  logic [52:0] ifp_d_mant_pre;
  logic        ifp_s_round_up;
  logic        ifp_d_round_up;
  logic        ifp_s_inexact;
  logic        ifp_d_inexact;

  always_comb begin
    logic [63:0] imag;
    logic        isigned;
    logic        is32;
    logic [63:0] norm;
    integer      lz;
    logic        s_guard, s_round_sticky, s_lsb;
    logic        d_guard, d_round_sticky, d_lsb;

    isigned = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_L);
    is32    = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_WU);

    if (is32) begin
      if (isigned) begin
        ifp_isneg = s1_a_q[31];
        imag = ifp_isneg ? {32'd0, (~s1_a_q[31:0] + 32'd1)} : {32'd0, s1_a_q[31:0]};
      end else begin
        ifp_isneg = 1'b0;
        imag = {32'd0, s1_a_q[31:0]};
      end
    end else begin
      if (isigned) begin
        ifp_isneg = s1_a_q[63];
        imag = ifp_isneg ? (~s1_a_q + 64'd1) : s1_a_q;  // 8×CARRY8 critical path
      end else begin
        ifp_isneg = 1'b0;
        imag = s1_a_q;
      end
    end

    ifp_imag_zero = (imag == 64'd0);

    lz = clz64(imag);
    norm = ifp_imag_zero ? 64'd0 : (imag << lz);

    // Single-precision path
    ifp_s_exp      = 8'd127 + 8'd63 - lz[7:0];
    ifp_s_mant_pre = norm[63:40];   // 24 bits (implicit 1 at [23])
    s_guard        = norm[39];
    s_round_sticky = |norm[38:0];
    s_lsb          = ifp_s_mant_pre[0];
    ifp_s_round_up = 1'b0;
    unique case (s1_rm_q)
      3'b000: ifp_s_round_up = s_guard && (s_round_sticky || s_lsb);
      3'b001: ifp_s_round_up = 1'b0;
      3'b010: ifp_s_round_up = ifp_isneg && (s_guard || s_round_sticky);
      3'b011: ifp_s_round_up = !ifp_isneg && (s_guard || s_round_sticky);
      3'b100: ifp_s_round_up = s_guard;
      default: ifp_s_round_up = s_guard && (s_round_sticky || s_lsb);
    endcase
    ifp_s_inexact = s_guard | s_round_sticky;

    // Double-precision path
    ifp_d_exp      = 11'd1023 + 11'd63 - {3'd0, lz[7:0]};
    ifp_d_mant_pre = norm[63:11];   // 53 bits (implicit 1 at [52])
    d_guard        = norm[10];
    d_round_sticky = |norm[9:0];
    d_lsb          = ifp_d_mant_pre[0];
    ifp_d_round_up = 1'b0;
    unique case (s1_rm_q)
      3'b000: ifp_d_round_up = d_guard && (d_round_sticky || d_lsb);
      3'b001: ifp_d_round_up = 1'b0;
      3'b010: ifp_d_round_up = ifp_isneg && (d_guard || d_round_sticky);
      3'b011: ifp_d_round_up = !ifp_isneg && (d_guard || d_round_sticky);
      3'b100: ifp_d_round_up = d_guard;
      default: ifp_d_round_up = d_guard && (d_round_sticky || d_lsb);
    endcase
    ifp_d_inexact = d_guard | d_round_sticky;
  end

  // ---------------------------------------------------------------------------
  // Stage-2 combinational: S <-> D format conversion (full result; no long chains)
  // ---------------------------------------------------------------------------
  logic [63:0] s2c_ds_result;
  logic [4:0]  s2c_ds_fflags;

  always_comb begin
    logic [63:0] d_result;
    logic [31:0] s_result;
    logic [4:0]  fs_flags;
    logic        sd_sign;
    logic [7:0]  sd_sexp;
    logic [22:0] sd_smant;
    // D->S
    logic        ds_sign;
    logic [10:0] ds_dexp;
    logic [51:0] ds_dmant;
    logic signed [12:0] ds_unbiased;
    logic [7:0]  ds_sexp_out;
    logic [23:0] ds_sig;
    logic        ds_g, ds_sticky, ds_lsb, ds_round_up;
    logic [24:0] ds_rounded;
    logic [9:0]  subn_shift_amt;
    logic [23:0] subn_sig24;
    logic [23:0] subn_sig;
    logic        subn_g;
    logic        subn_sticky;
    logic        subn_round_up;
    logic [23:0] subn_rounded;
    logic [22:0] subn_mant;
    logic [7:0]  subn_exp;

    fs_flags = '0;
    d_result = '0;
    s_result = '0;

    if (s1_op_q == FP_FCVT_D_S) begin
      // Single -> Double (exact)
      sd_sign  = s1_a_q[31];
      sd_sexp  = s1_a_q[30:23];
      sd_smant = s1_a_q[22:0];
      if ((sd_sexp == 8'd0) && (sd_smant == 23'd0)) begin
        d_result = {sd_sign, 63'd0};
      end else if ((sd_sexp == 8'hFF) && (sd_smant == 23'd0)) begin
        d_result = {sd_sign, 11'h7FF, 52'd0};
      end else if (sd_sexp == 8'hFF) begin
        if (sd_smant[22] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        d_result = FP_CANON_QNAN_D;
      end else if (sd_sexp == 8'd0) begin
        integer k;
        logic [22:0] m;
        integer shift_amt;
        m = sd_smant;
        shift_amt = 22;
        for (k = 22; k >= 0; k = k - 1) begin
          if (m[k]) begin
            // verilator coverage_off
            shift_amt = 22 - k;
            break;
            // verilator coverage_on
          end
        end
        begin
          logic [52:0] new_mant;
          logic [10:0] new_exp;
          new_mant = {m, 30'd0} << shift_amt;
          new_exp  = 11'd896 - shift_amt[10:0];
          d_result = {sd_sign, new_exp, new_mant[51:0]};
        end
      end else begin
        d_result = {sd_sign, ({3'd0, sd_sexp} + 11'd896), sd_smant, 29'd0};
      end
      s2c_ds_result = d_result;
      s2c_ds_fflags = fs_flags;
    end else begin
      // FP_FCVT_S_D: Double -> Single with rounding
      ds_sign    = s1_a_q[63];
      ds_dexp    = s1_a_q[62:52];
      ds_dmant   = s1_a_q[51:0];
      ds_unbiased = $signed({2'd0, ds_dexp}) - 13'sd1023;

      if ((ds_dexp == 11'd0) && (ds_dmant == 52'd0)) begin
        s_result = {ds_sign, 31'd0};
      end else if ((ds_dexp == 11'h7FF) && (ds_dmant == 52'd0)) begin
        s_result = {ds_sign, 8'hFF, 23'd0};
      end else if (ds_dexp == 11'h7FF) begin
        if (ds_dmant[51] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        s_result = FP_CANON_QNAN_S;
      end else begin
        if (ds_dexp == 11'd0) begin
          logic nz_in;
          nz_in = |ds_dmant;
          unique case (s1_rm_q)
            3'b010: s_result = (ds_sign  && nz_in) ? {1'b1, 8'd0, 23'd1}
                                                    : {ds_sign, 31'd0};
            3'b011: s_result = (!ds_sign && nz_in) ? {1'b0, 8'd0, 23'd1}
                                                    : {ds_sign, 31'd0};
            default: s_result = {ds_sign, 31'd0};
          endcase
          if (nz_in) begin
            fs_flags[FP_FFLAG_UF] = 1'b1;
            fs_flags[FP_FFLAG_NX] = 1'b1;
          end
        end else if (ds_unbiased > 13'sd127) begin
          fs_flags[FP_FFLAG_OF] = 1'b1;
          fs_flags[FP_FFLAG_NX] = 1'b1;
          unique case (s1_rm_q)
            3'b001: s_result = {ds_sign, 8'hFE, 23'h7FFFFF};
            3'b010: s_result = ds_sign ? {1'b1, 8'hFF, 23'd0} : {1'b0, 8'hFE, 23'h7FFFFF};
            3'b011: s_result = ds_sign ? {1'b1, 8'hFE, 23'h7FFFFF} : {1'b0, 8'hFF, 23'd0};
            default: s_result = {ds_sign, 8'hFF, 23'd0};
          endcase
        end else if (ds_unbiased < -13'sd126) begin
          subn_shift_amt = 10'(-(ds_unbiased + 13'sd126));
          subn_sig24     = {1'b1, ds_dmant[51:29]};

          if (subn_shift_amt >= 10'd25) begin
            subn_sig    = '0;
            subn_g      = 1'b0;
            subn_sticky = (subn_sig24 != 24'd0) | (|ds_dmant[28:0]);
          end else begin
            subn_sig    = subn_sig24 >> subn_shift_amt;
            subn_g      = (subn_shift_amt == 10'd0)
                          ? 1'b0
                          : subn_sig24[subn_shift_amt[4:0] - 5'd1];
            subn_sticky = (subn_shift_amt < 10'd2)
                          ? (|ds_dmant[28:0])
                          : (|(subn_sig24
                                 & ((24'd1 << (subn_shift_amt - 10'd1)) - 24'd1)))
                            | (|ds_dmant[28:0]);
          end

          subn_round_up = 1'b0;
          unique case (s1_rm_q)
            3'b000: subn_round_up = subn_g && (subn_sticky || subn_sig[0]);
            3'b001: subn_round_up = 1'b0;
            3'b010: subn_round_up = ds_sign && (subn_g || subn_sticky);
            3'b011: subn_round_up = !ds_sign && (subn_g || subn_sticky);
            3'b100: subn_round_up = subn_g;
            default: subn_round_up = subn_g && (subn_sticky || subn_sig[0]);
          endcase

          subn_rounded = subn_sig + (subn_round_up ? 24'd1 : 24'd0);
          if (subn_g | subn_sticky) fs_flags[FP_FFLAG_NX] = 1'b1;

          if (subn_rounded[23]) begin
            subn_mant = '0;
            subn_exp  = 8'd1;
          end else begin
            subn_mant = subn_rounded[22:0];
            subn_exp  = 8'd0;
          end
          s_result = {ds_sign, subn_exp, subn_mant};

          if ((subn_g | subn_sticky) && (subn_exp == 8'd0))
            fs_flags[FP_FFLAG_UF] = 1'b1;
        end else begin
          // Normal range: round 52-bit mantissa to 23 bits
          ds_sig    = {1'b1, ds_dmant[51:29]};
          ds_g      = ds_dmant[28];
          ds_sticky = |ds_dmant[27:0];
          ds_lsb    = ds_sig[0];
          ds_round_up = 1'b0;
          unique case (s1_rm_q)
            3'b000: ds_round_up = ds_g && (ds_sticky || ds_lsb);
            3'b001: ds_round_up = 1'b0;
            3'b010: ds_round_up = ds_sign && (ds_g || ds_sticky);
            3'b011: ds_round_up = !ds_sign && (ds_g || ds_sticky);
            3'b100: ds_round_up = ds_g;
            default: ds_round_up = ds_g && (ds_sticky || ds_lsb);
          endcase
          ds_rounded = {1'b0, ds_sig} + (ds_round_up ? 25'd1 : 25'd0);
          if (ds_g || ds_sticky) fs_flags[FP_FFLAG_NX] = 1'b1;

          ds_sexp_out = ds_unbiased[7:0] + 8'd127;
          if (ds_rounded[24]) begin
            if ((ds_sexp_out + 8'd1) == 8'hFF) begin
              s_result = {ds_sign, 8'hFF, 23'd0};
              fs_flags[FP_FFLAG_OF] = 1'b1;
            end else begin
              s_result = {ds_sign, ds_sexp_out + 8'd1, 23'd0};
            end
          end else begin
            s_result = {ds_sign, ds_sexp_out, ds_rounded[22:0]};
          end
        end
      end
      s2c_ds_result = {FP_NANBOX_UPPER, s_result};
      s2c_ds_fflags = fs_flags;
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
      s2_tag_q   <= '0;

      s2_ifp_isneg      <= 1'b0;
      s2_ifp_imag_zero  <= 1'b0;
      s2_ifp_s_exp      <= '0;
      s2_ifp_d_exp      <= '0;
      s2_ifp_s_mant_pre <= '0;
      s2_ifp_d_mant_pre <= '0;
      s2_ifp_s_round_up <= 1'b0;
      s2_ifp_d_round_up <= 1'b0;
      s2_ifp_s_inexact  <= 1'b0;
      s2_ifp_d_inexact  <= 1'b0;

      s2_fpi_overflow        <= 1'b0;
      s2_fpi_neg_of          <= 1'b0;
      s2_fpi_src_is_nan      <= 1'b0;
      s2_fpi_src_sign        <= 1'b0;
      s2_fpi_target_is_32b   <= 1'b0;
      s2_fpi_target_is_signed <= 1'b0;
      s2_fpi_target_max      <= '0;
      s2_fpi_target_min      <= '0;
      s2_fpi_int_part        <= '0;
      s2_fpi_round_up        <= 1'b0;
      s2_fpi_is_inexact      <= 1'b0;

      s2_ds_result <= '0;
      s2_ds_fflags <= '0;
    end else begin
      s2_valid_q <= flush_i ? 1'b0 : s1_valid_q;
      if (s1_valid_q) begin
        s2_op_q    <= s1_op_q;
        s2_fmt_d_q <= s1_fmt_d_q;
        s2_tag_q   <= s1_tag_q;

        s2_ifp_isneg      <= ifp_isneg;
        s2_ifp_imag_zero  <= ifp_imag_zero;
        s2_ifp_s_exp      <= ifp_s_exp;
        s2_ifp_d_exp      <= ifp_d_exp;
        s2_ifp_s_mant_pre <= ifp_s_mant_pre;
        s2_ifp_d_mant_pre <= ifp_d_mant_pre;
        s2_ifp_s_round_up <= ifp_s_round_up;
        s2_ifp_d_round_up <= ifp_d_round_up;
        s2_ifp_s_inexact  <= ifp_s_inexact;
        s2_ifp_d_inexact  <= ifp_d_inexact;

        s2_fpi_overflow        <= fpi_overflow;
        s2_fpi_neg_of          <= fpi_neg_of;
        s2_fpi_src_is_nan      <= src_is_nan;
        s2_fpi_src_sign        <= src_sign;
        s2_fpi_target_is_32b   <= target_is_32b;
        s2_fpi_target_is_signed <= target_is_signed;
        s2_fpi_target_max      <= target_max;
        s2_fpi_target_min      <= target_min;
        s2_fpi_int_part        <= int_part;
        s2_fpi_round_up        <= fpi_round_up;
        s2_fpi_is_inexact      <= is_inexact_fpi;

        s2_ds_result <= s2c_ds_result;
        s2_ds_fflags <= s2c_ds_fflags;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-3 combinational: rounding adders + final assembly
  // ---------------------------------------------------------------------------
  logic [63:0] s3_final_result;
  logic [4:0]  s3_final_fflags;

  always_comb begin
    // All local variable declarations must precede procedural statements.
    logic [24:0] s_rounded;
    logic [53:0] d_rounded;
    logic [31:0] s_bits;
    logic [63:0] d_bits;
    logic [63:0] ifp_result;
    logic [4:0]  ifp_fflags;
    logic [64:0] int_rounded;
    logic [63:0] mag;
    logic        over_after_round;
    logic [63:0] signed_val;
    logic [63:0] fpi_result;
    logic [4:0]  fpi_fflags;

    // Defaults (avoid latch inference)
    signed_val      = '0;
    s3_final_result = '0;
    s3_final_fflags = '0;

    // --- INT -> FP rounding (7×CARRY8 for double; 4×CARRY8 for single) ---
    s_rounded = {1'b0, s2_ifp_s_mant_pre} + (s2_ifp_s_round_up ? 25'd1 : 25'd0);
    d_rounded = {1'b0, s2_ifp_d_mant_pre} + (s2_ifp_d_round_up ? 54'd1 : 54'd0);

    if (s2_ifp_imag_zero) begin
      s_bits = {s2_ifp_isneg, 31'd0};
      d_bits = 64'd0;
    end else begin
      if (s_rounded[24]) begin
        s_bits = {s2_ifp_isneg, s2_ifp_s_exp + 8'd1, 23'd0};
      end else begin
        s_bits = {s2_ifp_isneg, s2_ifp_s_exp, s_rounded[22:0]};
      end
      if (d_rounded[53]) begin
        d_bits = {s2_ifp_isneg, s2_ifp_d_exp + 11'd1, 52'd0};
      end else begin
        d_bits = {s2_ifp_isneg, s2_ifp_d_exp, d_rounded[51:0]};
      end
    end

    ifp_fflags = '0;
    if (s2_fmt_d_q) begin
      ifp_result = d_bits;
      if (!s2_ifp_imag_zero && s2_ifp_d_inexact) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end else begin
      ifp_result = {FP_NANBOX_UPPER, s_bits};
      if (!s2_ifp_imag_zero && s2_ifp_s_inexact) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end

    // --- FP -> INT rounding (65-bit conditional increment + sign + range check) ---

    int_rounded      = {1'b0, s2_fpi_int_part} + (s2_fpi_round_up ? 65'd1 : 65'd0);
    mag              = int_rounded[63:0];
    over_after_round = 1'b0;
    fpi_result       = '0;
    fpi_fflags       = '0;

    if (s2_fpi_src_is_nan) begin
      fpi_result               = s2_fpi_target_max;
      fpi_fflags[FP_FFLAG_NV]  = 1'b1;
    end else if (s2_fpi_overflow) begin
      if (s2_fpi_neg_of) fpi_result = s2_fpi_target_is_signed ? s2_fpi_target_min : 64'd0;
      else               fpi_result = s2_fpi_target_max;
      fpi_fflags[FP_FFLAG_NV] = 1'b1;
    end else begin
      if (s2_fpi_target_is_32b && s2_fpi_target_is_signed) begin
        if (s2_fpi_src_sign) begin
          if (int_rounded > 65'h0_0000_0000_8000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_0000_0000_7FFF_FFFF) over_after_round = 1'b1;
        end
      end else if (s2_fpi_target_is_32b && !s2_fpi_target_is_signed) begin
        if (s2_fpi_src_sign && (mag != 64'd0 || s2_fpi_round_up)) begin
          over_after_round = 1'b1;
        end else if (int_rounded > 65'h0_0000_0000_FFFF_FFFF) begin
          over_after_round = 1'b1;
        end
      end else if (!s2_fpi_target_is_32b && s2_fpi_target_is_signed) begin
        if (s2_fpi_src_sign) begin
          if (int_rounded > 65'h0_8000_0000_0000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_7FFF_FFFF_FFFF_FFFF) over_after_round = 1'b1;
        end
      end else begin
        if (s2_fpi_src_sign && (mag != 64'd0 || s2_fpi_round_up)) begin
          over_after_round = 1'b1;
        end else if (int_rounded[64]) begin
          // verilator coverage_off
          over_after_round = 1'b1;
          // verilator coverage_on
        end
      end

      if (over_after_round) begin
        if (s2_fpi_src_sign) fpi_result = s2_fpi_target_is_signed ? s2_fpi_target_min : 64'd0;
        else                 fpi_result = s2_fpi_target_max;
        fpi_fflags[FP_FFLAG_NV] = 1'b1;
      end else begin
        signed_val = s2_fpi_src_sign ? (~mag + 64'd1) : mag;
        if (s2_fpi_target_is_32b) begin
          fpi_result = {{32{signed_val[31]}}, signed_val[31:0]};
        end else begin
          fpi_result = signed_val;
        end
        if (s2_fpi_is_inexact) fpi_fflags[FP_FFLAG_NX] = 1'b1;
      end
    end

    // --- Final mux ---
    s3_final_result = '0;
    s3_final_fflags = '0;
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
        s3_final_result = s2_ds_result;
        s3_final_fflags = s2_ds_fflags;
      end
      default: begin
        s3_final_result = '0;
        s3_final_fflags = '0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Stage-3 output registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
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
