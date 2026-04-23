// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_fadd;
  import kronos_pkg::*;
  import softfloat_dpi_pkg::*;

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

  kronos_fpu_fadd u_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .in_valid_i(in_valid), .op_i(op), .fmt_d_i(fmt_d), .rm_i(rm),
    .a_i(a), .b_i(b), .c_i(c), .tag_i(tag_in),
    .out_valid_o(out_valid), .result_o(result), .fflags_o(fflags), .tag_o(tag_out)
  );

  always #5 clk = ~clk;

  // Drive inputs for one cycle, then wait for output to emerge after 6 cycles.
  task automatic apply6(input fp_op_e o, input logic fmtd, input logic [2:0] r,
                        input logic [63:0] ain, input logic [63:0] bin);
    @(negedge clk);
    in_valid = 1;
    op       = o;
    fmt_d    = fmtd;
    rm       = r;
    a        = ain;
    b        = bin;
    @(negedge clk);
    in_valid = 0;
    // Seven pipeline stages (S1..S2b..S3b..S4..S5) → sample after 7 posedges.
    repeat (7) @(posedge clk);
    #1;
  endtask

  int errors = 0;
  int total  = 0;

  initial begin
    sf_reset();
    #12 rst_n = 1;

    // --------------------------------------------------------------------
    // F32 ADD vectors
    // --------------------------------------------------------------------
    begin : blk_f32_add
      int               fd;
      string            line;
      fp_tb_pkg::fp_vec_t v;
      int unsigned      sf_r;
      byte unsigned     sf_f;
      logic [63:0]      expected;
      fd = $fopen("../tb/stage5/testfloat_vectors/f32_add_rne.txt", "r");
      if (fd == 0) $fatal(1, "cannot open f32_add_rne.txt");
      while (!$feof(fd)) begin
        line = "";
        void'($fgets(line, fd));
        if (!fp_tb_pkg::parse_vec_line(line, v)) continue;
        apply6(FP_FADD, 1'b0, v.rm[2:0],
               {32'hFFFF_FFFF, v.a[31:0]},
               {32'hFFFF_FFFF, v.b[31:0]});
        sf_reset();
        sf_r = sf_f32_add(v.a[31:0], v.b[31:0], v.rm);
        sf_f = sf_exceptions();
        expected = {32'hFFFF_FFFF, sf_r};
        total++;
        if (result !== expected || fflags !== sf_f[4:0]) begin
          $error("[f32_add] a=%h b=%h rm=%0d dut=%h/%02h sf=%h/%02h",
                 v.a[31:0], v.b[31:0], v.rm, result, fflags, expected, sf_f);
          errors++;
        end
      end
      $fclose(fd);
    end

    // --------------------------------------------------------------------
    // F32 SUB vectors (reuse f32_sub_rne.txt via FP_FSUB)
    // --------------------------------------------------------------------
    begin : blk_f32_sub
      int               fd;
      string            line;
      fp_tb_pkg::fp_vec_t v;
      int unsigned      sf_r;
      byte unsigned     sf_f;
      logic [63:0]      expected;
      fd = $fopen("../tb/stage5/testfloat_vectors/f32_sub_rne.txt", "r");
      if (fd == 0) $fatal(1, "cannot open f32_sub_rne.txt");
      while (!$feof(fd)) begin
        line = "";
        void'($fgets(line, fd));
        if (!fp_tb_pkg::parse_vec_line(line, v)) continue;
        apply6(FP_FSUB, 1'b0, v.rm[2:0],
               {32'hFFFF_FFFF, v.a[31:0]},
               {32'hFFFF_FFFF, v.b[31:0]});
        sf_reset();
        sf_r = sf_f32_sub(v.a[31:0], v.b[31:0], v.rm);
        sf_f = sf_exceptions();
        expected = {32'hFFFF_FFFF, sf_r};
        total++;
        if (result !== expected || fflags !== sf_f[4:0]) begin
          $error("[f32_sub] a=%h b=%h rm=%0d dut=%h/%02h sf=%h/%02h",
                 v.a[31:0], v.b[31:0], v.rm, result, fflags, expected, sf_f);
          errors++;
        end
      end
      $fclose(fd);
    end

    // --------------------------------------------------------------------
    // F64 ADD vectors
    // --------------------------------------------------------------------
    begin : blk_f64_add
      int               fd;
      string            line;
      fp_tb_pkg::fp_vec_t v;
      longint unsigned  sf_r;
      byte unsigned     sf_f;
      fd = $fopen("../tb/stage5/testfloat_vectors/f64_add_rne.txt", "r");
      if (fd == 0) $fatal(1, "cannot open f64_add_rne.txt");
      while (!$feof(fd)) begin
        line = "";
        void'($fgets(line, fd));
        if (!fp_tb_pkg::parse_vec_line(line, v)) continue;
        apply6(FP_FADD, 1'b1, v.rm[2:0], v.a, v.b);
        sf_reset();
        sf_r = sf_f64_add(v.a, v.b, v.rm);
        sf_f = sf_exceptions();
        total++;
        if (result !== sf_r || fflags !== sf_f[4:0]) begin
          $error("[f64_add] a=%h b=%h rm=%0d dut=%h/%02h sf=%h/%02h",
                 v.a, v.b, v.rm, result, fflags, sf_r, sf_f);
          errors++;
        end
      end
      $fclose(fd);
    end

    // --------------------------------------------------------------------
    // Random differential: all 5 RMs for F32 ADD/SUB and F64 ADD/SUB
    // --------------------------------------------------------------------
    begin : blk_random_fadd
      logic [31:0]     ra, rb;
      logic [63:0]     da, db;
      int unsigned     sf_r32;
      longint unsigned sf_r64;
      byte unsigned    sf_f;
      logic [63:0]     expected;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        // F32 ADD random
        for (int k = 0; k < 200; k++) begin
          ra = $urandom; rb = $urandom;
          apply6(FP_FADD, 1'b0, rm_i[2:0],
                 {32'hFFFF_FFFF, ra}, {32'hFFFF_FFFF, rb});
          sf_reset();
          sf_r32 = sf_f32_add(ra, rb, rm_i);
          sf_f = sf_exceptions();
          expected = {32'hFFFF_FFFF, sf_r32};
          total++;
          if (result !== expected || fflags !== sf_f[4:0]) begin
            $error("[f32_add_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, ra, rb, result, fflags, expected, sf_f);
            errors++;
          end
        end
        // F32 SUB random
        for (int k = 0; k < 200; k++) begin
          ra = $urandom; rb = $urandom;
          apply6(FP_FSUB, 1'b0, rm_i[2:0],
                 {32'hFFFF_FFFF, ra}, {32'hFFFF_FFFF, rb});
          sf_reset();
          sf_r32 = sf_f32_sub(ra, rb, rm_i);
          sf_f = sf_exceptions();
          expected = {32'hFFFF_FFFF, sf_r32};
          total++;
          if (result !== expected || fflags !== sf_f[4:0]) begin
            $error("[f32_sub_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, ra, rb, result, fflags, expected, sf_f);
            errors++;
          end
        end
        // F64 ADD random
        for (int k = 0; k < 200; k++) begin
          da = {$urandom, $urandom}; db = {$urandom, $urandom};
          apply6(FP_FADD, 1'b1, rm_i[2:0], da, db);
          sf_reset();
          sf_r64 = sf_f64_add(da, db, rm_i);
          sf_f = sf_exceptions();
          total++;
          if (result !== sf_r64 || fflags !== sf_f[4:0]) begin
            $error("[f64_add_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, da, db, result, fflags, sf_r64, sf_f);
            errors++;
          end
        end
        // F64 SUB random
        for (int k = 0; k < 200; k++) begin
          da = {$urandom, $urandom}; db = {$urandom, $urandom};
          apply6(FP_FSUB, 1'b1, rm_i[2:0], da, db);
          sf_reset();
          sf_r64 = sf_f64_sub(da, db, rm_i);
          sf_f = sf_exceptions();
          total++;
          if (result !== sf_r64 || fflags !== sf_f[4:0]) begin
            $error("[f64_sub_rm%0d] a=%h b=%h dut=%h/%02h sf=%h/%02h",
                   rm_i, da, db, result, fflags, sf_r64, sf_f);
            errors++;
          end
        end
      end
    end

    // ── Directed: Inf + finite → Inf propagation ─────────────────────────
    // +Inf.S + 1.0S → +Inf.S (NaN-boxed), no flags
    apply6(FP_FADD, 1'b0, 3'd0,
           {32'hFFFF_FFFF, 32'h7F80_0000},
           {32'hFFFF_FFFF, 32'h3F80_0000});
    total++;
    if (result !== 64'hFFFF_FFFF_7F80_0000 || fflags !== 5'b0) begin
      $error("inf+1.s: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // 1.0S + (-Inf.S) → -Inf.S (NaN-boxed), no flags
    apply6(FP_FADD, 1'b0, 3'd0,
           {32'hFFFF_FFFF, 32'h3F80_0000},
           {32'hFFFF_FFFF, 32'hFF80_0000});
    total++;
    if (result !== 64'hFFFF_FFFF_FF80_0000 || fflags !== 5'b0) begin
      $error("1+(-inf).s: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // +Inf.D + 1.0D → +Inf.D, no flags
    apply6(FP_FADD, 1'b1, 3'd0,
           64'h7FF0_0000_0000_0000,
           64'h3FF0_0000_0000_0000);
    total++;
    if (result !== 64'h7FF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("inf+1.d: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // 1.0D + (-Inf.D) → -Inf.D, no flags
    apply6(FP_FADD, 1'b1, 3'd0,
           64'h3FF0_0000_0000_0000,
           64'hFFF0_0000_0000_0000);
    total++;
    if (result !== 64'hFFF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("1+(-inf).d: dut=%h flags=%b", result, fflags);
      errors++;
    end

    // ---- Directed: carry-up rounding  [covers lines 722-724] ----
    // F64: 0x3FFFFFFFFFFFFFFF + 0x3CA0000000000000 rounds to 2.0 in RNE
    begin : blk_fadd_carry_d
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h3FFF_FFFF_FFFF_FFFF, 64'h3CA0_0000_0000_0000, 8'd0);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd0,
             64'h3FFF_FFFF_FFFF_FFFF, 64'h3CA0_0000_0000_0000);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d carry_up: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    // F32: 0x3FFFFFFF + 0x33800000 (with NaN-boxing) → carry-up to 2.0f
    begin : blk_fadd_carry_s
      int unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f32_add(32'h3FFF_FFFF, 32'h3380_0000, 8'd0);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b0, 3'd0,
             {32'hFFFF_FFFF, 32'h3FFF_FFFF},
             {32'hFFFF_FFFF, 32'h3380_0000});
      total++;
      if (result !== {32'hFFFF_FFFF, sf_r} || fflags !== sf_f[4:0]) begin
        $error("fadd.s carry_up: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    // ---- Directed: overflow RM variants  [covers lines 775-792] ----
    // F32 overflow RDN positive → FLT_MAX  [covers line 791: else branch for F32 to_inf=false]
    begin : blk_fadd_ovf_f32_rdn_pos
      int unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f32_add(32'h7F7F_FFFF, 32'h7F7F_FFFF, 8'd2);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b0, 3'd2,
             {32'hFFFF_FFFF, 32'h7F7F_FFFF},
             {32'hFFFF_FFFF, 32'h7F7F_FFFF});
      total++;
      if (result !== {32'hFFFF_FFFF, sf_r} || fflags !== sf_f[4:0]) begin
        $error("fadd.s ovf RDN+: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    // RTZ positive → DBL_MAX
    begin : blk_fadd_ovf_rtz
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF, 8'd1);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd1,
             64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RTZ+: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    // RDN positive → DBL_MAX, negative → -Inf
    begin : blk_fadd_ovf_rdn_pos
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF, 8'd2);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd2,
             64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RDN+: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    begin : blk_fadd_ovf_rdn_neg
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'hFFEF_FFFF_FFFF_FFFF, 64'hFFEF_FFFF_FFFF_FFFF, 8'd2);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd2,
             64'hFFEF_FFFF_FFFF_FFFF, 64'hFFEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RDN-: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    // RUP positive → +Inf, negative → -DBL_MAX
    begin : blk_fadd_ovf_rup_pos
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF, 8'd3);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd3,
             64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RUP+: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    begin : blk_fadd_ovf_rup_neg
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'hFFEF_FFFF_FFFF_FFFF, 64'hFFEF_FFFF_FFFF_FFFF, 8'd3);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd3,
             64'hFFEF_FFFF_FFFF_FFFF, 64'hFFEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RUP-: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end
    // RMM → +Inf
    begin : blk_fadd_ovf_rmm
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF, 8'd4);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd4,
             64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d ovf RMM: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    // ---- Directed: F32 subnormal result  [covers lines 610-632] ----
    // 0x00800001 + (-0x00800000) → 0x00000001 (denorm, NX+UF)
    begin : blk_fadd_subn_s
      int unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f32_add(32'h0080_0001, 32'h8080_0000, 8'd0);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b0, 3'd0,
             {32'hFFFF_FFFF, 32'h0080_0001},
             {32'hFFFF_FFFF, 32'h8080_0000});
      total++;
      if (result !== {32'hFFFF_FFFF, sf_r} || fflags !== sf_f[4:0]) begin
        $error("fadd.s subn: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    // ---- Directed: flush mid-pipeline  [covers lines 828-833] ----
    begin : blk_fadd_flush
      @(negedge clk); in_valid=1; op=FP_FADD; fmt_d=1'b1; rm=3'd0;
                      a=64'h3FF0_0000_0000_0000; b=64'h3FF0_0000_0000_0000;
      @(negedge clk); in_valid=0; flush=1;
      @(negedge clk); flush=0;
      repeat(6) @(posedge clk); #1;
      if (out_valid) begin
        $error("fadd flush: out_valid still asserted after flush"); errors++;
      end
    end

    // ---- Directed: invalid rm=5 inexact  [covers line 712 default] ----
    // 1.0 + 2^-53: with rm=5 (default→round_up=0 / RTZ), result = 1.0 (truncate)
    begin : blk_fadd_rm5_inexact
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h3FF0_0000_0000_0000, 64'h3CA0_0000_0000_0000, 8'd1);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd5,
             64'h3FF0_0000_0000_0000, 64'h3CA0_0000_0000_0000);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d rm5 inexact: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    // ---- Directed: invalid rm=5 overflow  [covers line 786 default] ----
    // DBL_MAX + DBL_MAX: with rm=5 (default→to_inf=1), same as RNE → +Inf
    begin : blk_fadd_rm5_ovf
      longint unsigned sf_r; byte unsigned sf_f;
      sf_reset();
      sf_r = sf_f64_add(64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF, 8'd0);
      sf_f = sf_exceptions();
      apply6(FP_FADD, 1'b1, 3'd5,
             64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF);
      total++;
      if (result !== sf_r || fflags !== sf_f[4:0]) begin
        $error("fadd.d rm5 ovf: dut=%h/%b sf=%h/%b", result, fflags, sf_r, sf_f); errors++;
      end
    end

    if (errors) $fatal(1, "tb_fpu_fadd: %0d/%0d mismatches", errors, total);
    $display("tb_fpu_fadd PASS (%0d vectors)", total);
    $finish;
  end

endmodule
