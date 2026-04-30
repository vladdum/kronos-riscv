// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_fmul;
  import kronos_pkg::*;
  import softfloat_dpi_pkg::*;
  import fp_tb_pkg::*;

  logic        clk = 0, rst_n = 0, flush = 0;
  logic        in_valid = 0;
  fp_op_e      op;
  logic        fmt_d;
  logic [2:0]  rm;
  logic [63:0] a, b, c = '0;
  fpu_tag_t    tag_in = '{rd:0, fp_dest:0};
  logic        out_valid;
  logic [63:0] result;
  logic [4:0]  fflags;
  fpu_tag_t    tag_out;

  kronos_fpu_fmul u_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .in_valid_i(in_valid), .fmt_d_i(fmt_d), .rm_i(rm),
    .a_i(a), .b_i(b), .tag_i(tag_in),
    .out_valid_o(out_valid), .result_o(result), .fflags_o(fflags), .tag_o(tag_out)
  );

  always #5 clk = ~clk;

  task automatic apply4(input fp_op_e o, logic fmtd, logic [2:0] r,
                        input logic [63:0] ain, bin);
    @(negedge clk); in_valid=1; op=o; fmt_d=fmtd; rm=r; a=ain; b=bin;
    @(negedge clk); in_valid=0;
    repeat(8) @(posedge clk); #1;
  endtask

  int errors = 0, total = 0;

  initial begin
    sf_reset();
    #12 rst_n = 1;

    // f32_mul vectors
    begin : blk_f32
      int fd; string line; fp_vec_t v;
      fd = $fopen("../tb/stage5/testfloat_vectors/f32_mul_rne.txt", "r");
      while (!$feof(fd)) begin
        int unsigned sf_r;
        byte unsigned sf_f;
        longint unsigned expected;
        void'($fgets(line, fd));
        if (!parse_vec_line(line, v)) continue;
        apply4(FP_FMUL, 1'b0, v.rm[2:0],
               {32'hFFFF_FFFF, v.a[31:0]}, {32'hFFFF_FFFF, v.b[31:0]});
        sf_reset();
        sf_r = sf_f32_mul(v.a[31:0], v.b[31:0], v.rm);
        sf_f = sf_exceptions();
        expected = {32'hFFFF_FFFF, sf_r};
        if (!two_way_check("f32_mul", v.a, v.b, 0, v.rm, result, expected,
                           8'(fflags), 8'(sf_f[4:0])))
          errors++;
        total++;
      end
      $fclose(fd);
    end

    // f64_mul vectors
    begin : blk_f64
      int fd; string line; fp_vec_t v;
      fd = $fopen("../tb/stage5/testfloat_vectors/f64_mul_rne.txt", "r");
      while (!$feof(fd)) begin
        longint unsigned sf_r;
        byte unsigned sf_f;
        void'($fgets(line, fd));
        if (!parse_vec_line(line, v)) continue;
        apply4(FP_FMUL, 1'b1, v.rm[2:0], v.a, v.b);
        sf_reset();
        sf_r = sf_f64_mul(v.a, v.b, v.rm);
        sf_f = sf_exceptions();
        if (!two_way_check("f64_mul", v.a, v.b, 0, v.rm, result, sf_r,
                           8'(fflags), 8'(sf_f[4:0])))
          errors++;
        total++;
      end
      $fclose(fd);
    end

    // Random: all 5 RMs for F32 MUL and F64 MUL
    begin : blk_random_fmul
      logic [31:0]     ra, rb;
      logic [63:0]     da, db;
      int unsigned     sf_r32;
      longint unsigned sf_r64;
      byte unsigned    sf_f;
      logic [63:0]     expected;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 200; k++) begin
          ra = $urandom; rb = $urandom;
          apply4(FP_FMUL, 1'b0, rm_i[2:0],
                 {32'hFFFF_FFFF, ra}, {32'hFFFF_FFFF, rb});
          sf_reset();
          sf_r32 = sf_f32_mul(ra, rb, rm_i);
          sf_f = sf_exceptions();
          expected = {32'hFFFF_FFFF, sf_r32};
          total++;
          if (result !== expected || fflags !== sf_f[4:0]) begin
            $error("[f32_mul_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, ra, rb, result, fflags, expected, sf_f);
            errors++;
          end
        end
        for (int k = 0; k < 200; k++) begin
          da = {$urandom, $urandom}; db = {$urandom, $urandom};
          apply4(FP_FMUL, 1'b1, rm_i[2:0], da, db);
          sf_reset();
          sf_r64 = sf_f64_mul(da, db, rm_i);
          sf_f = sf_exceptions();
          total++;
          if (result !== sf_r64 || fflags !== sf_f[4:0]) begin
            $error("[f64_mul_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, da, db, result, fflags, sf_r64, sf_f);
            errors++;
          end
        end
      end
    end

    // Directed: +Inf.S × 1.0S → +Inf.S, no flags  [covers s4_res_is_inf_q path]
    apply4(FP_FMUL, 1'b0, 3'd0,
           {32'hFFFF_FFFF, 32'h7F80_0000},
           {32'hFFFF_FFFF, 32'h3F80_0000});
    total++;
    if (result !== 64'hFFFF_FFFF_7F80_0000 || fflags !== 5'b0) begin
      $error("inf.s*1.s: dut=%h/%b", result, fflags); errors++;
    end

    // Directed: -Inf.D × 2.0D → -Inf.D, no flags
    apply4(FP_FMUL, 1'b1, 3'd0,
           64'hFFF0_0000_0000_0000,
           64'h4000_0000_0000_0000);
    total++;
    if (result !== 64'hFFF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("inf.d*2.d: dut=%h/%b", result, fflags); errors++;
    end

    // F32 subnormal × near-2.0 → min_normal (subn→norm, exp_in=0)  [covers line 774]
    // a=0x00400000 (subnormal 2^-127), b=0x3FFFFFFF (≈1.9999999)
    // product = (2^24-1)×2^-150 = midpoint(max_subn, min_norm) → rounds to min_norm (RNE)
    // DUT uses tininess-after-rounding: result is min_normal (not subnormal) → UF not set
    begin : blk_fmul_subn_norm_s
      apply4(FP_FMUL, 1'b0, 3'd0,
             {32'hFFFF_FFFF, 32'h0040_0000},
             {32'hFFFF_FFFF, 32'h3FFF_FFFF});
      total++;
      if (result !== {32'hFFFF_FFFF, 32'h0080_0000} || fflags !== 5'b00001) begin
        $error("fmul.s subn->norm: dut=%h/%02h expected ffffffff00800000/01",
               result, fflags); errors++;
      end
    end

    // F64 subnormal→normal via SoftFloat oracle  [covers lines 762-763]
    begin : blk_fmul_subn_norm_d
      longint unsigned sf_r;
      byte unsigned    sf_f;
      sf_reset();
      sf_r = sf_f64_mul(64'h000F_FFFF_FFFF_FFFF, 64'h3FF0_0000_0000_0001, 8'd0);
      sf_f = sf_exceptions();
      apply4(FP_FMUL, 1'b1, 3'd0,
             64'h000F_FFFF_FFFF_FFFF,
             64'h3FF0_0000_0000_0001);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fmul.d subn->norm: dut=%h/%02h sf=%h/%02h",
               result, fflags, sf_r, sf_f); errors++;
      end
    end

    // ---- Directed: invalid rm=5 for FMUL  [covers lines 695-696 default] ----
    // (1/3) * 10.0 = 3.333...: inexact with rm=5 (default→round_up=0 / RTZ-like)
    begin : blk_fmul_rm5
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_mul(64'h3FD5_5555_5555_5555, 64'h4024_0000_0000_0000, 8'd1);
      sf_f = sf_exceptions();
      apply4(FP_FMUL, 1'b1, 3'd5,
             64'h3FD5_5555_5555_5555, 64'h4024_0000_0000_0000);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fmul.d rm5: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    if (errors != 0) $fatal(1, "tb_fpu_fmul: %0d/%0d mismatches", errors, total);
    $display("tb_fpu_fmul PASS (%0d vectors)", total);
    $finish;
  end

endmodule
