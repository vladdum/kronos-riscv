// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Tests for kronos_fpu_top dispatch wrapper:
//   1. FCVT then FMISC to same FP dest → FMISC is stalled (busy_o = 1) until
//      FCVT WB slot frees.
//   2. FADD completes at cycle 6, result visible on shared bus, tag passes through.
//   3. FMA completes at cycle 5, non-overlapping with FADD.
//   4. Flush during FADD in-flight → out_valid never fires.

module tb_fpu_top;
  import kronos_pkg::*;

  logic        clk = 0, rst_n = 0, flush = 0;
  logic        in_valid = 0;
  fp_op_e      op;
  logic        fmt_d = 0;
  logic [2:0]  rm   = 3'd0;
  logic [63:0] a = '0, b = '0, c = '0;
  fpu_tag_t    tag_in;

  logic        busy;
  logic        out_valid;
  logic [63:0] result;
  logic [4:0]  fflags;
  fpu_tag_t    tag_out;

  kronos_fpu_top u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .flush_i    (flush),
    .in_valid_i (in_valid),
    .op_i       (op),
    .fmt_d_i    (fmt_d),
    .rm_i       (rm),
    .a_i        (a),
    .b_i        (b),
    .c_i        (c),
    .tag_i      (tag_in),
    .busy_o     (busy),
    .out_valid_o(out_valid),
    .result_o   (result),
    .fflags_o   (fflags),
    .tag_o      (tag_out)
  );

  always #5 clk = ~clk;

  // Drive a single dispatch.  Returns immediately after posedge (instruction
  // captured by the DUT); does NOT stall on busy — caller must poll.
  task automatic dispatch(input fp_op_e o, input logic fmtd, input logic [63:0] ain,
                          input logic [63:0] bin, input logic [63:0] cin,
                          input fpu_tag_t tg);
    @(negedge clk);
    in_valid = 1; op = o; fmt_d = fmtd; a = ain; b = bin; c = cin; tag_in = tg;
    @(posedge clk); #1;
    in_valid = 0;
  endtask

  // Dispatch an operation, stalling (repeating every cycle) until busy_o=0.
  task automatic dispatch_until_accepted(
      input fp_op_e o, input logic fmtd,
      input logic [63:0] ain, input logic [63:0] bin, input logic [63:0] cin,
      input fpu_tag_t tg, output int stall_cycles);
    stall_cycles = 0;
    forever begin
      @(negedge clk);
      in_valid = 1; op = o; fmt_d = fmtd; a = ain; b = bin; c = cin; tag_in = tg;
      @(posedge clk); #1;
      if (!busy) begin
        in_valid = 0;
        break;
      end
      stall_cycles++;
    end
  endtask

  // Wait up to max_cycles for out_valid to pulse; return 1 if seen.
  task automatic wait_out_valid(input int max_cycles, output logic got_valid);
    got_valid = 1'b0;
    for (int i = 0; i < max_cycles; i++) begin
      @(posedge clk); #1;
      if (out_valid) begin
        got_valid = 1'b1;
        break;
      end
    end
  endtask

  int errors = 0;

  initial begin
    tag_in = '{rd: 5'd0, fp_dest: 1'b1};
    #12 rst_n = 1;

    // -----------------------------------------------------------------
    // Test 1: Scoreboard stall.
    //   Dispatch FCVT (lat=2, rd=1, fp_dest=1).
    //   Next cycle, dispatch FMISC (lat=1, rd=1, fp_dest=1).
    //   Both would write back at the same pipeline cycle → FMISC must stall.
    // -----------------------------------------------------------------
    begin : blk_stall
      int stalls;
      fpu_tag_t tg1, tg2;
      tg1 = '{rd: 5'd1, fp_dest: 1'b1};
      tg2 = '{rd: 5'd1, fp_dest: 1'b1};

      // Dispatch FCVT: convert integer 1 → FP (f32)
      dispatch(FP_FCVT_F_W, 1'b0, 64'd1, '0, '0, tg1);
      // Immediately try FMISC (lat=1, same dest): must be stalled
      dispatch_until_accepted(FP_FSGNJ, 1'b0, 64'hFFFF_FFFF_3F80_0000,
                              64'hFFFF_FFFF_3F80_0000, '0, tg2, stalls);
      if (stalls < 1) begin
        $error("[stall] FMISC was not stalled — expected ≥1 stall cycle, got %0d", stalls);
        errors++;
      end else begin
        $display("[stall] OK: FMISC stalled %0d cycle(s) behind FCVT", stalls);
      end
    end

    // Let the pipeline drain
    repeat (8) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 2: FADD completes at cycle 6, tag passes through.
    //   a=1.0f, b=1.0f → result=2.0f (0x40000000)
    // -----------------------------------------------------------------
    begin : blk_fadd
      logic       got;
      fpu_tag_t   tg;
      int         t;
      logic [63:0] expected;
      tg       = '{rd: 5'd3, fp_dest: 1'b1};
      expected = {32'hFFFF_FFFF, 32'h4000_0000};  // 2.0f NaN-boxed

      // Dispatch FADD.S  1.0 + 1.0
      dispatch(FP_FADD, 1'b0,
               {32'hFFFF_FFFF, 32'h3F80_0000},   // a = 1.0f
               {32'hFFFF_FFFF, 32'h3F80_0000},   // b = 1.0f
               '0, tg);

      wait_out_valid(8, got);
      if (!got) begin
        $error("[fadd] no out_valid within 8 cycles");
        errors++;
      end else begin
        if (result !== expected) begin
          $error("[fadd] result %h != expected %h", result, expected);
        end else if (tag_out !== tg) begin
          $error("[fadd] tag_out mismatch: got %p expected %p", tag_out, tg);
        end else begin
          $display("[fadd] OK: result=%h tag.rd=%0d", result, tag_out.rd);
        end
      end
    end

    repeat (6) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 3: FMA completes at cycle 5, tag carries through.
    //   a=2.0f, b=3.0f, c=4.0f → FMADD = 2*3+4 = 10.0f (0x41200000)
    // -----------------------------------------------------------------
    begin : blk_fma
      logic       got;
      fpu_tag_t   tg;
      logic [63:0] expected;
      tg       = '{rd: 5'd7, fp_dest: 1'b1};
      expected = {32'hFFFF_FFFF, 32'h4120_0000};  // 10.0f NaN-boxed

      dispatch(FP_FMADD, 1'b0,
               {32'hFFFF_FFFF, 32'h4000_0000},   // a = 2.0f
               {32'hFFFF_FFFF, 32'h4040_0000},   // b = 3.0f
               {32'hFFFF_FFFF, 32'h4080_0000},   // c = 4.0f
               tg);

      wait_out_valid(8, got);
      if (!got) begin
        $error("[fma] no out_valid within 8 cycles");
        errors++;
      end else begin
        if (result !== expected) begin
          $error("[fma] result %h != expected %h", result, expected);
        end else if (tag_out !== tg) begin
          $error("[fma] tag_out mismatch: got %p expected %p", tag_out, tg);
        end else begin
          $display("[fma] OK: result=%h tag.rd=%0d", result, tag_out.rd);
        end
      end
    end

    repeat (6) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 4: Flush during FADD in-flight → out_valid must not fire.
    // -----------------------------------------------------------------
    begin : blk_flush
      logic       got;
      fpu_tag_t   tg;
      tg = '{rd: 5'd2, fp_dest: 1'b1};

      dispatch(FP_FADD, 1'b0,
               {32'hFFFF_FFFF, 32'h3F80_0000},
               {32'hFFFF_FFFF, 32'h3F80_0000},
               '0, tg);

      // Flush 1 cycle after dispatch
      @(negedge clk); flush = 1;
      @(negedge clk); flush = 0;

      // Wait the full latency+1 and confirm no out_valid
      wait_out_valid(8, got);
      if (got) begin
        $error("[flush] out_valid fired after flush — expected none");
        errors++;
      end else begin
        $display("[flush] OK: no out_valid after flush");
      end
    end

    if (errors) $fatal(1, "tb_fpu_top: %0d error(s)", errors);
    $display("tb_fpu_top PASS");
    $finish;
  end
endmodule
