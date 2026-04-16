// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_fpu_iter;
  import kronos_pkg::*;
  import softfloat_dpi_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk;

  logic        rst_n = 0;
  logic        in_valid = 0;
  fp_op_e      op;
  logic        fmt_d = 1;
  logic [2:0]  rm = 3'b000;
  logic [63:0] a, b;
  fpu_tag_t    tag = '{rd: 5'd1, fp_dest: 1'b1};

  logic        busy, out_valid;
  logic [63:0] result;
  logic [4:0]  fflags;
  fpu_tag_t    tag_out;

  kronos_fpu_iter dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .in_valid_i(in_valid), .op_i(op), .fmt_d_i(fmt_d), .rm_i(rm),
    .a_i(a), .b_i(b), .tag_i(tag),
    .busy_o(busy), .out_valid_o(out_valid), .result_o(result),
    .fflags_o(fflags), .tag_o(tag_out),
    .sb_late_req_o(), .sb_late_fp_dest_o(),
    .sb_late_grant_i(1'b1)
  );

  integer errors = 0;
  integer total  = 0;

  // Double-precision constants
  localparam logic [63:0] D_QNAN    = 64'h7FF8_0000_0000_0000;
  localparam logic [63:0] D_SNAN    = 64'h7FF0_0000_0000_0001;
  localparam logic [63:0] D_PINF    = 64'h7FF0_0000_0000_0000;
  localparam logic [63:0] D_NINF    = 64'hFFF0_0000_0000_0000;
  localparam logic [63:0] D_PZERO   = 64'h0000_0000_0000_0000;
  localparam logic [63:0] D_NZERO   = 64'h8000_0000_0000_0000;
  localparam logic [63:0] D_ONE     = 64'h3FF0_0000_0000_0000;
  localparam logic [63:0] D_NONE    = 64'hBFF0_0000_0000_0000;
  localparam logic [63:0] D_TWO     = 64'h4000_0000_0000_0000;
  localparam logic [63:0] D_FOUR    = 64'h4010_0000_0000_0000;
  localparam logic [63:0] D_SIX     = 64'h4018_0000_0000_0000;
  localparam logic [63:0] D_HALF    = 64'h3FE0_0000_0000_0000;
  localparam logic [63:0] D_THREE   = 64'h4008_0000_0000_0000;

  // Single-precision constants (NaN-boxed)
  localparam logic [63:0] S_QNAN    = 64'hFFFF_FFFF_7FC0_0000;
  localparam logic [63:0] S_SNAN    = 64'hFFFF_FFFF_7F80_0001;
  localparam logic [63:0] S_PINF    = 64'hFFFF_FFFF_7F80_0000;
  localparam logic [63:0] S_NINF    = 64'hFFFF_FFFF_FF80_0000;
  localparam logic [63:0] S_PZERO   = 64'hFFFF_FFFF_0000_0000;
  localparam logic [63:0] S_NZERO   = 64'hFFFF_FFFF_8000_0000;
  localparam logic [63:0] S_ONE     = 64'hFFFF_FFFF_3F80_0000;
  localparam logic [63:0] S_NONE    = 64'hFFFF_FFFF_BF80_0000;
  localparam logic [63:0] S_FOUR    = 64'hFFFF_FFFF_4080_0000;

  // Flag bits
  localparam logic [4:0] FL_NV = 5'b10000;
  localparam logic [4:0] FL_DZ = 5'b01000;
  localparam logic [4:0] FL_NX = 5'b00001;
  localparam logic [4:0] FL_OK = 5'b00000;

  // Dispatch one operation and wait for out_valid (specials path)
  task automatic dispatch(
    input fp_op_e    t_op,
    input logic      t_fmt_d,
    input logic [63:0] t_a,
    input logic [63:0] t_b,
    input logic [63:0] exp_result,
    input logic [4:0]  exp_fflags,
    input string       name
  );
    op    = t_op;
    fmt_d = t_fmt_d;
    a     = t_a;
    b     = t_b;
    @(posedge clk);
    in_valid = 1;
    @(posedge clk);
    in_valid = 0;

    // Wait for out_valid (max 20 cycles for specials)
    for (int i = 0; i < 20; i++) begin
      if (out_valid) break;
      @(posedge clk);
    end

    if (!out_valid) begin
      $display("FAIL [%s]: out_valid never asserted", name);
      errors++;
    end else begin
      if (result !== exp_result) begin
        $display("FAIL [%s]: result=%016h expected=%016h", name, result, exp_result);
        errors++;
      end
      if (fflags !== exp_fflags) begin
        $display("FAIL [%s]: fflags=%05b expected=%05b", name, fflags, exp_fflags);
        errors++;
      end
    end

    // Wait for PACK -> IDLE
    @(posedge clk);
    if (busy) begin
      $display("FAIL [%s]: busy still asserted after PACK", name);
      errors++;
    end
    total++;
  endtask

  // Dispatch a finite-normal operation and verify FSM completion.
  task automatic dispatch_iter(
    input fp_op_e      t_op,
    input logic        t_fmt_d,
    input logic [63:0] t_a,
    input logic [63:0] t_b,
    input int          min_cycles,
    input int          max_cycles,
    input string       name
  );
    int cycle_count;
    op    = t_op;
    fmt_d = t_fmt_d;
    a     = t_a;
    b     = t_b;
    @(posedge clk);
    in_valid = 1;
    @(posedge clk);
    in_valid = 0;

    if (!busy) begin
      $display("FAIL [%s]: busy not asserted after dispatch", name);
      errors++;
    end

    cycle_count = 0;
    for (int i = 0; i < 200; i++) begin
      if (out_valid) break;
      if (!busy) begin
        $display("FAIL [%s]: busy deasserted before out_valid (cycle %0d)",
                 name, cycle_count);
        errors++;
        return;
      end
      @(posedge clk);
      cycle_count++;
    end

    if (!out_valid) begin
      $display("FAIL [%s]: out_valid never asserted (waited %0d cycles)",
               name, cycle_count);
      errors++;
    end else begin
      if (cycle_count < min_cycles || cycle_count > max_cycles) begin
        $display("FAIL [%s]: cycle_count=%0d not in [%0d, %0d]",
                 name, cycle_count, min_cycles, max_cycles);
        errors++;
      end else begin
        $display("OK   [%s]: completed in %0d cycles", name, cycle_count);
      end
    end

    @(posedge clk);
    if (busy) begin
      $display("FAIL [%s]: busy still asserted after PACK", name);
      errors++;
    end
    total++;
  endtask

  // Dispatch with result and fflags check (hand-crafted expected values)
  task automatic dispatch_iter_check(
    input fp_op_e      t_op,
    input logic        t_fmt_d,
    input logic [2:0]  t_rm,
    input logic [63:0] t_a,
    input logic [63:0] t_b,
    input logic [63:0] exp_result,
    input logic [4:0]  exp_fflags,
    input string       name
  );
    int cycle_count;
    op    = t_op;
    fmt_d = t_fmt_d;
    rm    = t_rm;
    a     = t_a;
    b     = t_b;
    @(posedge clk);
    in_valid = 1;
    @(posedge clk);
    in_valid = 0;

    cycle_count = 0;
    for (int i = 0; i < 200; i++) begin
      if (out_valid) break;
      @(posedge clk);
      cycle_count++;
    end

    if (!out_valid) begin
      $display("FAIL [%s]: out_valid never asserted (waited %0d cycles)",
               name, cycle_count);
      errors++;
    end else begin
      if (result !== exp_result) begin
        $display("FAIL [%s]: result=%016h expected=%016h", name, result,
                 exp_result);
        errors++;
      end else if (fflags !== exp_fflags) begin
        $display("FAIL [%s]: fflags=%05b expected=%05b", name, fflags,
                 exp_fflags);
        errors++;
      end else begin
        $display("OK   [%s]: result=%016h fflags=%05b (%0d cyc)", name,
                 result, fflags, cycle_count);
      end
    end

    @(posedge clk);
    total++;
  endtask

  // Dispatch and compare against SoftFloat reference (no hand-crafted expected)
  task automatic dispatch_sf(
    input fp_op_e      t_op,
    input logic        t_fmt_d,
    input logic [2:0]  t_rm,
    input logic [63:0] t_a,
    input logic [63:0] t_b,
    input string       name
  );
    int cycle_count;
    longint unsigned sf_r64;
    int unsigned     sf_r32;
    byte unsigned    sf_f;
    logic [63:0]     sf_expected;
    logic [4:0]      sf_flags;

    op    = t_op;
    fmt_d = t_fmt_d;
    rm    = t_rm;
    a     = t_a;
    b     = t_b;
    @(posedge clk);
    in_valid = 1;
    @(posedge clk);
    in_valid = 0;

    // Compute SoftFloat reference while DUT runs
    sf_reset();
    if (t_fmt_d) begin
      if (t_op == FP_FDIV) sf_r64 = sf_f64_div(t_a, t_b, {5'b0, t_rm});
      else                 sf_r64 = sf_f64_sqrt(t_a, {5'b0, t_rm});
      sf_f = sf_exceptions();
      sf_expected = sf_r64;
    end else begin
      if (t_op == FP_FDIV)
        sf_r32 = sf_f32_div(t_a[31:0], t_b[31:0], {5'b0, t_rm});
      else
        sf_r32 = sf_f32_sqrt(t_a[31:0], {5'b0, t_rm});
      sf_f = sf_exceptions();
      sf_expected = {32'hFFFF_FFFF, sf_r32};
    end
    sf_flags = sf_f[4:0];

    cycle_count = 0;
    for (int i = 0; i < 200; i++) begin
      if (out_valid) break;
      @(posedge clk);
      cycle_count++;
    end

    if (!out_valid) begin
      $display("FAIL [%s]: out_valid never asserted (waited %0d cycles)",
               name, cycle_count);
      errors++;
    end else begin
      if (result !== sf_expected || fflags !== sf_flags) begin
        $display("FAIL [%s]: dut=%016h/%05b sf=%016h/%05b a=%016h b=%016h rm=%0d",
                 name, result, fflags, sf_expected, sf_flags, t_a, t_b, t_rm);
        errors++;
      end
    end

    @(posedge clk);
    total++;
  endtask

  initial begin
    sf_reset();
    rst_n = 0; #20; rst_n = 1; #10;

    // =================================================================
    // FDIV.D specials (double precision)
    // =================================================================
    dispatch(FP_FDIV, 1, D_SNAN,  D_ONE,   D_QNAN, FL_NV,
      "FDIV.D sNaN/x");
    dispatch(FP_FDIV, 1, D_ONE,   D_SNAN,  D_QNAN, FL_NV,
      "FDIV.D x/sNaN");
    dispatch(FP_FDIV, 1, D_QNAN,  D_ONE,   D_QNAN, FL_OK,
      "FDIV.D qNaN/x");
    dispatch(FP_FDIV, 1, D_ONE,   D_QNAN,  D_QNAN, FL_OK,
      "FDIV.D x/qNaN");
    dispatch(FP_FDIV, 1, D_PZERO, D_PZERO, D_QNAN, FL_NV,
      "FDIV.D 0/0");
    dispatch(FP_FDIV, 1, D_PINF,  D_PINF,  D_QNAN, FL_NV,
      "FDIV.D inf/inf");
    dispatch(FP_FDIV, 1, D_ONE,   D_PZERO, D_PINF, FL_DZ,
      "FDIV.D 1.0/0.0 (DZ)");
    dispatch(FP_FDIV, 1, D_NONE,  D_PZERO, D_NINF, FL_DZ,
      "FDIV.D -1.0/+0.0 (DZ, neg)");
    dispatch(FP_FDIV, 1, D_PZERO, D_ONE,   D_PZERO, FL_OK,
      "FDIV.D 0/1");
    dispatch(FP_FDIV, 1, D_NZERO, D_ONE,   D_NZERO, FL_OK,
      "FDIV.D -0/1");
    dispatch(FP_FDIV, 1, D_PINF,  D_ONE,   D_PINF, FL_OK,
      "FDIV.D inf/1");
    dispatch(FP_FDIV, 1, D_NINF,  D_ONE,   D_NINF, FL_OK,
      "FDIV.D -inf/1");
    dispatch(FP_FDIV, 1, D_ONE,   D_PINF,  D_PZERO, FL_OK,
      "FDIV.D 1/inf");
    dispatch(FP_FDIV, 1, D_NONE,  D_PINF,  D_NZERO, FL_OK,
      "FDIV.D -1/inf");

    // =================================================================
    // FSQRT.D specials (double precision)
    // =================================================================
    dispatch(FP_FSQRT, 1, D_SNAN,  '0, D_QNAN, FL_NV,
      "FSQRT.D sNaN");
    dispatch(FP_FSQRT, 1, D_QNAN,  '0, D_QNAN, FL_OK,
      "FSQRT.D qNaN");
    dispatch(FP_FSQRT, 1, D_NZERO, '0, D_NZERO, FL_OK,
      "FSQRT.D -0");
    dispatch(FP_FSQRT, 1, D_PZERO, '0, D_PZERO, FL_OK,
      "FSQRT.D +0");
    dispatch(FP_FSQRT, 1, D_NONE,  '0, D_QNAN, FL_NV,
      "FSQRT.D -1.0");
    dispatch(FP_FSQRT, 1, D_PINF,  '0, D_PINF, FL_OK,
      "FSQRT.D +inf");
    dispatch(FP_FSQRT, 1, D_NINF,  '0, D_QNAN, FL_NV,
      "FSQRT.D -inf");

    // =================================================================
    // FDIV.S specials (single precision, NaN-boxed)
    // =================================================================
    dispatch(FP_FDIV, 0, S_SNAN,  S_ONE,   S_QNAN, FL_NV,
      "FDIV.S sNaN/x");
    dispatch(FP_FDIV, 0, S_ONE,   S_SNAN,  S_QNAN, FL_NV,
      "FDIV.S x/sNaN");
    dispatch(FP_FDIV, 0, S_QNAN,  S_ONE,   S_QNAN, FL_OK,
      "FDIV.S qNaN/x");
    dispatch(FP_FDIV, 0, S_ONE,   S_QNAN,  S_QNAN, FL_OK,
      "FDIV.S x/qNaN");
    dispatch(FP_FDIV, 0, S_PZERO, S_PZERO, S_QNAN, FL_NV,
      "FDIV.S 0/0");
    dispatch(FP_FDIV, 0, S_PINF,  S_PINF,  S_QNAN, FL_NV,
      "FDIV.S inf/inf");
    dispatch(FP_FDIV, 0, S_ONE,   S_PZERO, S_PINF, FL_DZ,
      "FDIV.S 1.0/0.0 (DZ)");
    dispatch(FP_FDIV, 0, S_NONE,  S_PZERO, S_NINF, FL_DZ,
      "FDIV.S -1.0/+0.0 (DZ, neg)");
    dispatch(FP_FDIV, 0, S_PZERO, S_ONE,   S_PZERO, FL_OK,
      "FDIV.S 0/1");
    dispatch(FP_FDIV, 0, S_NZERO, S_ONE,   S_NZERO, FL_OK,
      "FDIV.S -0/1");
    dispatch(FP_FDIV, 0, S_PINF,  S_ONE,   S_PINF, FL_OK,
      "FDIV.S inf/1");
    dispatch(FP_FDIV, 0, S_NINF,  S_ONE,   S_NINF, FL_OK,
      "FDIV.S -inf/1");
    dispatch(FP_FDIV, 0, S_ONE,   S_PINF,  S_PZERO, FL_OK,
      "FDIV.S 1/inf");
    dispatch(FP_FDIV, 0, S_NONE,  S_PINF,  S_NZERO, FL_OK,
      "FDIV.S -1/inf");

    // =================================================================
    // FSQRT.S specials (single precision, NaN-boxed)
    // =================================================================
    dispatch(FP_FSQRT, 0, S_SNAN,  '0, S_QNAN, FL_NV,
      "FSQRT.S sNaN");
    dispatch(FP_FSQRT, 0, S_QNAN,  '0, S_QNAN, FL_OK,
      "FSQRT.S qNaN");
    dispatch(FP_FSQRT, 0, S_NZERO, '0, S_NZERO, FL_OK,
      "FSQRT.S -0");
    dispatch(FP_FSQRT, 0, S_PZERO, '0, S_PZERO, FL_OK,
      "FSQRT.S +0");
    dispatch(FP_FSQRT, 0, S_NONE,  '0, S_QNAN, FL_NV,
      "FSQRT.S -1.0");
    dispatch(FP_FSQRT, 0, S_PINF,  '0, S_PINF, FL_OK,
      "FSQRT.S +inf");
    dispatch(FP_FSQRT, 0, S_NINF,  '0, S_QNAN, FL_NV,
      "FSQRT.S -inf");

    // =================================================================
    // Hand-crafted exact and inexact cases
    // =================================================================
    dispatch_iter_check(FP_FDIV, 1, 3'b000, D_ONE, D_TWO,
      64'h3FE0_0000_0000_0000, FL_OK,
      "FDIV.D 1/2 RNE exact");

    dispatch_iter_check(FP_FDIV, 1, 3'b000, D_SIX, D_TWO,
      D_THREE, FL_OK,
      "FDIV.D 6/2 RNE exact");

    dispatch_iter_check(FP_FSQRT, 1, 3'b000, D_ONE, '0,
      D_ONE, FL_OK,
      "FSQRT.D sqrt(1) exact");

    dispatch_iter_check(FP_FSQRT, 1, 3'b000, D_FOUR, '0,
      D_TWO, FL_OK,
      "FSQRT.D sqrt(4) exact");

    dispatch_iter_check(FP_FDIV, 1, 3'b000, D_ONE, D_THREE,
      64'h3FD5_5555_5555_5555, FL_NX,
      "FDIV.D 1/3 RNE");

    dispatch_iter_check(FP_FDIV, 1, 3'b001, D_ONE, D_THREE,
      64'h3FD5_5555_5555_5555, FL_NX,
      "FDIV.D 1/3 RTZ");

    dispatch_iter_check(FP_FSQRT, 1, 3'b000, D_TWO, '0,
      64'h3FF6_A09E_667F_3BCD, FL_NX,
      "FSQRT.D sqrt(2) RNE");

    dispatch_iter_check(FP_FDIV, 0, 3'b000, S_ONE,
      64'hFFFF_FFFF_4000_0000,
      64'hFFFF_FFFF_3F00_0000,
      FL_OK,
      "FDIV.S 1/2 exact");

    dispatch_iter_check(FP_FDIV, 0, 3'b000, S_ONE,
      64'hFFFF_FFFF_4040_0000,
      64'hFFFF_FFFF_3EAA_AAAB, FL_NX,
      "FDIV.S 1/3 RNE");

    dispatch_iter_check(FP_FSQRT, 0, 3'b000, S_FOUR, '0,
      64'hFFFF_FFFF_4000_0000,
      FL_OK,
      "FSQRT.S sqrt(4) exact");

    dispatch_iter_check(FP_FDIV, 1, 3'b000, D_NONE, D_THREE,
      64'hBFD5_5555_5555_5555, FL_NX,
      "FDIV.D -1/3 RNE (neg)");

    $display("[hand-crafted] %0d tests, %0d errors so far", total, errors);

    // =================================================================
    // SoftFloat-verified constrained-random sweep
    // =================================================================
    begin : blk_random_f64_div
      logic [63:0] ra, rb;
      string lbl;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 200; k++) begin
          ra = {$urandom, $urandom};
          rb = {$urandom, $urandom};
          $sformat(lbl, "f64_div_rm%0d_%0d", rm_i, k);
          dispatch_sf(FP_FDIV, 1'b1, rm_i[2:0], ra, rb, lbl);
        end
      end
    end

    begin : blk_random_f64_sqrt
      logic [63:0] ra;
      string lbl;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 200; k++) begin
          ra = {$urandom, $urandom};
          $sformat(lbl, "f64_sqrt_rm%0d_%0d", rm_i, k);
          dispatch_sf(FP_FSQRT, 1'b1, rm_i[2:0], ra, '0, lbl);
        end
      end
    end

    begin : blk_random_f32_div
      logic [31:0] ra, rb;
      string lbl;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 200; k++) begin
          ra = $urandom; rb = $urandom;
          $sformat(lbl, "f32_div_rm%0d_%0d", rm_i, k);
          dispatch_sf(FP_FDIV, 1'b0, rm_i[2:0],
                      {32'hFFFF_FFFF, ra}, {32'hFFFF_FFFF, rb}, lbl);
        end
      end
    end

    begin : blk_random_f32_sqrt
      logic [31:0] ra;
      string lbl;
      for (int rm_i = 0; rm_i < 5; rm_i++) begin
        for (int k = 0; k < 200; k++) begin
          ra = $urandom;
          $sformat(lbl, "f32_sqrt_rm%0d_%0d", rm_i, k);
          dispatch_sf(FP_FSQRT, 1'b0, rm_i[2:0],
                      {32'hFFFF_FFFF, ra}, '0, lbl);
        end
      end
    end

    // =================================================================
    // Boundary cases: subnormals, tiny values, near-overflow exponents
    // =================================================================
    begin : blk_boundary
      // Smallest positive subnormal / 2.0
      dispatch_sf(FP_FDIV, 1'b1, 3'b000,
                  64'h0000_0000_0000_0001, D_TWO, "f64_div_min_subnorm");
      // Largest subnormal / 1.0
      dispatch_sf(FP_FDIV, 1'b1, 3'b000,
                  64'h000F_FFFF_FFFF_FFFF, D_ONE, "f64_div_max_subnorm");
      // sqrt(smallest subnormal)
      dispatch_sf(FP_FSQRT, 1'b1, 3'b000,
                  64'h0000_0000_0000_0001, '0, "f64_sqrt_min_subnorm");
      // sqrt(largest normal)
      dispatch_sf(FP_FSQRT, 1'b1, 3'b000,
                  64'h7FEF_FFFF_FFFF_FFFF, '0, "f64_sqrt_max_normal");
      // Near-overflow: huge / tiny
      dispatch_sf(FP_FDIV, 1'b1, 3'b000,
                  64'h7FEF_FFFF_FFFF_FFFF,
                  64'h0010_0000_0000_0000, "f64_div_near_overflow");
      // SP subnormals
      dispatch_sf(FP_FDIV, 1'b0, 3'b000,
                  {32'hFFFF_FFFF, 32'h0000_0001},
                  {32'hFFFF_FFFF, 32'h4000_0000}, "f32_div_min_subnorm");
      dispatch_sf(FP_FSQRT, 1'b0, 3'b000,
                  {32'hFFFF_FFFF, 32'h0000_0001}, '0,
                  "f32_sqrt_min_subnorm");
      // 1.0 / max_normal (near underflow)
      dispatch_sf(FP_FDIV, 1'b1, 3'b000,
                  D_ONE, 64'h7FEF_FFFF_FFFF_FFFF,
                  "f64_div_near_underflow");
    end

    $display("[total] %0d tests, %0d errors", total, errors);
    if (errors == 0) $display("PASS");
    else $display("FAIL %0d errors", errors);
    $finish;
  end
endmodule
