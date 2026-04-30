// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_fmisc;
  import kronos_pkg::*;
  import softfloat_dpi_pkg::*;

  logic             clk = 0, rst_n = 0, flush = 0, in_valid = 0;
  fp_op_e           op;
  logic             fmt_d;
  logic [2:0]       rm = 3'b000;
  logic [63:0]      a, b, c = '0;
  fpu_tag_t         tag_in = '{rd:0, fp_dest:0};
  logic             out_valid;
  logic [63:0]      result;
  logic [4:0]       fflags;
  fpu_tag_t         tag_out;

  kronos_fpu_fmisc u_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .in_valid_i(in_valid), .op_i(op), .fmt_d_i(fmt_d), .rm_i(rm),
    .a_i(a), .b_i(b), .tag_i(tag_in),
    .out_valid_o(out_valid), .result_o(result), .fflags_o(fflags), .tag_o(tag_out)
  );
  always #5 clk = ~clk;

  // 1-cycle unit: drive inputs at negedge, sample after next posedge.
  task automatic apply(input fp_op_e o, input logic f, input logic [63:0] ain,
                       input logic [63:0] bin);
    @(negedge clk); in_valid = 1; op = o; fmt_d = f; a = ain; b = bin;
    @(posedge clk) #1;
    in_valid = 0;
  endtask

  initial begin
    #12 rst_n = 1;

    // FSGNJ.S: sign = b, magnitude = a. a = -1.0f (NaN-boxed),
    // b = +3.14f (NaN-boxed). Result = +1.0f NaN-boxed.
    apply(FP_FSGNJ, 1'b0,
          64'hFFFF_FFFF_BF80_0000,
          64'hFFFF_FFFF_4048_F5C3);
    if (!out_valid || result[31:0] !== 32'h3F80_0000)
      $fatal(1, "fsgnj.s: %h", result);
    if (result[63:32] !== 32'hFFFF_FFFF)
      $fatal(1, "fsgnj.s nan-box: %h", result);

    // ── FCLASS.D — all ten number categories ─────────────────────────────
    apply(FP_FCLASS, 1'b1, 64'h7FF4_0000_0000_0000, 64'h0); // sNaN.D
    if (result[8] !== 1'b1) $fatal(1, "fclass.d sNaN: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h7FF8_0000_0000_0000, 64'h0); // qNaN.D
    if (result[9] !== 1'b1) $fatal(1, "fclass.d qNaN: %h", result);
    apply(FP_FCLASS, 1'b1, 64'hFFF0_0000_0000_0000, 64'h0); // -inf.D
    if (result[0] !== 1'b1) $fatal(1, "fclass.d -inf: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h7FF0_0000_0000_0000, 64'h0); // +inf.D
    if (result[7] !== 1'b1) $fatal(1, "fclass.d +inf: %h", result);
    apply(FP_FCLASS, 1'b1, 64'hBFF0_0000_0000_0000, 64'h0); // -normal.D (-1.0)
    if (result[1] !== 1'b1) $fatal(1, "fclass.d -normal: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h3FF0_0000_0000_0000, 64'h0); // +normal.D (1.0)
    if (result[6] !== 1'b1) $fatal(1, "fclass.d +normal: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h8001_0000_0000_0000, 64'h0); // -subnormal.D
    if (result[2] !== 1'b1) $fatal(1, "fclass.d -subnorm: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h0001_0000_0000_0000, 64'h0); // +subnormal.D
    if (result[5] !== 1'b1) $fatal(1, "fclass.d +subnorm: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h8000_0000_0000_0000, 64'h0); // -zero.D
    if (result[3] !== 1'b1) $fatal(1, "fclass.d -zero: %h", result);
    apply(FP_FCLASS, 1'b1, 64'h0000_0000_0000_0000, 64'h0); // +zero.D
    if (result[4] !== 1'b1) $fatal(1, "fclass.d +zero: %h", result);

    // ── FCLASS.S — all ten number categories (NaN-boxed) ─────────────────
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_7FA0_0000, 64'h0); // sNaN.S
    if (result[8] !== 1'b1) $fatal(1, "fclass.s sNaN: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_7FC0_0000, 64'h0); // qNaN.S
    if (result[9] !== 1'b1) $fatal(1, "fclass.s qNaN: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_FF80_0000, 64'h0); // -inf.S
    if (result[0] !== 1'b1) $fatal(1, "fclass.s -inf: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_7F80_0000, 64'h0); // +inf.S
    if (result[7] !== 1'b1) $fatal(1, "fclass.s +inf: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_BF80_0000, 64'h0); // -normal.S (-1.0)
    if (result[1] !== 1'b1) $fatal(1, "fclass.s -normal: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_3F80_0000, 64'h0); // +normal.S (1.0)
    if (result[6] !== 1'b1) $fatal(1, "fclass.s +normal: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_8040_0000, 64'h0); // -subnormal.S
    if (result[2] !== 1'b1) $fatal(1, "fclass.s -subnorm: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_0040_0000, 64'h0); // +subnormal.S
    if (result[5] !== 1'b1) $fatal(1, "fclass.s +subnorm: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_8000_0000, 64'h0); // -zero.S
    if (result[3] !== 1'b1) $fatal(1, "fclass.s -zero: %h", result);
    apply(FP_FCLASS, 1'b0, 64'hFFFF_FFFF_0000_0000, 64'h0); // +zero.S
    if (result[4] !== 1'b1) $fatal(1, "fclass.s +zero: %h", result);

    // FEQ.S +0.0 == -0.0 → 1, no flag
    apply(FP_FEQ, 1'b0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000);
    if (result[0] !== 1'b1 || fflags !== 5'b0) $fatal(1, "feq.s: r=%h f=%b", result, fflags);

    // FLT.S with sNaN → result 0, NV flag set
    apply(FP_FLT, 1'b0, 64'hFFFF_FFFF_7FA0_0000, 64'hFFFF_FFFF_4000_0000);
    if (result[0] !== 1'b0 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1)
      $fatal(1, "flt sNaN: r=%h f=%b", result, fflags);

    // FMIN.S(+0, -0) = -0 (IEEE 754 edge case)
    apply(FP_FMIN, 1'b0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000);
    if (result[31:0] !== 32'h8000_0000) $fatal(1, "fmin +0/-0: %h", result);

    // FMAX.S(+0, -0) = +0
    apply(FP_FMAX, 1'b0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000);
    if (result[31:0] !== 32'h0000_0000) $fatal(1, "fmax +0/-0: %h", result);

    // FMV.X.W sign-extends low 32 bits to 64.
    apply(FP_FMV_X_W, 1'b0, 64'hFFFF_FFFF_FFFF_8000, 64'h0);
    if ($signed(result) !== -64'sd32768)
      $fatal(1, "fmv.x.w sign-extend: %h", result);

    // FMV.W.X NaN-boxes the low 32 bits.
    apply(FP_FMV_W_X, 1'b0, 64'h0000_0000_DEAD_BEEF, 64'h0);
    if (result !== 64'hFFFF_FFFF_DEAD_BEEF)
      $fatal(1, "fmv.w.x nan-box: %h", result);

    // NaN-unboxing: upper 32 bits != FFFF_FFFF → becomes canonical qNaN
    apply(FP_FSGNJ, 1'b0, 64'h0000_0000_BF80_0000, 64'hFFFF_FFFF_0000_0000);
    if (result[31:0] !== 32'h7FC0_0000) $fatal(1, "nan-unbox: %h", result);

    // ── FSGNJ.D — sign from b (double), magnitude from a ─────────────────
    // a = +1.0D, b = -2.0D → result = -1.0D
    apply(FP_FSGNJ, 1'b1, 64'h3FF0_0000_0000_0000, 64'hC000_0000_0000_0000);
    if (!out_valid || result !== 64'hBFF0_0000_0000_0000) $fatal(1, "fsgnj.d: %h", result);

    // ── FSGNJN — negate sign of b, keep magnitude of a ───────────────────
    // FSGNJN.S: a = +1.0S, b = -3.14S → result = +1.0S (NaN-boxed)
    apply(FP_FSGNJN, 1'b0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_C048_F5C3);
    if (!out_valid || result !== 64'hFFFF_FFFF_3F80_0000) $fatal(1, "fsgnjn.s: %h", result);
    // FSGNJN.D: a = +1.0D, b = -2.0D → result = +1.0D
    apply(FP_FSGNJN, 1'b1, 64'h3FF0_0000_0000_0000, 64'hC000_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fsgnjn.d: %h", result);
    // FSGNJN.S: a = +1.0S, b = +3.14S → result = -1.0S (NaN-boxed)
    apply(FP_FSGNJN, 1'b0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4048_F5C3);
    if (!out_valid || result !== 64'hFFFF_FFFF_BF80_0000) $fatal(1, "fsgnjn.s pos: %h", result);

    // ── FSGNJX — XOR sign of a and b ─────────────────────────────────────
    // FSGNJX.S: a = -1.0S, b = -3.14S → neg XOR neg = pos → +1.0S
    apply(FP_FSGNJX, 1'b0, 64'hFFFF_FFFF_BF80_0000, 64'hFFFF_FFFF_C048_F5C3);
    if (!out_valid || result !== 64'hFFFF_FFFF_3F80_0000) $fatal(1, "fsgnjx.s neg: %h", result);
    // FSGNJX.S: a = +1.0S, b = -3.14S → pos XOR neg = neg → -1.0S
    apply(FP_FSGNJX, 1'b0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_C048_F5C3);
    if (!out_valid || result !== 64'hFFFF_FFFF_BF80_0000) $fatal(1, "fsgnjx.s pos: %h", result);
    // FSGNJX.D: a = +1.0D, b = -2.0D → pos XOR neg = neg → -1.0D
    apply(FP_FSGNJX, 1'b1, 64'h3FF0_0000_0000_0000, 64'hC000_0000_0000_0000);
    if (!out_valid || result !== 64'hBFF0_0000_0000_0000) $fatal(1, "fsgnjx.d: %h", result);
    // FSGNJX.D: a = -1.0D, b = -2.0D → neg XOR neg = pos → +1.0D
    apply(FP_FSGNJX, 1'b1, 64'hBFF0_0000_0000_0000, 64'hC000_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fsgnjx.d neg: %h", result);

    // ── FEQ.D ─────────────────────────────────────────────────────────────
    // 1.0D == 1.0D → 1, no flag
    apply(FP_FEQ, 1'b1, 64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b1 || fflags !== 5'b0) $fatal(1, "feq.d eq: %h/%b", result, fflags);
    // 1.0D == 2.0D → 0, no flag
    apply(FP_FEQ, 1'b1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags !== 5'b0) $fatal(1, "feq.d ne: %h/%b", result, fflags);
    // sNaN → result 0, NV
    apply(FP_FEQ, 1'b1, 64'h7FF4_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1) $fatal(1, "feq.d sNaN: %h/%b", result, fflags);

    // ── FLT.D ─────────────────────────────────────────────────────────────
    // 1.0D < 2.0D → 1
    apply(FP_FLT, 1'b1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b1 || fflags !== 5'b0) $fatal(1, "flt.d lt: %h/%b", result, fflags);
    // 2.0D < 1.0D → 0
    apply(FP_FLT, 1'b1, 64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags !== 5'b0) $fatal(1, "flt.d gt: %h/%b", result, fflags);
    // qNaN → result 0, NV
    apply(FP_FLT, 1'b1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1) $fatal(1, "flt.d NaN: %h/%b", result, fflags);

    // ── FLE.D ─────────────────────────────────────────────────────────────
    // 1.0D <= 1.0D → 1
    apply(FP_FLE, 1'b1, 64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b1 || fflags !== 5'b0) $fatal(1, "fle.d eq: %h/%b", result, fflags);
    // 2.0D <= 1.0D → 0
    apply(FP_FLE, 1'b1, 64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags !== 5'b0) $fatal(1, "fle.d gt: %h/%b", result, fflags);
    // sNaN → result 0, NV
    apply(FP_FLE, 1'b1, 64'h7FF4_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result[0] !== 1'b0 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1) $fatal(1, "fle.d sNaN: %h/%b", result, fflags);

    // ── FMIN.D — all branches ─────────────────────────────────────────────
    // basic: min(1.0D, 2.0D) = 1.0D
    apply(FP_FMIN, 1'b1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fmin.d basic: %h", result);
    // zero: min(+0D, -0D) = -0D
    apply(FP_FMIN, 1'b1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000);
    if (!out_valid || result !== 64'h8000_0000_0000_0000) $fatal(1, "fmin.d +0/-0: %h", result);
    // sNaN → non-NaN operand + NV (per RISC-V spec: "result is the non-NaN operand")
    apply(FP_FMIN, 1'b1, 64'h7FF4_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1)
      $fatal(1, "fmin.d sNaN: %h/%b", result, fflags);
    // qNaN a, number b → return b
    apply(FP_FMIN, 1'b1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fmin.d qNaN-a: %h", result);
    // number a, qNaN b → return a
    apply(FP_FMIN, 1'b1, 64'h3FF0_0000_0000_0000, 64'h7FF8_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fmin.d qNaN-b: %h", result);

    // ── FMAX.D — all branches ─────────────────────────────────────────────
    // basic: max(1.0D, 2.0D) = 2.0D
    apply(FP_FMAX, 1'b1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000);
    if (!out_valid || result !== 64'h4000_0000_0000_0000) $fatal(1, "fmax.d basic: %h", result);
    // zero: max(+0D, -0D) = +0D
    apply(FP_FMAX, 1'b1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000);
    if (!out_valid || result !== 64'h0000_0000_0000_0000) $fatal(1, "fmax.d +0/-0: %h", result);
    // sNaN → non-NaN operand + NV (per RISC-V spec: "result is the non-NaN operand")
    apply(FP_FMAX, 1'b1, 64'h7FF4_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b1)
      $fatal(1, "fmax.d sNaN: %h/%b", result, fflags);
    // qNaN a, number b → return b
    apply(FP_FMAX, 1'b1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fmax.d qNaN-a: %h", result);
    // number a, qNaN b → return a
    apply(FP_FMAX, 1'b1, 64'h3FF0_0000_0000_0000, 64'h7FF8_0000_0000_0000);
    if (!out_valid || result !== 64'h3FF0_0000_0000_0000) $fatal(1, "fmax.d qNaN-b: %h", result);

    // FMIN.D(qNaN, qNaN) → canonical qNaN, no NV  [covers both-NaN branch]
    apply(FP_FMIN, 1'b1, 64'h7FF8_0000_0000_0000, 64'h7FF8_0000_0000_0000);
    if (!out_valid || result !== 64'h7FF8_0000_0000_0000 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b0)
      $fatal(1, "fmin.d both-qNaN: r=%h f=%b", result, fflags);

    // FMAX.D(qNaN, qNaN) → canonical qNaN, no NV
    apply(FP_FMAX, 1'b1, 64'h7FF8_0000_0000_0000, 64'h7FF8_0000_0000_0000);
    if (!out_valid || result !== 64'h7FF8_0000_0000_0000 || fflags[kronos_pkg::FP_FFLAG_NV] !== 1'b0)
      $fatal(1, "fmax.d both-qNaN: r=%h f=%b", result, fflags);

    // FMAX.S(-0, -0) → -0  [covers the -0/-0 equal-zero branch for FMAX.S]
    apply(FP_FMAX, 1'b0, 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_8000_0000);
    if (result[31:0] !== 32'h8000_0000)
      $fatal(1, "fmax.s -0/-0: %h", result);

    // ── FMV.X.D / FMV.D.X ────────────────────────────────────────────────
    apply(FP_FMV_X_D, 1'b1, 64'hDEAD_BEEF_1234_5678, 64'h0);
    if (!out_valid || result !== 64'hDEAD_BEEF_1234_5678) $fatal(1, "fmv.x.d: %h", result);
    apply(FP_FMV_D_X, 1'b1, 64'hCAFE_BABE_DEAD_BEEF, 64'h0);
    if (!out_valid || result !== 64'hCAFE_BABE_DEAD_BEEF) $fatal(1, "fmv.d.x: %h", result);

    // --------------------------------------------------------------------
    // Random differential: FEQ/FLT/FLE and FMIN/FMAX vs SV reference
    // Weighted operand generation: ~50% random, ~30% boundary, ~20% specials
    // fflags checked for NV on NaN inputs per RISC-V spec
    // --------------------------------------------------------------------
    begin : blk_random_fmisc
      int          rand_errors;
      int          rand_total;
      logic [31:0] ra32, rb32;
      logic        a_nan, b_nan, a_snan, b_snan, a_zero, b_zero;
      logic        ref_feq, ref_flt, ref_fle;
      logic [31:0] ref_fmin, ref_fmax;
      logic        exp_nv_eq, exp_nv_lt, exp_nv_le;
      logic        exp_nv_min, exp_nv_max;
      int          pick_a, pick_b;

      rand_errors = 0;
      rand_total  = 0;

      for (int k = 0; k < 500; k++) begin

        // --- Weighted operand selection ---
        // 0-4 (50%): fully random  5: +Inf  6: -Inf  7: +0  8: qNaN  9: sNaN
        pick_a = $urandom_range(0, 9);
        if      (pick_a <= 4) ra32 = $urandom;
        else if (pick_a == 5) ra32 = 32'h7F80_0000;
        else if (pick_a == 6) ra32 = 32'hFF80_0000;
        else if (pick_a == 7) ra32 = 32'h0000_0000;
        else if (pick_a == 8) ra32 = 32'h7FC0_0000;
        else                  ra32 = 32'h7FA0_0000;

        pick_b = $urandom_range(0, 9);
        if      (pick_b <= 4) rb32 = $urandom;
        else if (pick_b == 5) rb32 = 32'h7F80_0000;
        else if (pick_b == 6) rb32 = 32'hFF80_0000;
        else if (pick_b == 7) rb32 = 32'h0000_0000;
        else if (pick_b == 8) rb32 = 32'h7FC0_0000;
        else                  rb32 = 32'h7FA0_0000;

        // Classify operands
        a_nan  = (ra32[30:23] == 8'hFF) && (ra32[22:0] != 0);
        b_nan  = (rb32[30:23] == 8'hFF) && (rb32[22:0] != 0);
        a_snan = a_nan && !ra32[22];  // quiet bit=0 → sNaN
        b_snan = b_nan && !rb32[22];
        a_zero = (ra32[30:0] == 31'h0);
        b_zero = (rb32[30:0] == 31'h0);

        // Expected NV flags per RISC-V spec
        exp_nv_eq  = a_snan || b_snan;         // FEQ: only sNaN raises NV
        exp_nv_lt  = a_nan  || b_nan;           // FLT: any NaN raises NV
        exp_nv_le  = a_nan  || b_nan;           // FLE: any NaN raises NV
        exp_nv_min = a_snan || b_snan;          // FMIN: only sNaN raises NV
        exp_nv_max = a_snan || b_snan;          // FMAX: only sNaN raises NV

        // Reference FEQ.S: +0 == -0, NaN returns 0
        ref_feq = (!a_nan && !b_nan) && (ra32 == rb32 || (a_zero && b_zero));

        // Reference FLT.S: signed comparison, NaN returns 0
        if (a_nan || b_nan) begin
          ref_flt = 1'b0;
        end else if (a_zero && b_zero) begin
          ref_flt = 1'b0;
        end else if (ra32[31] && !rb32[31]) begin
          ref_flt = 1'b1;  // a negative, b non-negative
        end else if (!ra32[31] && rb32[31]) begin
          ref_flt = 1'b0;  // a non-negative, b negative
        end else if (ra32[31]) begin
          ref_flt = (ra32[30:0] > rb32[30:0]);  // both negative
        end else begin
          ref_flt = (ra32[30:0] < rb32[30:0]);  // both positive
        end

        // Reference FLE.S: a <= b  iff  a < b  or  a == b (feq semantics)
        ref_fle = ref_flt | ref_feq;

        // Reference FMIN.S per RISC-V spec:
        // - Both NaN (any combo) → canonical qNaN
        // - One NaN → the non-NaN operand (even if the NaN is signaling)
        // - sNaN → also raise NV
        if (a_nan && b_nan) begin
          ref_fmin = 32'h7FC0_0000;
        end else if (a_nan) begin
          ref_fmin = rb32;
        end else if (b_nan) begin
          ref_fmin = ra32;
        end else if (a_zero && b_zero) begin
          // If either is -0, result is -0; else both +0, return +0
          ref_fmin = (ra32[31] || rb32[31]) ? 32'h8000_0000 : 32'h0000_0000;
        end else if (ref_flt) begin
          ref_fmin = ra32;
        end else begin
          ref_fmin = rb32;
        end

        // Reference FMAX.S per RISC-V spec: same NaN rules as FMIN.S
        if (a_nan && b_nan) begin
          ref_fmax = 32'h7FC0_0000;
        end else if (a_nan) begin
          ref_fmax = rb32;
        end else if (b_nan) begin
          ref_fmax = ra32;
        end else if (a_zero && b_zero) begin
          // If either is +0, result is +0; else both -0, return -0
          ref_fmax = (!ra32[31] || !rb32[31]) ? 32'h0000_0000 : 32'h8000_0000;
        end else if (ref_flt) begin
          ref_fmax = rb32;
        end else begin
          ref_fmax = ra32;
        end

        // --- FEQ.S ---
        apply(FP_FEQ, 1'b0, {32'hFFFF_FFFF, ra32}, {32'hFFFF_FFFF, rb32});
        rand_total++;
        if (result[0] !== ref_feq || (fflags[kronos_pkg::FP_FFLAG_NV] !== exp_nv_eq)) begin
          $error("[FEQ.S rand %0d] a=%h b=%h dut=%b/%b ref=%b nv_exp=%b",
                 k, ra32, rb32, result[0], fflags[kronos_pkg::FP_FFLAG_NV], ref_feq, exp_nv_eq);
          rand_errors++;
        end

        // --- FLT.S ---
        apply(FP_FLT, 1'b0, {32'hFFFF_FFFF, ra32}, {32'hFFFF_FFFF, rb32});
        rand_total++;
        if (result[0] !== ref_flt || (fflags[kronos_pkg::FP_FFLAG_NV] !== exp_nv_lt)) begin
          $error("[FLT.S rand %0d] a=%h b=%h dut=%b/%b ref=%b nv_exp=%b",
                 k, ra32, rb32, result[0], fflags[kronos_pkg::FP_FFLAG_NV], ref_flt, exp_nv_lt);
          rand_errors++;
        end

        // --- FLE.S ---
        apply(FP_FLE, 1'b0, {32'hFFFF_FFFF, ra32}, {32'hFFFF_FFFF, rb32});
        rand_total++;
        if (result[0] !== ref_fle || (fflags[kronos_pkg::FP_FFLAG_NV] !== exp_nv_le)) begin
          $error("[FLE.S rand %0d] a=%h b=%h dut=%b/%b ref=%b nv_exp=%b",
                 k, ra32, rb32, result[0], fflags[kronos_pkg::FP_FFLAG_NV], ref_fle, exp_nv_le);
          rand_errors++;
        end

        // --- FMIN.S --- (NaN inputs are now tested, not skipped)
        apply(FP_FMIN, 1'b0, {32'hFFFF_FFFF, ra32}, {32'hFFFF_FFFF, rb32});
        rand_total++;
        if (result[31:0] !== ref_fmin || (fflags[kronos_pkg::FP_FFLAG_NV] !== exp_nv_min)) begin
          $error("[FMIN.S rand %0d] a=%h b=%h dut=%h/%b ref=%h nv_exp=%b",
                 k, ra32, rb32, result[31:0], fflags[kronos_pkg::FP_FFLAG_NV], ref_fmin, exp_nv_min);
          rand_errors++;
        end

        // --- FMAX.S --- (NaN inputs are now tested, not skipped)
        apply(FP_FMAX, 1'b0, {32'hFFFF_FFFF, ra32}, {32'hFFFF_FFFF, rb32});
        rand_total++;
        if (result[31:0] !== ref_fmax || (fflags[kronos_pkg::FP_FFLAG_NV] !== exp_nv_max)) begin
          $error("[FMAX.S rand %0d] a=%h b=%h dut=%h/%b ref=%h nv_exp=%b",
                 k, ra32, rb32, result[31:0], fflags[kronos_pkg::FP_FFLAG_NV], ref_fmax, exp_nv_max);
          rand_errors++;
        end
      end

      if (|rand_errors)
        $fatal(1, "random fmisc: %0d/%0d errors", rand_errors, rand_total);
      $display("random fmisc: %0d checks passed", rand_total);
    end

    // ---- Directed: invalid fp_op_e → default arm  [covers lines 395-397] ----
    apply(fp_op_e'(4'd15), 1'b1, 64'hDEAD_BEEF_CAFE_1234, 64'hABCD_1234_5678_9ABC);
    if (result !== 64'h0 || fflags !== 5'b0) begin
      $error("fmisc invalid op: dut=%h/%b expected 0/0", result, fflags);
      $fatal(1, "invalid op test failed");
    end
    $display("fmisc invalid op check passed");

    $display("tb_fpu_fmisc PASS");
    $finish;
  end
endmodule
