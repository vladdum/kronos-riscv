// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module kronos_fpu_fmisc
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
  input  logic [63:0] c_i,     // unused for FMISC
  input  fpu_tag_t    tag_i,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // -------------------------------------------------------------------------
  // Helper functions: NaN classification for single-precision
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

  // -------------------------------------------------------------------------
  // Helper functions: NaN classification for double-precision
  // -------------------------------------------------------------------------
  function automatic logic is_snan_d(logic [62:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b0) && (x[50:0] != 51'd0);
  endfunction

  function automatic logic is_qnan_d(logic [62:0] x);
    return (x[62:52] == 11'h7FF) && (x[51] == 1'b1);
  endfunction

  function automatic logic is_nan_d(logic [62:0] x);
    return is_snan_d(x) || is_qnan_d(x);
  endfunction

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  logic [63:0] result_comb;
  logic [4:0]  fflags_comb;

  // NaN-unboxed operands for single-precision use
  logic [31:0] a_s, b_s;
  logic [63:0] a_eff, b_eff;

  // Intermediate signals for FMIN/FMAX
  logic a_nan_s, b_nan_s, a_snan_s, b_snan_s;
  logic a_nan_d, b_nan_d, a_snan_d, b_snan_d;

  // Single-precision comparison helpers
  logic a_sign_s, b_sign_s;
  logic [30:0] a_mag_s, b_mag_s;
  logic a_zero_s, b_zero_s;
  logic a_lt_b_s;      // a < b numerically (single)

  // Double-precision comparison helpers
  logic a_sign_d, b_sign_d;
  logic [62:0] a_mag_d, b_mag_d;
  logic a_zero_d, b_zero_d;
  logic a_lt_b_d;      // a < b numerically (double)

  // FEQ/FLT/FLE comparison result
  logic cmp_eq_s, cmp_lt_s, cmp_le_s;
  logic cmp_eq_d, cmp_lt_d, cmp_le_d;

  // FCLASS bits
  logic [9:0] fclass_bits;

  // -------------------------------------------------------------------------
  // NaN-unboxing for single-precision operands
  // If upper 32 bits != 0xFFFF_FFFF, replace with canonical single qNaN.
  // -------------------------------------------------------------------------
  always_comb begin
    // NaN-unbox single operands
    a_s = (a_i[63:32] == FP_NANBOX_UPPER) ? a_i[31:0] : FP_CANON_QNAN_S;
    b_s = (b_i[63:32] == FP_NANBOX_UPPER) ? b_i[31:0] : FP_CANON_QNAN_S;

    // Effective operands for each format
    if (fmt_d_i) begin
      a_eff = a_i;
      b_eff = b_i;
    end else begin
      a_eff = {FP_NANBOX_UPPER, a_s};
      b_eff = {FP_NANBOX_UPPER, b_s};
    end
  end

  // -------------------------------------------------------------------------
  // Precompute classification flags (used in multiple ops)
  // -------------------------------------------------------------------------
  always_comb begin
    // Single
    a_nan_s  = is_nan_s(a_s);
    b_nan_s  = is_nan_s(b_s);
    a_snan_s = is_snan_s(a_s);
    b_snan_s = is_snan_s(b_s);

    // Double
    a_nan_d  = is_nan_d(a_i[62:0]);
    b_nan_d  = is_nan_d(b_i[62:0]);
    a_snan_d = is_snan_d(a_i[62:0]);
    b_snan_d = is_snan_d(b_i[62:0]);

    // Single magnitude/sign for comparisons
    a_sign_s = a_s[31];
    b_sign_s = b_s[31];
    a_mag_s  = a_s[30:0];
    b_mag_s  = b_s[30:0];
    a_zero_s = (a_mag_s == 31'd0);
    b_zero_s = (b_mag_s == 31'd0);

    // Double magnitude/sign for comparisons
    a_sign_d = a_i[63];
    b_sign_d = b_i[63];
    a_mag_d  = a_i[62:0];
    b_mag_d  = b_i[62:0];
    a_zero_d = (a_mag_d == 63'd0);
    b_zero_d = (b_mag_d == 63'd0);

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
      if (is_snan_d(a_i[62:0]))
        fclass_bits = 10'b01_0000_0000; // bit 8: sNaN
      else if (is_qnan_d(a_i[62:0]))
        fclass_bits = 10'b10_0000_0000; // bit 9: qNaN
      else if (a_i[63] && (a_i[62:52] == 11'h7FF))
        fclass_bits = 10'b00_0000_0001; // bit 0: -inf
      else if (!a_i[63] && (a_i[62:52] == 11'h7FF))
        fclass_bits = 10'b00_1000_0000; // bit 7: +inf
      else if (a_i[63] && (a_i[62:52] != 11'd0))
        fclass_bits = 10'b00_0000_0010; // bit 1: -normal
      else if (!a_i[63] && (a_i[62:52] != 11'd0))
        fclass_bits = 10'b00_0100_0000; // bit 6: +normal
      else if (a_i[63] && (a_i[62:52] == 11'd0) && (a_i[51:0] != 52'd0))
        fclass_bits = 10'b00_0000_0100; // bit 2: -subnormal
      else if (!a_i[63] && (a_i[62:52] == 11'd0) && (a_i[51:0] != 52'd0))
        fclass_bits = 10'b00_0010_0000; // bit 5: +subnormal
      else if (a_i[63])
        fclass_bits = 10'b00_0000_1000; // bit 3: -zero
      else
        fclass_bits = 10'b00_0001_0000; // bit 4: +zero
    end else begin
      // Single (use unboxed a_s)
      if (is_snan_s(a_s))
        fclass_bits = 10'b01_0000_0000; // bit 8: sNaN
      else if (is_qnan_s(a_s))
        fclass_bits = 10'b10_0000_0000; // bit 9: qNaN
      else if (a_s[31] && (a_s[30:23] == 8'hFF))
        fclass_bits = 10'b00_0000_0001; // bit 0: -inf
      else if (!a_s[31] && (a_s[30:23] == 8'hFF))
        fclass_bits = 10'b00_1000_0000; // bit 7: +inf
      else if (a_s[31] && (a_s[30:23] != 8'd0))
        fclass_bits = 10'b00_0000_0010; // bit 1: -normal
      else if (!a_s[31] && (a_s[30:23] != 8'd0))
        fclass_bits = 10'b00_0100_0000; // bit 6: +normal
      else if (a_s[31] && (a_s[30:23] == 8'd0) && (a_s[22:0] != 23'd0))
        fclass_bits = 10'b00_0000_0100; // bit 2: -subnormal
      else if (!a_s[31] && (a_s[30:23] == 8'd0) && (a_s[22:0] != 23'd0))
        fclass_bits = 10'b00_0010_0000; // bit 5: +subnormal
      else if (a_s[31])
        fclass_bits = 10'b00_0000_1000; // bit 3: -zero
      else
        fclass_bits = 10'b00_0001_0000; // bit 4: +zero
    end
  end

  // -------------------------------------------------------------------------
  // Main combinational result computation
  // -------------------------------------------------------------------------
  always_comb begin
    result_comb = '0;
    fflags_comb = '0;

    unique case (op_i)
      // --- Sign injection ---
      FP_FSGNJ: begin
        if (fmt_d_i) begin
          result_comb = {b_eff[63], a_eff[62:0]};
        end else begin
          result_comb = {FP_NANBOX_UPPER, b_s[31], a_s[30:0]};
        end
      end

      FP_FSGNJN: begin
        if (fmt_d_i) begin
          result_comb = {~b_eff[63], a_eff[62:0]};
        end else begin
          result_comb = {FP_NANBOX_UPPER, ~b_s[31], a_s[30:0]};
        end
      end

      FP_FSGNJX: begin
        if (fmt_d_i) begin
          result_comb = {a_eff[63] ^ b_eff[63], a_eff[62:0]};
        end else begin
          result_comb = {FP_NANBOX_UPPER, a_s[31] ^ b_s[31], a_s[30:0]};
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
          if (a_snan_d || b_snan_d) fflags_comb[FP_FFLAG_NV] = 1'b1;
          if (a_nan_d && b_nan_d) begin
            result_comb = FP_CANON_QNAN_D;
          end else if (a_nan_d) begin
            result_comb = b_i;
          end else if (b_nan_d) begin
            result_comb = a_i;
          end else begin
            // Both numeric: min(-0,+0) = -0
            if (a_zero_d && b_zero_d) begin
              result_comb = (a_sign_d || b_sign_d) ? {1'b1, 63'd0} : a_i;
            end else begin
              result_comb = a_lt_b_d ? a_i : b_i;
            end
          end
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[FP_FFLAG_NV] = 1'b1;
          if (a_nan_s && b_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
          end else if (a_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, b_s};
          end else if (b_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, a_s};
          end else begin
            // Both numeric: min(-0,+0) = -0
            if (a_zero_s && b_zero_s) begin
              result_comb = (a_sign_s || b_sign_s) ? {FP_NANBOX_UPPER, 1'b1, 31'd0}
                                                   : {FP_NANBOX_UPPER, a_s};
            end else begin
              result_comb = a_lt_b_s ? {FP_NANBOX_UPPER, a_s} : {FP_NANBOX_UPPER, b_s};
            end
          end
        end
      end

      FP_FMAX: begin
        if (fmt_d_i) begin
          if (a_snan_d || b_snan_d) fflags_comb[FP_FFLAG_NV] = 1'b1;
          if (a_nan_d && b_nan_d) begin
            result_comb = FP_CANON_QNAN_D;
          end else if (a_nan_d) begin
            result_comb = b_i;
          end else if (b_nan_d) begin
            result_comb = a_i;
          end else begin
            // Both numeric: max(-0,+0) = +0
            if (a_zero_d && b_zero_d) begin
              result_comb = (!a_sign_d || !b_sign_d) ? {1'b0, 63'd0} : a_i;
            end else begin
              result_comb = a_lt_b_d ? b_i : a_i;
            end
          end
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[FP_FFLAG_NV] = 1'b1;
          if (a_nan_s && b_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, FP_CANON_QNAN_S};
          end else if (a_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, b_s};
          end else if (b_nan_s) begin
            result_comb = {FP_NANBOX_UPPER, a_s};
          end else begin
            // Both numeric: max(-0,+0) = +0
            if (a_zero_s && b_zero_s) begin
              result_comb = (!a_sign_s || !b_sign_s) ? {FP_NANBOX_UPPER, 1'b0, 31'd0}
                                                     : {FP_NANBOX_UPPER, a_s};
            end else begin
              result_comb = a_lt_b_s ? {FP_NANBOX_UPPER, b_s} : {FP_NANBOX_UPPER, a_s};
            end
          end
        end
      end

      // --- FCLASS ---
      FP_FCLASS: begin
        result_comb = {54'd0, fclass_bits};
      end

      // --- Comparisons ---
      FP_FEQ: begin
        if (fmt_d_i) begin
          // FEQ: only raises NV on sNaN
          if (a_snan_d || b_snan_d) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_eq_d};
        end else begin
          if (a_snan_s || b_snan_s) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_eq_s};
        end
      end

      FP_FLT: begin
        if (fmt_d_i) begin
          // FLT: raises NV on any NaN
          if (a_nan_d || b_nan_d) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_lt_d};
        end else begin
          if (a_nan_s || b_nan_s) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_lt_s};
        end
      end

      FP_FLE: begin
        if (fmt_d_i) begin
          // FLE: raises NV on any NaN
          if (a_nan_d || b_nan_d) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_le_d};
        end else begin
          if (a_nan_s || b_nan_s) fflags_comb[FP_FFLAG_NV] = 1'b1;
          result_comb = {63'd0, cmp_le_s};
        end
      end

      // --- Move operations ---
      FP_FMV_X_W: begin
        // Sign-extend low 32 bits to 64
        result_comb = {{32{a_i[31]}}, a_i[31:0]};
      end

      FP_FMV_W_X: begin
        // NaN-box low 32 bits of integer source
        result_comb = {FP_NANBOX_UPPER, a_i[31:0]};
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
        result_comb = '0;
        fflags_comb = '0;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // Pipeline register (1-cycle latency)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_o <= 1'b0;
      result_o    <= '0;
      fflags_o    <= '0;
      tag_o       <= '0;
    end else begin
      out_valid_o <= flush_i ? 1'b0 : in_valid_i;
      result_o    <= result_comb;
      fflags_o    <= fflags_comb;
      tag_o       <= tag_i;
    end
  end

endmodule
