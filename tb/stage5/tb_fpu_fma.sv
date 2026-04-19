// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_fma;
  import kronos_pkg::*;
  import softfloat_dpi_pkg::*;
  import fp_tb_pkg::*;

  logic        clk = 0;
  logic        rst_n = 0;
  logic        flush = 0;
  logic        in_valid = 0;
  fp_op_e      op;
  logic        fmt_d;
  logic [2:0]  rm;
  logic [63:0] a, b, c;
  fpu_tag_t    tag_in;
  logic        out_valid;
  logic [63:0] result;
  logic [4:0]  fflags;
  fpu_tag_t    tag_out;

  kronos_fpu_fma u_dut (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .flush_i     (flush),
    .in_valid_i  (in_valid),
    .op_i        (op),
    .fmt_d_i     (fmt_d),
    .rm_i        (rm),
    .a_i         (a),
    .b_i         (b),
    .c_i         (c),
    .tag_i       (tag_in),
    .out_valid_o (out_valid),
    .result_o    (result),
    .fflags_o    (fflags),
    .tag_o       (tag_out)
  );

  always #5 clk = ~clk;

  int errors = 0;
  int total  = 0;

  task automatic apply5(input fp_op_e o, input logic fmtd, input logic [2:0] r,
                        input logic [63:0] ain, input logic [63:0] bin,
                        input logic [63:0] cin);
    @(negedge clk);
      in_valid = 1;
      op       = o;
      fmt_d    = fmtd;
      rm       = r;
      a        = ain;
      b        = bin;
      c        = cin;
    @(negedge clk);
      in_valid = 0;
    // 8-deep pipeline + output reg (S2b re-latch + S3b barrel-shift stage added)
    repeat (8) @(posedge clk);
    #1;
  endtask

  // ---- Single-precision check against SoftFloat ----
  task automatic check_s(input fp_op_e o, input logic [2:0] r,
                         input logic [31:0] as, input logic [31:0] bs,
                         input logic [31:0] cs, input string label);
    logic [31:0] sf_a, sf_b, sf_c;
    int unsigned sf_r;
    byte unsigned sf_f;
    apply5(o, 1'b0, r,
           {FP_NANBOX_UPPER, as}, {FP_NANBOX_UPPER, bs}, {FP_NANBOX_UPPER, cs});
    sf_a = as;
    sf_b = bs;
    sf_c = cs;
    unique case (o)
      FP_FMADD:  begin sf_reset(); sf_r = sf_f32_mulAdd(sf_a, sf_b, sf_c, {5'b0, r}); end
      FP_FMSUB:  begin sf_reset();
                       sf_r = sf_f32_mulAdd(sf_a, sf_b, {~sf_c[31], sf_c[30:0]}, {5'b0, r});
                 end
      FP_FNMADD: begin sf_reset();
                       sf_r = sf_f32_mulAdd({~sf_a[31], sf_a[30:0]}, sf_b,
                                            {~sf_c[31], sf_c[30:0]}, {5'b0, r});
                 end
      FP_FNMSUB: begin sf_reset();
                       sf_r = sf_f32_mulAdd({~sf_a[31], sf_a[30:0]}, sf_b, sf_c, {5'b0, r});
                 end
      default:   begin sf_r = '0; end
    endcase
    sf_f = sf_exceptions();
    total++;
    if (result[31:0] !== sf_r || fflags !== sf_f[4:0]) begin
      $error("[%s] dut=%h/%02b sf=%h/%02b a=%h b=%h c=%h rm=%0d",
             label, result[31:0], fflags, sf_r, sf_f[4:0], sf_a, sf_b, sf_c, r);
      errors++;
    end
  endtask

  // ---- Double-precision check against SoftFloat ----
  task automatic check_d(input fp_op_e o, input logic [2:0] r,
                         input logic [63:0] ad, input logic [63:0] bd,
                         input logic [63:0] cd, input string label);
    longint unsigned sf_r;
    byte unsigned sf_f;
    apply5(o, 1'b1, r, ad, bd, cd);
    unique case (o)
      FP_FMADD:  begin sf_reset(); sf_r = sf_f64_mulAdd(ad, bd, cd, {5'b0, r}); end
      FP_FMSUB:  begin sf_reset();
                       sf_r = sf_f64_mulAdd(ad, bd, {~cd[63], cd[62:0]}, {5'b0, r});
                 end
      FP_FNMADD: begin sf_reset();
                       sf_r = sf_f64_mulAdd({~ad[63], ad[62:0]}, bd,
                                            {~cd[63], cd[62:0]}, {5'b0, r});
                 end
      FP_FNMSUB: begin sf_reset();
                       sf_r = sf_f64_mulAdd({~ad[63], ad[62:0]}, bd, cd, {5'b0, r});
                 end
      default:   begin sf_r = '0; end
    endcase
    sf_f = sf_exceptions();
    total++;
    if (result !== sf_r || fflags !== sf_f[4:0]) begin
      $error("[%s] dut=%h/%02b sf=%h/%02b a=%h b=%h c=%h rm=%0d",
             label, result, fflags, sf_r, sf_f[4:0], ad, bd, cd, r);
      errors++;
    end
  endtask

  initial begin
    tag_in = '{rd: 5'd0, fp_dest: 1'b0};

    sf_reset();
    #12 rst_n = 1;
    @(negedge clk);

    // ------- Directed S-precision corner cases -------
    // +0 * +0 + (-0) in RNE -> +0
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h8000_0000});
    total++;
    if (result[31:0] !== 32'h0000_0000) begin
      $error("0*0+(-0) RNE: dut=%h", result[31:0]);
      errors++;
    end

    // +0 * +0 + (-0) in RDN -> -0
    apply5(FP_FMADD, 1'b0, 3'd2,
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h8000_0000});
    total++;
    if (result[31:0] !== 32'h8000_0000) begin
      $error("0*0+(-0) RDN: dut=%h", result[31:0]);
      errors++;
    end

    // Inf * 0 -> canonical qNaN, NV
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h7F80_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000});
    total++;
    if (result[31:0] !== FP_CANON_QNAN_S || !fflags[FP_FFLAG_NV]) begin
      $error("inf*0: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end

    // Inf * 1 + (-Inf) -> qNaN, NV
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h7F80_0000},
           {FP_NANBOX_UPPER, 32'h3F80_0000},
           {FP_NANBOX_UPPER, 32'hFF80_0000});
    total++;
    if (result[31:0] !== FP_CANON_QNAN_S || !fflags[FP_FFLAG_NV]) begin
      $error("inf-inf: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end

    // ── sNaN input -> canonical qNaN + NV ────────────────────────────────
    // S-precision: sNaN.S × 1.0S + 0 → qNaN.S + NV
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h7FA0_0000},   // a = sNaN.S
           {FP_NANBOX_UPPER, 32'h3F80_0000},   // b = 1.0S
           {FP_NANBOX_UPPER, 32'h0000_0000});  // c = +0
    total++;
    if (result[31:0] !== FP_CANON_QNAN_S || !fflags[FP_FFLAG_NV]) begin
      $error("sNaN.s fma: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end
    // D-precision: sNaN.D × 1.0D + 0 → qNaN.D + NV
    apply5(FP_FMADD, 1'b1, 3'd0,
           64'h7FF4_0000_0000_0000,            // a = sNaN.D
           64'h3FF0_0000_0000_0000,            // b = 1.0D
           64'h0000_0000_0000_0000);           // c = +0.D
    total++;
    if (result !== FP_CANON_QNAN_D || !fflags[FP_FFLAG_NV]) begin
      $error("sNaN.d fma: dut=%h flags=%b", result, fflags);
      errors++;
    end

    // ── Inf × finite (non-zero) -> ±Inf result ───────────────────────────
    // S-precision: +Inf × 1.0S + 0 → +Inf.S, no flags
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h7F80_0000},   // a = +Inf.S
           {FP_NANBOX_UPPER, 32'h3F80_0000},   // b = 1.0S
           {FP_NANBOX_UPPER, 32'h0000_0000});  // c = +0
    total++;
    if (result[31:0] !== 32'h7F80_0000 || fflags !== 5'b0) begin
      $error("inf*1.s fma: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end
    // D-precision: +Inf.D × 1.0D + 0 → +Inf.D, no flags
    apply5(FP_FMADD, 1'b1, 3'd0,
           64'h7FF0_0000_0000_0000,            // a = +Inf.D
           64'h3FF0_0000_0000_0000,            // b = 1.0D
           64'h0000_0000_0000_0000);           // c = +0.D
    total++;
    if (result !== 64'h7FF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("inf*1.d fma: dut=%h flags=%b", result, fflags);
      errors++;
    end

    // ── finite × finite + Inf addend -> ±Inf result ──────────────────────
    // S-precision: 1.0S × 1.0S + (+Inf.S) → +Inf.S, no flags
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h3F80_0000},   // a = 1.0S
           {FP_NANBOX_UPPER, 32'h3F80_0000},   // b = 1.0S
           {FP_NANBOX_UPPER, 32'h7F80_0000});  // c = +Inf.S
    total++;
    if (result[31:0] !== 32'h7F80_0000 || fflags !== 5'b0) begin
      $error("1*1+inf.s fma: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end
    // D-precision: 1.0D × 1.0D + (+Inf.D) → +Inf.D, no flags
    apply5(FP_FMADD, 1'b1, 3'd0,
           64'h3FF0_0000_0000_0000,            // a = 1.0D
           64'h3FF0_0000_0000_0000,            // b = 1.0D
           64'h7FF0_0000_0000_0000);           // c = +Inf.D
    total++;
    if (result !== 64'h7FF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("1*1+inf.d fma: dut=%h flags=%b", result, fflags);
      errors++;
    end

    // ── Exact zero result with negative product sign → -0 ───────────────
    // S-precision: FMADD(-0, 1.0, -0) — product = -0, addend = -0, same-sign add
    // → result = -0 (prod_sign = 1)
    apply5(FP_FMADD, 1'b0, 3'd0,
           {FP_NANBOX_UPPER, 32'h8000_0000},   // a = -0.S
           {FP_NANBOX_UPPER, 32'h3F80_0000},   // b = 1.0S
           {FP_NANBOX_UPPER, 32'h8000_0000});  // c = -0.S
    total++;
    if (result[31:0] !== 32'h8000_0000 || fflags !== 5'b0) begin
      $error("neg-zero fma: dut=%h flags=%b", result[31:0], fflags);
      errors++;
    end

    // ------- S-precision value checks (SoftFloat oracle) -------
    // 1.0 * 2.0 + 3.0 = 5.0
    check_s(FP_FMADD,  3'd0, 32'h3F80_0000, 32'h4000_0000, 32'h4040_0000, "s:1*2+3");
    // -1.0 * 1.0 + 2.0 = 1.0
    check_s(FP_FMADD,  3'd0, 32'hBF80_0000, 32'h3F80_0000, 32'h4000_0000, "s:-1*1+2");
    // 1.5 * 2.5 + 0.5 = 4.25
    check_s(FP_FMADD,  3'd0, 32'h3FC0_0000, 32'h4020_0000, 32'h3F00_0000, "s:1.5*2.5+.5");
    // FMSUB: 2.0 * 3.0 - 1.0 = 5.0
    check_s(FP_FMSUB,  3'd0, 32'h4000_0000, 32'h4040_0000, 32'h3F80_0000, "s:2*3-1");
    // FNMADD: -(1.0*2.0) + 5.0 = 3.0
    check_s(FP_FNMADD, 3'd0, 32'h3F80_0000, 32'h4000_0000, 32'h40A0_0000, "s:-(1*2)+5");
    // FNMSUB: -(1.0*2.0) - 3.0 = -5.0
    check_s(FP_FNMSUB, 3'd0, 32'h3F80_0000, 32'h4000_0000, 32'h4040_0000, "s:-(1*2)-3");

    // Cancellation: 1.0*1.0 + (-1.0) = 0.0
    check_s(FP_FMADD, 3'd0, 32'h3F80_0000, 32'h3F80_0000, 32'hBF80_0000, "s:cancel");

    // Inexact: 1.0/3 * 3 + 0 vs exact 1.0 (illustrative pattern)
    check_s(FP_FMADD, 3'd0, 32'h3EAA_AAAB, 32'h4040_0000, 32'h0000_0000, "s:inexact");

    // ------- D-precision checks -------
    // 1.0 * 2.0 + 3.0 = 5.0 (double)
    check_d(FP_FMADD, 3'd0,
            64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000,
            64'h4008_0000_0000_0000, "d:1*2+3");
    // 1.5 * 2.5 + 0.5 = 4.25
    check_d(FP_FMADD, 3'd0,
            64'h3FF8_0000_0000_0000, 64'h4004_0000_0000_0000,
            64'h3FE0_0000_0000_0000, "d:1.5*2.5+.5");
    // FMSUB d
    check_d(FP_FMSUB, 3'd0,
            64'h4000_0000_0000_0000, 64'h4008_0000_0000_0000,
            64'h3FF0_0000_0000_0000, "d:2*3-1");
    // FNMADD d
    check_d(FP_FNMADD, 3'd0,
            64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000,
            64'h4014_0000_0000_0000, "d:-(1*2)+5");
    // Cancellation double
    check_d(FP_FMADD, 3'd0,
            64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000,
            64'hBFF0_0000_0000_0000, "d:cancel");

    // ------- Gap 1: zero-sign edge cases for RUP and RMM -------
    // +0 * +0 + (-0) in RUP -> +0
    apply5(FP_FMADD, 1'b0, 3'd3,
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h8000_0000});
    total++;
    if (result[31:0] !== 32'h0000_0000) begin
      $error("0*0+(-0) RUP: dut=%h", result[31:0]);
      errors++;
    end

    // +0 * +0 + (-0) in RMM -> +0
    apply5(FP_FMADD, 1'b0, 3'd4,
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h0000_0000},
           {FP_NANBOX_UPPER, 32'h8000_0000});
    total++;
    if (result[31:0] !== 32'h0000_0000) begin
      $error("0*0+(-0) RMM: dut=%h", result[31:0]);
      errors++;
    end

    // ------- Gap 2: subnormal product + opposing-sign addend -------
    // a = 3*2^-127 (subnormal: 0x00C00000), b = 1.0, product = 3*2^-127 (subnormal)
    // c = -2^-127 (subnormal: 0x80400000); exact result = 3*2^-127 - 2^-127 = 2^-126 = 0x00800000
    // Verifies single-rounding: subnormal input in product path, normal result, exact (no flags)
    check_s(FP_FMADD, 3'd0, 32'h00C0_0000, 32'h3F80_0000, 32'h8040_0000,
            "s:subnorm_prod_neg_add");

    // ------- Gap 3: subnormal * subnormal product far below addend -------
    // a = b = 0x00000001 (min positive subnormal f32, value = 2^-149)
    // product = 2^-298, far below 1-ulp of any normal f32.
    // FMADD with c = 1.0: result = 1.0 (inexact), product rounds to 0 before add.
    check_s(FP_FMADD, 3'd0, 32'h0000_0001, 32'h0000_0001, 32'h3F80_0000,
            "s:subnorm_prod_below_1");
    // FMADD with c = -1.0: result = -1.0 (inexact), product rounds to 0 before add.
    check_s(FP_FMADD, 3'd0, 32'h0000_0001, 32'h0000_0001, 32'hBF80_0000,
            "s:subnorm_prod_below_neg1");

    // ------- Gap 4: random testing (200 per fmt/op/rm) -------
    // Operands are constrained to normal range (exponent in [1, 0xFE] for f32,
    // [1, 0x7FE] for f64) so that the product stays normal.
    begin
      int unsigned  raw32, sf_r32;
      longint unsigned raw64a, raw64b, raw64c, sf_r64;
      logic [31:0]  ra32, rb32, rc32;
      logic [63:0]  ra64, rb64, rc64;
      byte unsigned sf_f;
      int           rm_i, iter, op_i;
      logic [7:0]   e8;
      logic [10:0]  e11;
      fp_op_e       rand_op;
      for (rm_i = 0; rm_i < 5; rm_i++) begin
        for (op_i = 0; op_i < 4; op_i++) begin
          unique case (op_i)
            0: rand_op = FP_FMADD;
            1: rand_op = FP_FMSUB;
            2: rand_op = FP_FNMADD;
            3: rand_op = FP_FNMSUB;
            default: rand_op = FP_FMADD;
          endcase
          // ---- f32 random — normal operands, product stays normal ----
          // a and b exponents in [0x50, 0xB4] so that ea+eb-127 in [1, 0xE9] (always normal).
          // c exponent in [0x01, 0xFE] (any normal).
          for (iter = 0; iter < 200; iter++) begin
            e8    = 8'($urandom_range(32'hB4, 32'h50));
            raw32 = $urandom();
            ra32  = {raw32[31], e8, raw32[22:0]};
            e8    = 8'($urandom_range(32'hB4, 32'h50));
            raw32 = $urandom();
            rb32  = {raw32[31], e8, raw32[22:0]};
            e8    = 8'($urandom_range(32'hFE, 32'h01));
            raw32 = $urandom();
            rc32  = {raw32[31], e8, raw32[22:0]};
            apply5(rand_op, 1'b0, rm_i[2:0],
                   {FP_NANBOX_UPPER, ra32},
                   {FP_NANBOX_UPPER, rb32},
                   {FP_NANBOX_UPPER, rc32});
            sf_reset();
            unique case (rand_op)
              FP_FMADD:  sf_r32 = sf_f32_mulAdd(ra32, rb32, rc32, rm_i[7:0]);
              FP_FMSUB:  sf_r32 = sf_f32_mulAdd(ra32, rb32,
                                    {~rc32[31], rc32[30:0]}, rm_i[7:0]);
              FP_FNMADD: sf_r32 = sf_f32_mulAdd({~ra32[31], ra32[30:0]}, rb32,
                                    {~rc32[31], rc32[30:0]}, rm_i[7:0]);
              FP_FNMSUB: sf_r32 = sf_f32_mulAdd({~ra32[31], ra32[30:0]}, rb32,
                                    rc32, rm_i[7:0]);
              default:   sf_r32 = '0;
            endcase
            sf_f   = sf_exceptions();
            total++;
            if (result[31:0] !== sf_r32 || fflags !== sf_f[4:0]) begin
              $error("[rand_f32 op=%0d rm=%0d iter=%0d] dut=%h/%05b sf=%h/%05b a=%h b=%h c=%h",
                     op_i, rm_i, iter, result[31:0], fflags, sf_r32, sf_f[4:0],
                     ra32, rb32, rc32);
              errors++;
            end
          end
          // ---- f64 random — normal operands, product stays normal ----
          // a and b exponents in [0x200, 0x5FE] so ea+eb-1023 in [1, 0x7FB] (always normal).
          // c exponent in [0x001, 0x7FE] (any normal).
          for (iter = 0; iter < 200; iter++) begin
            e11   = 11'($urandom_range(32'h5FE, 32'h200));
            raw64a = {32'($urandom()), 32'($urandom())};
            ra64  = {raw64a[63], e11, raw64a[51:0]};
            e11   = 11'($urandom_range(32'h5FE, 32'h200));
            raw64b = {32'($urandom()), 32'($urandom())};
            rb64  = {raw64b[63], e11, raw64b[51:0]};
            e11   = 11'($urandom_range(32'h7FE, 32'h001));
            raw64c = {32'($urandom()), 32'($urandom())};
            rc64  = {raw64c[63], e11, raw64c[51:0]};
            apply5(rand_op, 1'b1, rm_i[2:0], ra64, rb64, rc64);
            sf_reset();
            unique case (rand_op)
              FP_FMADD:  sf_r64 = sf_f64_mulAdd(ra64, rb64, rc64, rm_i[7:0]);
              FP_FMSUB:  sf_r64 = sf_f64_mulAdd(ra64, rb64,
                                    {~rc64[63], rc64[62:0]}, rm_i[7:0]);
              FP_FNMADD: sf_r64 = sf_f64_mulAdd({~ra64[63], ra64[62:0]}, rb64,
                                    {~rc64[63], rc64[62:0]}, rm_i[7:0]);
              FP_FNMSUB: sf_r64 = sf_f64_mulAdd({~ra64[63], ra64[62:0]}, rb64,
                                    rc64, rm_i[7:0]);
              default:   sf_r64 = '0;
            endcase
            sf_f   = sf_exceptions();
            total++;
            if (result !== sf_r64 || fflags !== sf_f[4:0]) begin
              $error("[rand_f64 op=%0d rm=%0d iter=%0d] dut=%h/%05b sf=%h/%05b a=%h b=%h c=%h",
                     op_i, rm_i, iter, result, fflags, sf_r64, sf_f[4:0],
                     ra64, rb64, rc64);
              errors++;
            end
          end
        end
      end
    end

    if (errors) begin
      $fatal(1, "tb_fpu_fma: %0d/%0d errors", errors, total);
    end
    $display("tb_fpu_fma PASS (%0d checks)", total);
    $finish;
  end

endmodule
