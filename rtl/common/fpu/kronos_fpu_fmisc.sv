// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module kronos_fpu_fmisc
  import kronos_pkg::*;
(
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            flush_i,
  input  logic            in_valid_i,
  input  fp_op_e          op_i,
  input  logic            fmt_d_i,
  input  logic [2:0]      rm_i,
  input  logic [kronos_pkg::FLEN-1:0] a_i,
  input  logic [kronos_pkg::FLEN-1:0] b_i,
  input  fpu_tag_t        tag_i,
  output logic            out_valid_o,
  output logic [kronos_pkg::FLEN-1:0] result_o,
  output logic [4:0]      fflags_o,
  output fpu_tag_t        tag_o
);

  // -------------------------------------------------------------------------
  // Helper functions: NaN classification for single-precision
  // -------------------------------------------------------------------------
  function automatic logic is_snan_s(logic [kronos_pkg::FP_S_TOTAL_W-1:0] x);
    return (x[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == kronos_pkg::FP_S_EXP_MAX) &&
           (x[kronos_pkg::FP_S_MANT_W-1] == 1'b0) &&
           (x[kronos_pkg::FP_S_MANT_W-2:0] != {(kronos_pkg::FP_S_MANT_W-1){1'b0}});
  endfunction

  function automatic logic is_qnan_s(logic [kronos_pkg::FP_S_TOTAL_W-1:0] x);
    return (x[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == kronos_pkg::FP_S_EXP_MAX) &&
           (x[kronos_pkg::FP_S_MANT_W-1] == 1'b1);
  endfunction

  function automatic logic is_nan_s(logic [kronos_pkg::FP_S_TOTAL_W-1:0] x);
    return is_snan_s(x) || is_qnan_s(x);
  endfunction

  // -------------------------------------------------------------------------
  // Helper functions: NaN classification for double-precision
  // -------------------------------------------------------------------------
  function automatic logic is_snan_d(logic [kronos_pkg::FP_D_TOTAL_W-2:0] x);
    return (x[kronos_pkg::FP_D_TOTAL_W-2:FP_D_MANT_W] == kronos_pkg::FP_D_EXP_MAX) &&
           (x[kronos_pkg::FP_D_MANT_W-1] == 1'b0) &&
           (x[kronos_pkg::FP_D_MANT_W-2:0] != {(kronos_pkg::FP_D_MANT_W-1){1'b0}});
  endfunction

  function automatic logic is_qnan_d(logic [kronos_pkg::FP_D_TOTAL_W-2:0] x);
    return (x[kronos_pkg::FP_D_TOTAL_W-2:FP_D_MANT_W] == kronos_pkg::FP_D_EXP_MAX) &&
           (x[kronos_pkg::FP_D_MANT_W-1] == 1'b1);
  endfunction

  function automatic logic is_nan_d(logic [kronos_pkg::FP_D_TOTAL_W-2:0] x);
    return is_snan_d(x) || is_qnan_d(x);
  endfunction

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  logic [kronos_pkg::FLEN-1:0] result_comb;
  logic [4:0]      fflags_comb;

  // NaN-unboxed operands for single-precision use
  logic [kronos_pkg::FP_S_TOTAL_W-1:0] a_s, b_s;
  logic [kronos_pkg::FLEN-1:0]         a_eff, b_eff;

  // Intermediate signals for FMIN/FMAX
  logic a_nan_s, b_nan_s, a_snan_s, b_snan_s;
  logic a_nan_d, b_nan_d, a_snan_d, b_snan_d;

  // Single-precision comparison helpers
  logic                    a_sign_s, b_sign_s;
  logic [kronos_pkg::FP_S_TOTAL_W-2:0] a_mag_s, b_mag_s;
  logic                    a_zero_s, b_zero_s;
  logic                    a_lt_b_s;     // a < b numerically (single)

  // Double-precision comparison helpers
  logic                    a_sign_d, b_sign_d;
  logic [kronos_pkg::FP_D_TOTAL_W-2:0] a_mag_d, b_mag_d;
  logic                    a_zero_d, b_zero_d;
  logic                    a_lt_b_d;     // a < b numerically (double)

  // FEQ/FLT/FLE comparison result
  logic cmp_eq_s, cmp_lt_s, cmp_le_s;
  logic cmp_eq_d, cmp_lt_d, cmp_le_d;

  // FCLASS bits (10-bit one-hot, see FCLASS_* in kronos_pkg)
  logic [9:0] fclass_bits;

  // FMISC ops (FCLASS / FSGNJ / FMV / FMIN-FMAX / FEQ-FLT-FLE) are exact
  // — they do not consult the dynamic rounding mode.
  logic _unused;

  // -------------------------------------------------------------------------
  // NaN-unboxing for single-precision operands
  // If upper 32 bits != 0xFFFF_FFFF, replace with canonical single qNaN.
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults
    a_s   = kronos_pkg::FP_CANON_QNAN_S;
    b_s   = kronos_pkg::FP_CANON_QNAN_S;
    a_eff = {kronos_pkg::FLEN{1'b0}};
    b_eff = {kronos_pkg::FLEN{1'b0}};

    // NaN-unbox single operands
    a_s = (a_i[kronos_pkg::FLEN-1:FP_S_TOTAL_W] == kronos_pkg::FP_NANBOX_UPPER) ? a_i[kronos_pkg::FP_S_TOTAL_W-1:0]
                                                        : kronos_pkg::FP_CANON_QNAN_S;
    b_s = (b_i[kronos_pkg::FLEN-1:FP_S_TOTAL_W] == kronos_pkg::FP_NANBOX_UPPER) ? b_i[kronos_pkg::FP_S_TOTAL_W-1:0]
                                                        : kronos_pkg::FP_CANON_QNAN_S;

    // Effective operands for each format
    if (fmt_d_i) begin
      a_eff = a_i;
      b_eff = b_i;
    end else begin
      a_eff = {kronos_pkg::FP_NANBOX_UPPER, a_s};
      b_eff = {kronos_pkg::FP_NANBOX_UPPER, b_s};
    end
  end

  // -------------------------------------------------------------------------
  // Precompute classification flags (used in multiple ops)
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults
    a_nan_s     = 1'b0;
    b_nan_s     = 1'b0;
    a_snan_s    = 1'b0;
    b_snan_s    = 1'b0;
    a_nan_d     = 1'b0;
    b_nan_d     = 1'b0;
    a_snan_d    = 1'b0;
    b_snan_d    = 1'b0;
    a_sign_s    = 1'b0;
    b_sign_s    = 1'b0;
    a_mag_s     = {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}};
    b_mag_s     = {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}};
    a_zero_s    = 1'b0;
    b_zero_s    = 1'b0;
    a_sign_d    = 1'b0;
    b_sign_d    = 1'b0;
    a_mag_d     = {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}};
    b_mag_d     = {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}};
    a_zero_d    = 1'b0;
    b_zero_d    = 1'b0;
    a_lt_b_s    = 1'b0;
    a_lt_b_d    = 1'b0;
    cmp_eq_s    = 1'b0;
    cmp_lt_s    = 1'b0;
    cmp_le_s    = 1'b0;
    cmp_eq_d    = 1'b0;
    cmp_lt_d    = 1'b0;
    cmp_le_d    = 1'b0;
    fclass_bits = 10'd0;

    // Single
    a_nan_s  = is_nan_s(a_s);
    b_nan_s  = is_nan_s(b_s);
    a_snan_s = is_snan_s(a_s);
    b_snan_s = is_snan_s(b_s);

    // Double
    a_nan_d  = is_nan_d(a_i[kronos_pkg::FLEN-2:0]);
    b_nan_d  = is_nan_d(b_i[kronos_pkg::FLEN-2:0]);
    a_snan_d = is_snan_d(a_i[kronos_pkg::FLEN-2:0]);
    b_snan_d = is_snan_d(b_i[kronos_pkg::FLEN-2:0]);

    // Single magnitude/sign for comparisons
    a_sign_s = a_s[kronos_pkg::FP_S_TOTAL_W-1];
    b_sign_s = b_s[kronos_pkg::FP_S_TOTAL_W-1];
    a_mag_s  = a_s[kronos_pkg::FP_S_TOTAL_W-2:0];
    b_mag_s  = b_s[kronos_pkg::FP_S_TOTAL_W-2:0];
    a_zero_s = (a_mag_s == {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}});
    b_zero_s = (b_mag_s == {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}});

    // Double magnitude/sign for comparisons
    a_sign_d = a_i[kronos_pkg::FLEN-1];
    b_sign_d = b_i[kronos_pkg::FLEN-1];
    a_mag_d  = a_i[kronos_pkg::FLEN-2:0];
    b_mag_d  = b_i[kronos_pkg::FLEN-2:0];
    a_zero_d = (a_mag_d == {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}});
    b_zero_d = (b_mag_d == {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}});

    // Numeric comparison: a < b (single, ignoring NaN)
    // Two negatives: larger magnitude = smaller value
    // +0 == -0
    if (a_zero_s && b_zero_s) begin
      a_lt_b_s = 1'b0; // +0 == -0, not less
    end else if (a_sign_s != b_sign_s) begin
      a_lt_b_s = a_sign_s; // negative < positive
    end else if (a_sign_s) begin
      a_lt_b_s = (a_mag_s > b_mag_s); // both negative: larger mag = smaller val
    end else begin
      a_lt_b_s = (a_mag_s < b_mag_s); // both positive: smaller mag = smaller val
    end

    // Numeric comparison: a < b (double, ignoring NaN)
    if (a_zero_d && b_zero_d) begin
      a_lt_b_d = 1'b0;
    end else if (a_sign_d != b_sign_d) begin
      a_lt_b_d = a_sign_d;
    end else if (a_sign_d) begin
      a_lt_b_d = (a_mag_d > b_mag_d);
    end else begin
      a_lt_b_d = (a_mag_d < b_mag_d);
    end

    // Single comparisons
    cmp_eq_s = (!a_nan_s && !b_nan_s) && ((a_s == b_s) || (a_zero_s && b_zero_s));
    cmp_lt_s = (!a_nan_s && !b_nan_s) && a_lt_b_s;
    cmp_le_s = (!a_nan_s && !b_nan_s) && (a_lt_b_s || cmp_eq_s);

    // Double comparisons
    cmp_eq_d = (!a_nan_d && !b_nan_d) && ((a_i == b_i) || (a_zero_d && b_zero_d));
    cmp_lt_d = (!a_nan_d && !b_nan_d) && a_lt_b_d;
    cmp_le_d = (!a_nan_d && !b_nan_d) && (a_lt_b_d || cmp_eq_d);

    // FCLASS one-hot bits (single or double)
    // RISC-V spec: bit 8 = signalling NaN, bit 9 = quiet NaN.
    if (fmt_d_i) begin
      // Double
      if (is_snan_d(a_i[kronos_pkg::FLEN-2:0])) begin
        fclass_bits = kronos_pkg::FCLASS_SNAN;
      end else if (is_qnan_d(a_i[kronos_pkg::FLEN-2:0])) begin
        fclass_bits = kronos_pkg::FCLASS_QNAN;
      end else if (a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] == kronos_pkg::FP_D_EXP_MAX)) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_INF;
      end else if (!a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] == kronos_pkg::FP_D_EXP_MAX)) begin
        fclass_bits = kronos_pkg::FCLASS_POS_INF;
      end else if (a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] != {kronos_pkg::FP_D_EXP_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_NORMAL;
      end else if (!a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] != {kronos_pkg::FP_D_EXP_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_POS_NORMAL;
      end else if (a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (a_i[kronos_pkg::FP_D_MANT_W-1:0] != {kronos_pkg::FP_D_MANT_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_SUBNORMAL;
      end else if (!a_i[kronos_pkg::FLEN-1] && (a_i[kronos_pkg::FLEN-2:FP_D_MANT_W] == {kronos_pkg::FP_D_EXP_W{1'b0}}) && (a_i[kronos_pkg::FP_D_MANT_W-1:0] != {kronos_pkg::FP_D_MANT_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_POS_SUBNORMAL;
      end else if (a_i[kronos_pkg::FLEN-1]) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_ZERO;
      end else begin
        fclass_bits = kronos_pkg::FCLASS_POS_ZERO;
      end
    end else begin
      // Single (use unboxed a_s)
      if (is_snan_s(a_s)) begin
        fclass_bits = kronos_pkg::FCLASS_SNAN;
      end else if (is_qnan_s(a_s)) begin
        fclass_bits = kronos_pkg::FCLASS_QNAN;
      end else if (a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == kronos_pkg::FP_S_EXP_MAX)) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_INF;
      end else if (!a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == kronos_pkg::FP_S_EXP_MAX)) begin
        fclass_bits = kronos_pkg::FCLASS_POS_INF;
      end else if (a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] != {kronos_pkg::FP_S_EXP_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_NORMAL;
      end else if (!a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] != {kronos_pkg::FP_S_EXP_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_POS_NORMAL;
      end else if (a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (a_s[kronos_pkg::FP_S_MANT_W-1:0] != {kronos_pkg::FP_S_MANT_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_SUBNORMAL;
      end else if (!a_s[kronos_pkg::FP_S_TOTAL_W-1] && (a_s[kronos_pkg::FP_S_TOTAL_W-2:FP_S_MANT_W] == {kronos_pkg::FP_S_EXP_W{1'b0}}) && (a_s[kronos_pkg::FP_S_MANT_W-1:0] != {kronos_pkg::FP_S_MANT_W{1'b0}})) begin
        fclass_bits = kronos_pkg::FCLASS_POS_SUBNORMAL;
      end else if (a_s[kronos_pkg::FP_S_TOTAL_W-1]) begin
        fclass_bits = kronos_pkg::FCLASS_NEG_ZERO;
      end else begin
        fclass_bits = kronos_pkg::FCLASS_POS_ZERO;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Main combinational result computation
  // -------------------------------------------------------------------------
  always_comb begin
    result_comb = {kronos_pkg::FLEN{1'b0}};
    fflags_comb = 5'h0;

    unique case (op_i)
      // --- Sign injection ---
      FP_FSGNJ: begin
        if (fmt_d_i) begin
          result_comb = {b_eff[kronos_pkg::FLEN-1], a_eff[kronos_pkg::FLEN-2:0]};
        end else begin
          result_comb = {kronos_pkg::FP_NANBOX_UPPER, b_s[kronos_pkg::FP_S_TOTAL_W-1], a_s[kronos_pkg::FP_S_TOTAL_W-2:0]};
        end
      end

      FP_FSGNJN: begin
        if (fmt_d_i) begin
          result_comb = {~b_eff[kronos_pkg::FLEN-1], a_eff[kronos_pkg::FLEN-2:0]};
        end else begin
          result_comb = {kronos_pkg::FP_NANBOX_UPPER, ~b_s[kronos_pkg::FP_S_TOTAL_W-1], a_s[kronos_pkg::FP_S_TOTAL_W-2:0]};
        end
      end

      FP_FSGNJX: begin
        if (fmt_d_i) begin
          result_comb = {a_eff[kronos_pkg::FLEN-1] ^ b_eff[kronos_pkg::FLEN-1], a_eff[kronos_pkg::FLEN-2:0]};
        end else begin
          result_comb = {kronos_pkg::FP_NANBOX_UPPER, a_s[kronos_pkg::FP_S_TOTAL_W-1] ^ b_s[kronos_pkg::FP_S_TOTAL_W-1], a_s[kronos_pkg::FP_S_TOTAL_W-2:0]};
        end
      end

      // --- Min/Max ---
      // Per RISC-V F/D spec (and IEEE 754-2008 minNum/maxNum):
      //   - Signalling NaN on either operand raises NV, but the result is
      //     the non-NaN operand unless BOTH are NaN, in which case it is
      //     the canonical qNaN.
      //   - Quiet NaN on one operand silently returns the other.
      FP_FMIN: begin
        if (fmt_d_i) begin
          if (a_snan_d || b_snan_d) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          if (a_nan_d && b_nan_d) begin
            result_comb = kronos_pkg::FP_CANON_QNAN_D;
          end else if (a_nan_d) begin
            result_comb = b_i;
          end else if (b_nan_d) begin
            result_comb = a_i;
          end else begin
            // Both numeric: min(-0,+0) = -0
            if (a_zero_d && b_zero_d) begin
              result_comb = (a_sign_d || b_sign_d) ? {1'b1, {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}} : a_i;
            end else begin
              result_comb = a_lt_b_d ? a_i : b_i;
            end
          end
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          if (a_nan_s && b_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, kronos_pkg::FP_CANON_QNAN_S};
          end else if (a_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, b_s};
          end else if (b_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, a_s};
          end else begin
            // Both numeric: min(-0,+0) = -0
            if (a_zero_s && b_zero_s) begin
              result_comb = (a_sign_s || b_sign_s) ? {kronos_pkg::FP_NANBOX_UPPER, 1'b1, {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}}}
                                                   : {kronos_pkg::FP_NANBOX_UPPER, a_s};
            end else begin
              result_comb = a_lt_b_s ? {kronos_pkg::FP_NANBOX_UPPER, a_s} : {kronos_pkg::FP_NANBOX_UPPER, b_s};
            end
          end
        end
      end

      FP_FMAX: begin
        if (fmt_d_i) begin
          if (a_snan_d || b_snan_d) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          if (a_nan_d && b_nan_d) begin
            result_comb = kronos_pkg::FP_CANON_QNAN_D;
          end else if (a_nan_d) begin
            result_comb = b_i;
          end else if (b_nan_d) begin
            result_comb = a_i;
          end else begin
            // Both numeric: max(-0,+0) = +0
            if (a_zero_d && b_zero_d) begin
              result_comb = (!a_sign_d || !b_sign_d) ? {1'b0, {(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}} : a_i;
            end else begin
              result_comb = a_lt_b_d ? b_i : a_i;
            end
          end
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          if (a_nan_s && b_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, kronos_pkg::FP_CANON_QNAN_S};
          end else if (a_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, b_s};
          end else if (b_nan_s) begin
            result_comb = {kronos_pkg::FP_NANBOX_UPPER, a_s};
          end else begin
            // Both numeric: max(-0,+0) = +0
            if (a_zero_s && b_zero_s) begin
              result_comb = (!a_sign_s || !b_sign_s) ? {kronos_pkg::FP_NANBOX_UPPER, 1'b0, {(kronos_pkg::FP_S_TOTAL_W-1){1'b0}}}
                                                     : {kronos_pkg::FP_NANBOX_UPPER, a_s};
            end else begin
              result_comb = a_lt_b_s ? {kronos_pkg::FP_NANBOX_UPPER, b_s} : {kronos_pkg::FP_NANBOX_UPPER, a_s};
            end
          end
        end
      end

      // --- FCLASS ---
      FP_FCLASS: begin
        result_comb = {{(kronos_pkg::FLEN-10){1'b0}}, fclass_bits};
      end

      // --- Comparisons ---
      FP_FEQ: begin
        if (fmt_d_i) begin
          // FEQ: only raises NV on sNaN
          if (a_snan_d || b_snan_d) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_eq_d};
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_eq_s};
        end
      end

      FP_FLT: begin
        if (fmt_d_i) begin
          // FLT: raises NV on any NaN
          if (a_nan_d || b_nan_d) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_lt_d};
        end else begin
          if (a_nan_s || b_nan_s) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_lt_s};
        end
      end

      FP_FLE: begin
        if (fmt_d_i) begin
          // FLE: raises NV on any NaN
          if (a_nan_d || b_nan_d) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_le_d};
        end else begin
          if (a_nan_s || b_nan_s) fflags_comb[kronos_pkg::FP_FFLAG_NV] = 1'b1;
          result_comb = {{(kronos_pkg::FP_D_TOTAL_W-1){1'b0}}, cmp_le_s};
        end
      end

      // --- Move operations ---
      FP_FMV_X_W: begin
        // Sign-extend low 32 bits to 64
        result_comb = {{(kronos_pkg::FLEN-kronos_pkg::FP_S_TOTAL_W){a_i[kronos_pkg::FP_S_TOTAL_W-1]}}, a_i[kronos_pkg::FP_S_TOTAL_W-1:0]};
      end

      FP_FMV_W_X: begin
        // NaN-box low 32 bits of integer source
        result_comb = {kronos_pkg::FP_NANBOX_UPPER, a_i[kronos_pkg::FP_S_TOTAL_W-1:0]};
      end

      FP_FMV_X_D: begin
        // Pass double bits to integer register unchanged
        result_comb = a_i;
      end

      FP_FMV_D_X: begin
        // Pass integer bits to FP register unchanged
        result_comb = a_i;
      end

      default: begin
        result_comb = {kronos_pkg::FLEN{1'b0}};
        fflags_comb = 5'h0;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // Pipeline register (1-cycle latency)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= {kronos_pkg::FLEN{1'b0}};
      fflags_o    <= 5'h0;
      tag_o       <= '{default: '0};
    end else begin
      out_valid_o <= flush_i ? 1'b0 : in_valid_i;
      result_o    <= result_comb;
      fflags_o    <= fflags_comb;
      tag_o       <= tag_i;
    end
  end

  assign _unused = ^rm_i;

endmodule
