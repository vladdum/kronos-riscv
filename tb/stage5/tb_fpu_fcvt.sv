// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_fcvt;
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
  logic [63:0] a;
  logic [63:0] b = '0;
  logic [63:0] c = '0;
  fpu_tag_t    tag_in = '{rd:5'd0, fp_dest:1'b0};

  logic        out_valid;
  logic [63:0] result;
  logic [4:0]  fflags;
  fpu_tag_t    tag_out;

  kronos_fpu_fcvt u_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .in_valid_i(in_valid), .op_i(op), .fmt_d_i(fmt_d), .rm_i(rm),
    .a_i(a), .b_i(b), .c_i(c), .tag_i(tag_in),
    .out_valid_o(out_valid), .result_o(result),
    .fflags_o(fflags), .tag_o(tag_out)
  );

  always #5 clk = ~clk;

  // Drive one operation, then wait for stage-2 output register to update
  task automatic apply_and_wait(input fp_op_e o, input logic fmtd,
                                input logic [2:0] r, input logic [63:0] ain);
    @(negedge clk);
    in_valid = 1'b1;
    op       = o;
    fmt_d    = fmtd;
    rm       = r;
    a        = ain;
    @(negedge clk);
    in_valid = 1'b0;
    // 2 more pos-edges for the data to propagate through both pipeline stages
    @(posedge clk);
    @(posedge clk);
    #1;
  endtask

  int errors = 0;
  int total  = 0;

  task automatic check_val(input string lbl,
                           input logic [63:0] exp_res,
                           input logic [4:0]  exp_flg);
    total++;
    if (result !== exp_res || fflags !== exp_flg) begin
      $error("[%s] dut=%h/%02h exp=%h/%02h", lbl, result, fflags, exp_res, exp_flg);
      errors++;
    end
  endtask

  int unsigned     sf_r32;
  longint          sf_r64s;
  int              sf_r32s;
  longint unsigned sf_r64;
  byte unsigned    sf_fl;

  initial begin
    sf_reset();
    #12 rst_n = 1;
    @(posedge clk);

    // ====================================================================
    // Directed tests for ops NOT covered by SoftFloat DPI:
    //   f64->int, int->fp, fp->fp (int->fp direction)
    // ====================================================================

    // ---------- FCVT.W.S directed edge cases ----------
    // NaN -> saturate to 0x7FFF_FFFF, NV
    apply_and_wait(FP_FCVT_W_F, 1'b0, 3'd0, 64'hFFFF_FFFF_7FC0_0000);
    check_val("fcvt.w.s NaN", 64'h0000_0000_7FFF_FFFF, 5'b10000);

    // +Inf -> saturate to 0x7FFF_FFFF, NV
    apply_and_wait(FP_FCVT_W_F, 1'b0, 3'd0, 64'hFFFF_FFFF_7F80_0000);
    check_val("fcvt.w.s +Inf", 64'h0000_0000_7FFF_FFFF, 5'b10000);

    // -Inf -> saturate to 0x8000_0000, NV
    apply_and_wait(FP_FCVT_W_F, 1'b0, 3'd0, 64'hFFFF_FFFF_FF80_0000);
    check_val("fcvt.w.s -Inf", 64'hFFFF_FFFF_8000_0000, 5'b10000);

    // ---------- FCVT.WU.S directed edge cases ----------
    // -1.5 -> saturate 0, NV
    apply_and_wait(FP_FCVT_WU_F, 1'b0, 3'd0, 64'hFFFF_FFFF_BFC0_0000);
    check_val("fcvt.wu.s -1.5", 64'h0, 5'b10000);

    // NaN -> 0xFFFF_FFFF, NV
    apply_and_wait(FP_FCVT_WU_F, 1'b0, 3'd0, 64'hFFFF_FFFF_7FC0_0000);
    check_val("fcvt.wu.s NaN", 64'hFFFF_FFFF_FFFF_FFFF, 5'b10000);

    // ---------- FCVT.L.S directed edge cases ----------
    // -Inf -> 0x8000_..., NV
    apply_and_wait(FP_FCVT_L_F, 1'b0, 3'd0, 64'hFFFF_FFFF_FF80_0000);
    check_val("fcvt.l.s -Inf", 64'h8000_0000_0000_0000, 5'b10000);

    // ---------- FCVT.LU.S directed edge cases ----------
    // NaN -> all-ones, NV
    apply_and_wait(FP_FCVT_LU_F, 1'b0, 3'd0, 64'hFFFF_FFFF_7FC0_0000);
    check_val("fcvt.lu.s NaN", 64'hFFFF_FFFF_FFFF_FFFF, 5'b10000);

    // ---------- FCVT.W.D (double -> signed 32) directed ----------
    // 1.0d -> 1, no flags
    apply_and_wait(FP_FCVT_W_F, 1'b1, 3'd0, 64'h3FF0_0000_0000_0000);
    check_val("fcvt.w.d 1.0", 64'h0000_0000_0000_0001, 5'b00000);

    // -2.5d RNE -> -2, NX
    apply_and_wait(FP_FCVT_W_F, 1'b1, 3'd0, 64'hC004_0000_0000_0000);
    check_val("fcvt.w.d -2.5 rne", 64'hFFFF_FFFF_FFFF_FFFE, 5'b00001);

    // ---------- FCVT.S.W (signed 32 -> single) directed ----------
    // -1 -> -1.0f (NaN-boxed)
    apply_and_wait(FP_FCVT_F_W, 1'b0, 3'd0, 64'hFFFF_FFFF_FFFF_FFFF);
    check_val("fcvt.s.w -1", 64'hFFFF_FFFF_BF80_0000, 5'b00000);

    // 1 -> 1.0f
    apply_and_wait(FP_FCVT_F_W, 1'b0, 3'd0, 64'h0000_0000_0000_0001);
    check_val("fcvt.s.w 1", 64'hFFFF_FFFF_3F80_0000, 5'b00000);

    // 0 -> +0.0f
    apply_and_wait(FP_FCVT_F_W, 1'b0, 3'd0, 64'h0);
    check_val("fcvt.s.w 0", 64'hFFFF_FFFF_0000_0000, 5'b00000);

    // 2 -> 2.0f
    apply_and_wait(FP_FCVT_F_W, 1'b0, 3'd0, 64'h0000_0000_0000_0002);
    check_val("fcvt.s.w 2", 64'hFFFF_FFFF_4000_0000, 5'b00000);

    // ---------- FCVT.S.WU directed ----------
    // 0xFFFF_FFFF -> 4294967295.0f rounded -> 0x4F800000 (2^32), NX
    apply_and_wait(FP_FCVT_F_WU, 1'b0, 3'd0, 64'hFFFF_FFFF_FFFF_FFFF);
    check_val("fcvt.s.wu UMAX", 64'hFFFF_FFFF_4F80_0000, 5'b00001);

    // ---------- FCVT.D.W directed ----------
    // 1 -> 1.0d
    apply_and_wait(FP_FCVT_F_W, 1'b1, 3'd0, 64'h0000_0000_0000_0001);
    check_val("fcvt.d.w 1", 64'h3FF0_0000_0000_0000, 5'b00000);

    // -1 -> -1.0d
    apply_and_wait(FP_FCVT_F_W, 1'b1, 3'd0, 64'hFFFF_FFFF_FFFF_FFFF);
    check_val("fcvt.d.w -1", 64'hBFF0_0000_0000_0000, 5'b00000);

    // ---------- FCVT.D.L directed ----------
    // 1 -> 1.0d
    apply_and_wait(FP_FCVT_F_L, 1'b1, 3'd0, 64'h0000_0000_0000_0001);
    check_val("fcvt.d.l 1", 64'h3FF0_0000_0000_0000, 5'b00000);

    // ---------- FCVT.D.LU directed ----------
    // 1 -> 1.0d
    apply_and_wait(FP_FCVT_F_LU, 1'b1, 3'd0, 64'h0000_0000_0000_0001);
    check_val("fcvt.d.lu 1", 64'h3FF0_0000_0000_0000, 5'b00000);
    // ULONG_MAX (0xFFFFFFFFFFFFFFFF) -> 1.8446744e19 ~ 0x43F0000000000000
    apply_and_wait(FP_FCVT_F_LU, 1'b1, 3'd0, 64'hFFFF_FFFF_FFFF_FFFF);
    check_val("fcvt.d.lu umax", 64'h43F0_0000_0000_0000, 5'b00001);  // NX (inexact)

    // ---------- FCVT.D.S directed ----------
    // 1.0f (NaN-boxed) -> 1.0d (exact)
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_3F80_0000);
    check_val("fcvt.d.s 1.0", 64'h3FF0_0000_0000_0000, 5'b00000);

    // -2.0f -> -2.0d
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_C000_0000);
    check_val("fcvt.d.s -2.0", 64'hC000_0000_0000_0000, 5'b00000);

    // +0f -> +0d
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_0000_0000);
    check_val("fcvt.d.s +0", 64'h0, 5'b00000);

    // +Inf.S -> +Inf.D (special: exp=0xFF, mant=0)
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_7F80_0000);
    check_val("fcvt.d.s +inf", 64'h7FF0_0000_0000_0000, 5'b00000);

    // -Inf.S -> -Inf.D
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_FF80_0000);
    check_val("fcvt.d.s -inf", 64'hFFF0_0000_0000_0000, 5'b00000);

    // sNaN.S -> canonical qNaN.D, NV flag
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_7FA0_0000);
    check_val("fcvt.d.s sNaN", 64'h7FF8_0000_0000_0000, 5'b10000);

    // qNaN.S -> canonical qNaN.D, no NV
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_7FC0_0000);
    check_val("fcvt.d.s qNaN", 64'h7FF8_0000_0000_0000, 5'b00000);

    // Subnormal.S (0x0040_0000 = 2^-127) -> normalized double (2^-127 = 0x3800...)
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'hFFFF_FFFF_0040_0000);
    check_val("fcvt.d.s subnorm", 64'h3800_0000_0000_0000, 5'b00000);

    // Bad NaN-box: upper bits != FFFF_FFFF → treated as qNaN.S → qNaN.D
    apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, 64'h0000_0000_3F80_0000);
    check_val("fcvt.d.s nan-unbox", 64'h7FF8_0000_0000_0000, 5'b00000);

    // ---------- FCVT.S.D directed — special cases ----------
    // +Inf.D -> +Inf.S (NaN-boxed), no flags
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'h7FF0_0000_0000_0000);
    check_val("fcvt.s.d +inf", 64'hFFFF_FFFF_7F80_0000, 5'b00000);

    // -Inf.D -> -Inf.S (NaN-boxed), no flags
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'hFFF0_0000_0000_0000);
    check_val("fcvt.s.d -inf", 64'hFFFF_FFFF_FF80_0000, 5'b00000);

    // qNaN.D -> canonical qNaN.S (NaN-boxed), no NV
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'h7FF8_0000_0000_0000);
    check_val("fcvt.s.d qNaN", 64'hFFFF_FFFF_7FC0_0000, 5'b00000);

    // sNaN.D -> canonical qNaN.S (NaN-boxed), NV flag
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'h7FF4_0000_0000_0000);
    check_val("fcvt.s.d sNaN", 64'hFFFF_FFFF_7FC0_0000, 5'b10000);

    // Overflow: 2^200 in double (biased exp=1223) -> +Inf single (RNE), OF+NX
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'h4C70_0000_0000_0000);
    check_val("fcvt.s.d overflow", 64'hFFFF_FFFF_7F80_0000, 5'b00101);

    // Underflow: 2^-200 in double (biased exp=823) -> +0 single, UF+NX
    apply_and_wait(FP_FCVT_S_D, 1'b0, 3'd0, 64'h3370_0000_0000_0000);
    check_val("fcvt.s.d underflow", 64'hFFFF_FFFF_0000_0000, 5'b00011);

    // ====================================================================
    // SoftFloat DPI random differential testing
    // 100 random inputs x 5 rounding modes = 500 checks per operation
    // ====================================================================

    // ---------- FCVT.W.S random (f32 -> signed int32) ----------
    begin : blk_rand_fcvt_w_s
      logic [31:0]  ra;
      int           sf_i32;
      logic [63:0]  expres;
      byte unsigned sf_f;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 100; k++) begin
          ra     = $urandom;
          sf_reset();
          sf_i32 = sf_f32_to_i32(ra, rm_i[7:0]);
          sf_f   = sf_exceptions();
          apply_and_wait(FP_FCVT_W_F, 1'b0, rm_i[2:0], {32'hFFFF_FFFF, ra});
          expres = {{32{sf_i32[31]}}, sf_i32};
          total++;
          if (result !== expres || fflags !== sf_f[4:0]) begin
            $error("[fcvt.w.s rm%0d #%0d] a=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, k, ra, result, fflags, expres, sf_f);
            errors++;
          end
        end
      end
    end

    // ---------- FCVT.WU.S random (f32 -> unsigned int32) ----------
    begin : blk_rand_fcvt_wu_s
      logic [31:0]  ra;
      int unsigned  sf_u32;
      logic [63:0]  expres;
      byte unsigned sf_f;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 100; k++) begin
          ra     = $urandom;
          sf_reset();
          sf_u32 = sf_f32_to_ui32(ra, rm_i[7:0]);
          sf_f   = sf_exceptions();
          apply_and_wait(FP_FCVT_WU_F, 1'b0, rm_i[2:0], {32'hFFFF_FFFF, ra});
          // RISC-V sign-extends the 32-bit result to 64 bits
          expres = {{32{sf_u32[31]}}, sf_u32};
          total++;
          if (result !== expres || fflags !== sf_f[4:0]) begin
            $error("[fcvt.wu.s rm%0d #%0d] a=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, k, ra, result, fflags, expres, sf_f);
            errors++;
          end
        end
      end
    end

    // ---------- FCVT.L.S random (f32 -> signed int64) ----------
    begin : blk_rand_fcvt_l_s
      logic [31:0]     ra;
      longint          sf_i64;
      logic [63:0]     expres;
      byte unsigned    sf_f;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 100; k++) begin
          ra     = $urandom;
          sf_reset();
          sf_i64 = sf_f32_to_i64(ra, rm_i[7:0]);
          sf_f   = sf_exceptions();
          apply_and_wait(FP_FCVT_L_F, 1'b0, rm_i[2:0], {32'hFFFF_FFFF, ra});
          expres = sf_i64;
          total++;
          if (result !== expres || fflags !== sf_f[4:0]) begin
            $error("[fcvt.l.s rm%0d #%0d] a=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, k, ra, result, fflags, expres, sf_f);
            errors++;
          end
        end
      end
    end

    // ---------- FCVT.LU.S random (f32 -> unsigned int64) ----------
    begin : blk_rand_fcvt_lu_s
      logic [31:0]     ra;
      longint unsigned sf_u64;
      byte unsigned    sf_f;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 100; k++) begin
          ra    = $urandom;
          sf_reset();
          sf_u64 = sf_f32_to_ui64(ra, rm_i[7:0]);
          sf_f   = sf_exceptions();
          apply_and_wait(FP_FCVT_LU_F, 1'b0, rm_i[2:0], {32'hFFFF_FFFF, ra});
          total++;
          if (result !== sf_u64 || fflags !== sf_f[4:0]) begin
            $error("[fcvt.lu.s rm%0d #%0d] a=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, k, ra, result, fflags, sf_u64, sf_f);
            errors++;
          end
        end
      end
    end

    // ---------- FCVT.S.D random (f64 -> f32) ----------
    // Restrict inputs to f64 values whose magnitude maps to a normal f32 result
    // (f64 exponent in [897..1150] = f32 exponent range [1..254]).
    // This avoids testing denormal/underflow/overflow edge cases which are
    // better covered by directed tests.
    begin : blk_rand_fcvt_s_d
      logic [63:0]  da;
      logic [10:0]  f64_exp;
      int unsigned  sf_f32r;
      logic [63:0]  expres;
      byte unsigned sf_f;
      int           k;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        k = 0;
        while (k < 100) begin
          da      = {$urandom, $urandom};
          f64_exp = da[62:52];
          // Skip NaN, Inf, and values that would produce f32 denormal or overflow.
          // f64 exponent 897..1150 maps to f32 biased exponent 1..254 (normal range).
          if (f64_exp < 11'd897 || f64_exp > 11'd1150) continue;
          sf_reset();
          sf_f32r = sf_f64_to_f32(da, rm_i[7:0]);
          sf_f    = sf_exceptions();
          // fmt_d_i=0: output format is single (converting TO single)
          apply_and_wait(FP_FCVT_S_D, 1'b0, rm_i[2:0], da);
          expres  = {32'hFFFF_FFFF, sf_f32r};
          total++;
          if (result !== expres || fflags !== sf_f[4:0]) begin
            $error("[fcvt.s.d rm%0d #%0d] a=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, k, da, result, fflags, expres, sf_f);
            errors++;
          end
          k++;
        end
      end
    end

    // ---------- FCVT.D.S random (f32 -> f64, exact, no rounding) ----------
    begin : blk_rand_fcvt_d_s
      logic [31:0]     ra;
      longint unsigned sf_f64r;
      for (int k = 0; k < 100; k++) begin
        ra      = $urandom;
        sf_reset();
        sf_f64r = sf_f32_to_f64(ra);
        // fmt_d_i=1: output format is double
        apply_and_wait(FP_FCVT_D_S, 1'b1, 3'd0, {32'hFFFF_FFFF, ra});
        total++;
        if (result !== sf_f64r || fflags !== 5'b0) begin
          $error("[fcvt.d.s #%0d] a=%h dut=%h/%02h sf=%h/00",
                 k, ra, result, fflags, sf_f64r);
          errors++;
        end
      end
    end

    if (errors != 0) $fatal(1, "tb_fpu_fcvt: %0d error(s) out of %0d", errors, total);
    $display("tb_fpu_fcvt PASS (%0d checks)", total);
    $finish;
  end

endmodule
