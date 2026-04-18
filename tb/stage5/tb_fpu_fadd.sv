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

  // Drive inputs for one cycle, then wait for output to emerge after 5 cycles.
  task automatic apply5(input fp_op_e o, input logic fmtd, input logic [2:0] r,
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
    // Five pipeline stages → sample after 5 posedges from capture.
    repeat (5) @(posedge clk);
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
        apply5(FP_FADD, 1'b0, v.rm[2:0],
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
        apply5(FP_FSUB, 1'b0, v.rm[2:0],
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
        apply5(FP_FADD, 1'b1, v.rm[2:0], v.a, v.b);
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
          apply5(FP_FADD, 1'b0, rm_i[2:0],
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
          apply5(FP_FSUB, 1'b0, rm_i[2:0],
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
          apply5(FP_FADD, 1'b1, rm_i[2:0], da, db);
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
          apply5(FP_FSUB, 1'b1, rm_i[2:0], da, db);
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
    apply5(FP_FADD, 1'b0, 3'd0,
           {32'hFFFF_FFFF, 32'h7F80_0000},
           {32'hFFFF_FFFF, 32'h3F80_0000});
    total++;
    if (result !== 64'hFFFF_FFFF_7F80_0000 || fflags !== 5'b0) begin
      $error("inf+1.s: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // 1.0S + (-Inf.S) → -Inf.S (NaN-boxed), no flags
    apply5(FP_FADD, 1'b0, 3'd0,
           {32'hFFFF_FFFF, 32'h3F80_0000},
           {32'hFFFF_FFFF, 32'hFF80_0000});
    total++;
    if (result !== 64'hFFFF_FFFF_FF80_0000 || fflags !== 5'b0) begin
      $error("1+(-inf).s: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // +Inf.D + 1.0D → +Inf.D, no flags
    apply5(FP_FADD, 1'b1, 3'd0,
           64'h7FF0_0000_0000_0000,
           64'h3FF0_0000_0000_0000);
    total++;
    if (result !== 64'h7FF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("inf+1.d: dut=%h flags=%b", result, fflags);
      errors++;
    end
    // 1.0D + (-Inf.D) → -Inf.D, no flags
    apply5(FP_FADD, 1'b1, 3'd0,
           64'h3FF0_0000_0000_0000,
           64'hFFF0_0000_0000_0000);
    total++;
    if (result !== 64'hFFF0_0000_0000_0000 || fflags !== 5'b0) begin
      $error("1+(-inf).d: dut=%h flags=%b", result, fflags);
      errors++;
    end

    if (errors) $fatal(1, "tb_fpu_fadd: %0d/%0d mismatches", errors, total);
    $display("tb_fpu_fadd PASS (%0d vectors)", total);
    $finish;
  end

endmodule
