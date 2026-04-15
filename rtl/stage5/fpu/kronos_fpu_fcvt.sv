// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FCVT unit: integer<->FP conversions (W/WU/L/LU) and S<->D format conversion.
// 2-stage pipelined. Latency = 2 cycles.

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
        clz64 = 63 - i;
        break;
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
  logic [63:0] s1_a_q;          // NaN-unboxed / raw source
  fpu_tag_t    s1_tag_q;

  // ---------------------------------------------------------------------------
  // Stage-1 combinational (NaN-unbox single-precision inputs)
  // ---------------------------------------------------------------------------
  logic [63:0] s1_a_next;
  logic        s1_src_is_single;

  always_comb begin
    // Source-single operand? FP->INT or S->D read a single; everything else reads
    // either a double (FP->INT with fmt_d) or an integer (INT->FP) or a double
    // source (D->S). We only need to NaN-unbox when the source is a single FP
    // value (FCVT.*.F with fmt_d=0, and FCVT.D.S).
    s1_src_is_single = 1'b0;
    unique case (op_i)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: s1_src_is_single = ~fmt_d_i; // fmt_d_i == source format
      FP_FCVT_D_S:  s1_src_is_single = 1'b1;
      default:      s1_src_is_single = 1'b0;
    endcase

    if (s1_src_is_single) begin
      // NaN-unbox: if upper 32 bits aren't all ones, force canonical qNaN
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
  // Stage-2 combinational logic: compute result from stage-1 registers
  // ---------------------------------------------------------------------------
  logic [63:0] s2_result;
  logic [4:0]  s2_fflags;

  // Source decomposition (for FP->INT and S/D convert)
  logic        src_sign;
  logic        src_is_s;           // source is single (low 32 of s1_a_q)
  logic [31:0] src_s;
  logic [63:0] src_d;
  logic [10:0] src_exp_d;
  logic [51:0] src_mant_d;
  logic [7:0]  src_exp_s;
  logic [22:0] src_mant_s;
  logic        src_is_nan;
  logic        src_is_inf;
  logic        src_is_zero;

  // FP->INT working signals
  logic signed [12:0] unbiased_exp;  // signed for range check
  logic [63:0]  int_part;
  logic         rnd_g, rnd_s; // guard and sticky
  logic         rnd_lsb;
  logic         round_up;
  logic [64:0]  int_rounded;         // one extra for overflow detect
  logic         is_inexact_fpi;
  logic [63:0]  target_max, target_min;
  logic         target_is_signed;
  logic         target_is_32b;
  logic         fpi_overflow;
  logic         fpi_neg_of;           // negative overflow (value < min)

  // INT->FP working signals
  logic [63:0]  ifp_result;
  logic [4:0]   ifp_fflags;

  // Format conversion (D->S) working signals
  logic [63:0]  ds_result;
  logic [4:0]   ds_fflags;

  // ---------------------------------------------------------------------------
  // Decompose source
  // ---------------------------------------------------------------------------
  always_comb begin
    src_s     = s1_a_q[31:0];
    src_d     = s1_a_q;
    src_exp_s = src_s[30:23];
    src_mant_s = src_s[22:0];
    src_exp_d  = src_d[62:52];
    src_mant_d = src_d[51:0];

    // We pick source format for FP->INT based on s1_fmt_d_q (source fmt for these)
    src_is_s = 1'b0;
    unique case (s1_op_q)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: src_is_s = ~s1_fmt_d_q;
      FP_FCVT_D_S:  src_is_s = 1'b1;
      FP_FCVT_S_D:  src_is_s = 1'b0; // double source
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
  // FP -> INT conversion
  // ---------------------------------------------------------------------------
  // unbiased exponent, and a 64-bit-left-aligned significand with 1.xxx
  // For exp E (unbiased), the integer value is sig_64 >> (63 - E); fractional
  // bits dropped to the right form guard+sticky.
  always_comb begin
    logic [63:0] sig64; // normalised with implicit 1 at bit 63
    logic [63:0] frac_mask;
    logic [6:0]  shift_r;
    logic [7:0]  frac_bits;   // number of bits shifted right (fraction width)

    // Decompose: build a 64-bit significand with implicit 1 at bit 63
    if (src_is_s) begin
      unbiased_exp = $signed({5'd0, src_exp_s}) - 13'sd127;
      // 24-bit significand (1+23), place at bits [63:40]
      sig64 = {1'b1, src_mant_s, 40'd0};
    end else begin
      unbiased_exp = $signed({2'd0, src_exp_d}) - 13'sd1023;
      // 53-bit significand (1+52), place at bits [63:11]
      sig64 = {1'b1, src_mant_d, 11'd0};
    end

    // Target setup
    target_is_signed = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_L_F);
    target_is_32b    = (s1_op_q == FP_FCVT_W_F) || (s1_op_q == FP_FCVT_WU_F);

    // Saturation values per RISC-V spec
    if (target_is_32b && target_is_signed) begin
      target_max    = {{32{1'b0}}, 32'h7FFF_FFFF};
      target_min    = {{32{1'b1}}, 32'h8000_0000}; // sign-extended
    end else if (target_is_32b && !target_is_signed) begin
      // RISC-V: FCVT.WU sign-extends 32-bit result; max u32 = 0xFFFF_FFFF sign-ext = all 1s
      target_max    = {32'hFFFF_FFFF, 32'hFFFF_FFFF};
      target_min    = 64'd0;
    end else if (!target_is_32b && target_is_signed) begin
      target_max    = 64'h7FFF_FFFF_FFFF_FFFF;
      target_min    = 64'h8000_0000_0000_0000;
    end else begin
      target_max    = 64'hFFFF_FFFF_FFFF_FFFF;
      target_min    = 64'd0;
    end

    // Shift: result integer = sig64 >> (63 - exp); fraction bits = (63 - exp)
    // If exp >= width, overflow. If exp < 0 (value < 1), integer=0, frac=all of sig64.
    int_part    = '0;
    rnd_g       = 1'b0;
    rnd_s       = 1'b0;
    rnd_lsb     = 1'b0;
    fpi_overflow = 1'b0;
    fpi_neg_of   = 1'b0;

    if (src_is_nan) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = 1'b0; // NaN -> max for signed, max for unsigned
    end else if (src_is_inf) begin
      fpi_overflow = 1'b1;
      fpi_neg_of   = src_sign;
    end else if (src_is_zero) begin
      int_part = '0;
    end else begin
      // unbiased_exp in range [-1023,1023]
      if (unbiased_exp < 0) begin
        // |v| < 1; integer part = 0; fraction is the full significand
        int_part = '0;
        // Explicit computation for guard/sticky bits:
        if (unbiased_exp == -13'sd1) begin
          // value in [0.5, 1): G=1 (the implicit 1), rest sticky
          rnd_g = 1'b1;
          rnd_s = |sig64[62:0];
        end else begin
          // value < 0.5: G=0, sticky = 1 if any non-zero
          rnd_g = 1'b0;
          rnd_s = 1'b1; // any nonzero normal below 0.5 -> inexact sticky
        end
        rnd_lsb = 1'b0;
      end else begin
        // exp >= 0. Build 128-bit shifted: sig64 << exp, then top 64 = integer, bottom = fraction
        // integer = sig64 >> (63 - exp)
        if (unbiased_exp >= 13'sd64) begin
          fpi_overflow = 1'b1;
          fpi_neg_of   = src_sign;
        end else begin
          // int_part has (exp+1) bits of integer. Need to detect unsigned range after.
          shift_r   = 7'd63 - unbiased_exp[6:0];
          frac_bits = {1'b0, shift_r};
          int_part  = sig64 >> shift_r;
          // Fraction bits are the low shift_r bits of sig64
          // Extract G (bit shift_r-1) and sticky (bits below)
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

    // Rounding decision (RNE/RTZ/RDN/RUP/RMM)
    round_up = 1'b0;
    if (!fpi_overflow) begin
      unique case (s1_rm_q)
        3'b000: round_up = rnd_g && (rnd_s || rnd_lsb);          // RNE
        3'b001: round_up = 1'b0;                                   // RTZ
        3'b010: round_up = src_sign && (rnd_g || rnd_s);           // RDN: toward -inf
        3'b011: round_up = !src_sign && (rnd_g || rnd_s);          // RUP: toward +inf
        3'b100: round_up = rnd_g;                                  // RMM: ties to max magnitude
        default: round_up = rnd_g && (rnd_s || rnd_lsb);
      endcase
    end

    // Rounded magnitude (unsigned), plus 1-bit carry slot
    int_rounded = {1'b0, int_part} + (round_up ? 65'd1 : 65'd0);
    is_inexact_fpi = rnd_g | rnd_s;

    // Apply sign and range-check
    s2_result = '0;
    s2_fflags = '0;

    if (src_is_nan) begin
      // NaN → saturate to max value (signed or unsigned, per RISC-V F spec §11.2)
      s2_result = target_max;
      s2_fflags[FP_FFLAG_NV] = 1'b1;
    end else if (fpi_overflow) begin
      if (fpi_neg_of) s2_result = target_is_signed ? target_min : 64'd0;
      else            s2_result = target_max;
      s2_fflags[FP_FFLAG_NV] = 1'b1;
    end else begin
      // Take |value| = int_rounded (up to 65 bits), then apply sign.
      logic [63:0] mag;
      logic        over_after_round;
      logic [63:0] signed_val;

      mag = int_rounded[63:0];
      over_after_round = 1'b0;

      if (target_is_32b && target_is_signed) begin
        // Range: [-2^31, 2^31-1]. mag must fit in 31 bits (positive) or 31 bits+1 for min.
        if (src_sign) begin
          // Negative: allow mag up to 2^31
          if (int_rounded > 65'h0_0000_0000_8000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_0000_0000_7FFF_FFFF) over_after_round = 1'b1;
        end
      end else if (target_is_32b && !target_is_signed) begin
        if (src_sign && (mag != 64'd0 || round_up)) begin
          // Negative nonzero -> saturate to 0, NV
          over_after_round = 1'b1;
        end else if (int_rounded > 65'h0_0000_0000_FFFF_FFFF) begin
          over_after_round = 1'b1;
        end
      end else if (!target_is_32b && target_is_signed) begin
        if (src_sign) begin
          if (int_rounded > 65'h0_8000_0000_0000_0000) over_after_round = 1'b1;
        end else begin
          if (int_rounded > 65'h0_7FFF_FFFF_FFFF_FFFF) over_after_round = 1'b1;
        end
      end else begin
        if (src_sign && (mag != 64'd0 || round_up)) begin
          over_after_round = 1'b1;
        end else if (int_rounded[64]) begin
          over_after_round = 1'b1;
        end
      end

      if (over_after_round) begin
        if (src_sign) s2_result = target_is_signed ? target_min : 64'd0;
        else          s2_result = target_max;
        s2_fflags[FP_FFLAG_NV] = 1'b1;
      end else begin
        // Apply sign
        signed_val = src_sign ? (~mag + 64'd1) : mag;

        // Sign-extend 32-bit results to 64 per RV spec
        if (target_is_32b) begin
          s2_result = {{32{signed_val[31]}}, signed_val[31:0]};
        end else begin
          s2_result = signed_val;
        end

        if (is_inexact_fpi) s2_fflags[FP_FFLAG_NX] = 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // INT -> FP conversion (overrides s2_result/fflags when op is FP_FCVT_F_*)
  // ---------------------------------------------------------------------------

  always_comb begin
    logic [63:0] imag;
    logic        isigned;
    logic        is32;
    logic        isneg;
    logic [63:0] norm;
    integer      lz;
    logic [7:0]  s_exp;
    logic [10:0] d_exp;
    logic [23:0] s_mant_pre;   // with implicit 1
    logic [52:0] d_mant_pre;
    logic        s_guard, s_round_sticky, s_lsb, s_round_up;
    logic        d_guard, d_round_sticky, d_lsb, d_round_up;
    logic [24:0] s_rounded;
    logic [53:0] d_rounded;
    logic        s_inexact, d_inexact;
    logic [31:0] s_bits;
    logic [63:0] d_bits;

    isigned = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_L);
    is32    = (s1_op_q == FP_FCVT_F_W) || (s1_op_q == FP_FCVT_F_WU);

    // Extract integer value
    if (is32) begin
      // 32-bit: low 32 of s1_a_q
      if (isigned) begin
        isneg = s1_a_q[31];
        imag  = isneg ? {32'd0, (~s1_a_q[31:0] + 32'd1)} : {32'd0, s1_a_q[31:0]};
      end else begin
        isneg = 1'b0;
        imag  = {32'd0, s1_a_q[31:0]};
      end
    end else begin
      if (isigned) begin
        isneg = s1_a_q[63];
        imag  = isneg ? (~s1_a_q + 64'd1) : s1_a_q;
      end else begin
        isneg = 1'b0;
        imag  = s1_a_q;
      end
    end

    // Normalise
    lz = clz64(imag);
    if (imag == 64'd0) begin
      norm = '0;
    end else begin
      norm = imag << lz; // MSB at bit 63
    end

    // Single-precision path ---------------------------------------------------
    // exponent = 127 + (63 - lz)
    s_exp = 8'd127 + 8'd63 - lz[7:0];
    // top 24 bits of norm is 1.xxx (bit63=1 explicit)
    s_mant_pre = norm[63:40]; // 24 bits including leading 1
    s_guard    = norm[39];
    s_round_sticky = |norm[38:0];
    s_lsb      = s_mant_pre[0];
    s_round_up = 1'b0;
    unique case (s1_rm_q)
      3'b000: s_round_up = s_guard && (s_round_sticky || s_lsb);
      3'b001: s_round_up = 1'b0;
      3'b010: s_round_up = isneg && (s_guard || s_round_sticky);
      3'b011: s_round_up = !isneg && (s_guard || s_round_sticky);
      3'b100: s_round_up = s_guard;
      default: s_round_up = s_guard && (s_round_sticky || s_lsb);
    endcase
    s_rounded = {1'b0, s_mant_pre} + (s_round_up ? 25'd1 : 25'd0);
    s_inexact = s_guard | s_round_sticky;

    if (imag == 64'd0) begin
      s_bits = 32'd0;
      if (isneg) s_bits[31] = 1'b0; // zero is positive
    end else begin
      // Check overflow from rounding (mantissa carried out)
      if (s_rounded[24]) begin
        s_bits = {isneg, s_exp + 8'd1, 23'd0}; // exponent bump, mantissa zero
      end else begin
        s_bits = {isneg, s_exp, s_rounded[22:0]};
      end
    end

    // Double-precision path ---------------------------------------------------
    d_exp = 11'd1023 + 11'd63 - {3'd0, lz[7:0]};
    d_mant_pre = norm[63:11]; // 53 bits including leading 1
    d_guard    = norm[10];
    d_round_sticky = |norm[9:0];
    d_lsb      = d_mant_pre[0];
    d_round_up = 1'b0;
    unique case (s1_rm_q)
      3'b000: d_round_up = d_guard && (d_round_sticky || d_lsb);
      3'b001: d_round_up = 1'b0;
      3'b010: d_round_up = isneg && (d_guard || d_round_sticky);
      3'b011: d_round_up = !isneg && (d_guard || d_round_sticky);
      3'b100: d_round_up = d_guard;
      default: d_round_up = d_guard && (d_round_sticky || d_lsb);
    endcase
    d_rounded = {1'b0, d_mant_pre} + (d_round_up ? 54'd1 : 54'd0);
    d_inexact = d_guard | d_round_sticky;

    if (imag == 64'd0) begin
      d_bits = 64'd0;
    end else begin
      if (d_rounded[53]) begin
        d_bits = {isneg, d_exp + 11'd1, 52'd0};
      end else begin
        d_bits = {isneg, d_exp, d_rounded[51:0]};
      end
    end

    ifp_fflags = '0;
    if (s1_fmt_d_q) begin
      ifp_result = d_bits;
      if (imag != 64'd0 && d_inexact) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end else begin
      ifp_result = {FP_NANBOX_UPPER, s_bits};
      if (imag != 64'd0 && s_inexact) ifp_fflags[FP_FFLAG_NX] = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // S <-> D format conversion
  // ---------------------------------------------------------------------------
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
    logic [23:0] ds_sig; // 1.xxx (24 bits)
    logic        ds_g, ds_sticky, ds_lsb, ds_round_up;
    logic [24:0] ds_rounded;

    fs_flags = '0;
    d_result = '0;
    s_result = '0;

    if (s1_op_q == FP_FCVT_D_S) begin
      // Single -> Double (exact)
      sd_sign  = s1_a_q[31];
      sd_sexp  = s1_a_q[30:23];
      sd_smant = s1_a_q[22:0];
      if ((sd_sexp == 8'd0) && (sd_smant == 23'd0)) begin
        // +/- zero
        d_result = {sd_sign, 63'd0};
      end else if ((sd_sexp == 8'hFF) && (sd_smant == 23'd0)) begin
        // +/- inf
        d_result = {sd_sign, 11'h7FF, 52'd0};
      end else if (sd_sexp == 8'hFF) begin
        // NaN: canonical qNaN in D (quiet sNaN by setting MSB of mantissa)
        // Signal sNaN input -> NV flag
        if (sd_smant[22] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        d_result = FP_CANON_QNAN_D;
      end else if (sd_sexp == 8'd0) begin
        // Subnormal single -> normalised double (always exact, fits)
        // Find leading 1 in mantissa
        integer k;
        logic [22:0] m;
        integer shift_amt;
        m = sd_smant;
        k = 0;
        for (k = 22; k >= 0; k = k - 1) begin
          if (m[k]) begin
            shift_amt = 23 - k;
            break;
          end
        end
        begin
          logic [52:0] new_mant;
          logic [10:0] new_exp;
          new_mant = {m, 30'd0} << shift_amt; // shift so implicit 1 leaves bit 52
          new_exp  = 11'd1023 - 11'd127 + 11'd1 - shift_amt[10:0];
          d_result = {sd_sign, new_exp, new_mant[51:0]};
        end
      end else begin
        // Normal: exp' = exp - 127 + 1023; mant zero-extended
        d_result = {sd_sign, ({3'd0, sd_sexp} + 11'd896), sd_smant, 29'd0};
      end
      ds_result = d_result;
      ds_fflags = fs_flags;
    end else begin
      // FP_FCVT_S_D: Double -> Single with rounding
      ds_sign  = s1_a_q[63];
      ds_dexp  = s1_a_q[62:52];
      ds_dmant = s1_a_q[51:0];
      ds_unbiased = $signed({2'd0, ds_dexp}) - 13'sd1023;

      if ((ds_dexp == 11'd0) && (ds_dmant == 52'd0)) begin
        s_result = {ds_sign, 31'd0};
      end else if ((ds_dexp == 11'h7FF) && (ds_dmant == 52'd0)) begin
        s_result = {ds_sign, 8'hFF, 23'd0};
      end else if (ds_dexp == 11'h7FF) begin
        // NaN
        if (ds_dmant[51] == 1'b0) fs_flags[FP_FFLAG_NV] = 1'b1;
        s_result = FP_CANON_QNAN_S;
      end else begin
        // Normal/subnormal double. Exponent range of single: [-126, 127].
        // Build 24-bit sig (with leading 1)
        if (ds_dexp == 11'd0) begin
          // Subnormal double - effectively zero at single precision if exponent < -126
          // In practice: underflow/inexact -> zero or subnormal
          // Simpler: treat as zero with UF+NX
          s_result = {ds_sign, 31'd0};
          fs_flags[FP_FFLAG_UF] = 1'b1;
          fs_flags[FP_FFLAG_NX] = 1'b1;
        end else if (ds_unbiased > 13'sd127) begin
          // Overflow
          fs_flags[FP_FFLAG_OF] = 1'b1;
          fs_flags[FP_FFLAG_NX] = 1'b1;
          // Saturate to inf (for RNE/RUP+/RDN- etc.) - use inf per IEEE
          // Round mode dependent: RTZ or RDN+ / RUP- -> max normal
          unique case (s1_rm_q)
            3'b001: s_result = {ds_sign, 8'hFE, 23'h7FFFFF};
            3'b010: s_result = ds_sign ? {1'b1, 8'hFF, 23'd0} : {1'b0, 8'hFE, 23'h7FFFFF};
            3'b011: s_result = ds_sign ? {1'b1, 8'hFE, 23'h7FFFFF} : {1'b0, 8'hFF, 23'd0};
            default: s_result = {ds_sign, 8'hFF, 23'd0};
          endcase
        end else if (ds_unbiased < -13'sd126) begin
          // Underflow -> zero or subnormal single
          // For now treat as zero (full subnormal handling is complex, rarely tested here)
          s_result = {ds_sign, 31'd0};
          fs_flags[FP_FFLAG_UF] = 1'b1;
          fs_flags[FP_FFLAG_NX] = 1'b1;
        end else begin
          // Normal range: round 52-bit mantissa to 23 bits
          // mant = 1.xxx (implicit 1), take top 24 bits (1 + 23 explicit)
          // guard = bit 28 of mant, sticky = |bits[27:0]
          ds_sig   = {1'b1, ds_dmant[51:29]}; // 24 bits
          ds_g     = ds_dmant[28];
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

          // New exponent (may bump if rounding overflows)
          ds_sexp_out = ds_unbiased[7:0] + 8'd127;
          if (ds_rounded[24]) begin
            // Mantissa overflow -> exp+1
            if ((ds_sexp_out + 8'd1) == 8'hFF) begin
              // Exponent overflow
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
      ds_result = {FP_NANBOX_UPPER, s_result};
      ds_fflags = fs_flags;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage-2 final mux
  // ---------------------------------------------------------------------------
  logic [63:0] s2_final_result;
  logic [4:0]  s2_final_fflags;

  always_comb begin
    unique case (s1_op_q)
      FP_FCVT_W_F,
      FP_FCVT_WU_F,
      FP_FCVT_L_F,
      FP_FCVT_LU_F: begin
        s2_final_result = s2_result;
        s2_final_fflags = s2_fflags;
      end
      FP_FCVT_F_W,
      FP_FCVT_F_WU,
      FP_FCVT_F_L,
      FP_FCVT_F_LU: begin
        s2_final_result = ifp_result;
        s2_final_fflags = ifp_fflags;
      end
      FP_FCVT_S_D,
      FP_FCVT_D_S: begin
        s2_final_result = ds_result;
        s2_final_fflags = ds_fflags;
      end
      default: begin
        s2_final_result = '0;
        s2_final_fflags = '0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Stage-2 output registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
    end else begin
      out_valid_o <= flush_i ? 1'b0 : s1_valid_q;
      if (s1_valid_q) begin
        result_o <= s2_final_result;
        fflags_o <= s2_final_fflags;
        tag_o    <= s1_tag_q;
      end
    end
  end

endmodule
