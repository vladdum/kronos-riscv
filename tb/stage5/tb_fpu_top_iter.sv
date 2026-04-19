// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Integration tests for iterative (FDIV/FSQRT) dispatch through kronos_fpu_top:
//   1. Blocking handshake — FDIV.D busy blocks a subsequent FADD.
//   2. Late-reservation — FMA then FDIV.D, both complete with out_valid.
//   3. Mid-iteration flush — FDIV.D flushed mid-flight, then FADD completes normally.
//   4. Back-to-back FDIV.D — second accepted after first completes.

module tb_fpu_top_iter;
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

  // IEEE 754 double constants
  localparam logic [63:0] D_1_0 = 64'h3FF0_0000_0000_0000;  // 1.0
  localparam logic [63:0] D_2_0 = 64'h4000_0000_0000_0000;  // 2.0
  localparam logic [63:0] D_3_0 = 64'h4008_0000_0000_0000;  // 3.0
  localparam logic [63:0] D_4_0 = 64'h4010_0000_0000_0000;  // 4.0

  // Drive a single dispatch (does NOT stall on busy).
  task automatic dispatch(input fp_op_e o, input logic fmtd, input logic [63:0] ain,
                          input logic [63:0] bin, input logic [63:0] cin,
                          input fpu_tag_t tg);
    @(negedge clk);
    in_valid = 1; op = o; fmt_d = fmtd; a = ain; b = bin; c = cin; tag_in = tg;
    @(posedge clk); #1;
    in_valid = 0;
  endtask

  // Dispatch, re-presenting every cycle while busy_o is high.
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

  // Wait up to max_cycles for out_valid; return 1 if seen, plus tag.
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

  // Collect up to `count` out_valid pulses within max_cycles total.
  // Returns the number actually collected and the tags seen.
  task automatic collect_valids(input int max_cycles, input int count,
                                output int collected,
                                output logic [4:0] tags [0:3]);
    collected = 0;
    tags[0] = 5'd0; tags[1] = 5'd0; tags[2] = 5'd0; tags[3] = 5'd0;
    for (int i = 0; i < max_cycles && collected < count; i++) begin
      @(posedge clk); #1;
      if (out_valid) begin
        tags[collected] = tag_out.rd;
        collected++;
      end
    end
  endtask

  int errors = 0;

  initial begin
    tag_in = '{rd: 5'd0, fp_dest: 1'b1};
    #12 rst_n = 1;

    // -----------------------------------------------------------------
    // Test 1: Blocking handshake
    //   Dispatch FDIV.D (variable latency, iter unit busy).
    //   Immediately try FADD.D — should see busy_o high for >= 1 cycle.
    //   Both eventually complete with correct tags.
    // -----------------------------------------------------------------
    begin : blk_blocking
      int            stalls, collected;
      logic [4:0]    tags [0:3];
      logic          saw_div, saw_add;
      fpu_tag_t      tg_div, tg_add;
      tg_div = '{rd: 5'd1, fp_dest: 1'b1};
      tg_add = '{rd: 5'd2, fp_dest: 1'b1};

      // Dispatch FDIV.D: 1.0 / 2.0
      dispatch(FP_FDIV, 1'b1, D_1_0, D_2_0, '0, tg_div);

      // Immediately try to dispatch FADD.D while iter is busy.
      dispatch_until_accepted(FP_FADD, 1'b1, D_1_0, D_2_0, '0, tg_add, stalls);

      if (stalls < 1) begin
        $display("[blocking] FAIL: FADD was not stalled at all, expected >= 1 stall cycle");
        errors++;
      end else begin
        $display("[blocking] OK: FADD stalled %0d cycle(s) behind FDIV.D", stalls);
      end

      // Collect both results (FADD arrives first at ~lat4, FDIV much later)
      collect_valids(200, 2, collected, tags);
      if (collected < 2) begin
        $display("[blocking] FAIL: expected 2 out_valid pulses, got %0d", collected);
        errors++;
      end else begin
        saw_div = 1'b0; saw_add = 1'b0;
        for (int i = 0; i < 2; i++) begin
          if (tags[i] == tg_div.rd) saw_div = 1'b1;
          if (tags[i] == tg_add.rd) saw_add = 1'b1;
        end
        if (!saw_div || !saw_add) begin
          $display("[blocking] FAIL: did not see both tags (div=%0b add=%0b)", saw_div, saw_add);
          errors++;
        end else begin
          $display("[blocking] OK: both FDIV (rd=%0d) and FADD (rd=%0d) completed",
                   tg_div.rd, tg_add.rd);
        end
      end
    end

    repeat (10) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 2: Late-reservation
    //   Dispatch FMA (5-cycle latency), then FDIV.D.
    //   FMA finishes first; FDIV.D finishes much later.
    //   Both must produce out_valid with correct tags.
    // -----------------------------------------------------------------
    begin : blk_late_res
      int            collected;
      logic [4:0]    tags [0:3];
      logic          saw_fma, saw_div;
      fpu_tag_t      tg_fma, tg_div;
      tg_fma = '{rd: 5'd3, fp_dest: 1'b1};
      tg_div = '{rd: 5'd4, fp_dest: 1'b1};

      // Dispatch FMA: 1.0 * 2.0 + 3.0
      dispatch(FP_FMADD, 1'b1, D_1_0, D_2_0, D_3_0, tg_fma);

      // Dispatch FDIV.D: 4.0 / 2.0
      dispatch(FP_FDIV, 1'b1, D_4_0, D_2_0, '0, tg_div);

      // Collect both results
      collect_valids(200, 2, collected, tags);
      if (collected < 2) begin
        $display("[late-res] FAIL: expected 2 out_valid pulses, got %0d", collected);
        errors++;
      end else begin
        saw_fma = 1'b0; saw_div = 1'b0;
        for (int i = 0; i < 2; i++) begin
          if (tags[i] == tg_fma.rd) saw_fma = 1'b1;
          if (tags[i] == tg_div.rd) saw_div = 1'b1;
        end
        if (!saw_fma || !saw_div) begin
          $display("[late-res] FAIL: did not see both tags (fma=%0b div=%0b)", saw_fma, saw_div);
          errors++;
        end else begin
          $display("[late-res] OK: both FMA (rd=%0d) and FDIV (rd=%0d) completed",
                   tg_fma.rd, tg_div.rd);
        end
      end
    end

    repeat (10) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 3: Mid-iteration flush
    //   Dispatch FDIV.D, wait a few cycles, flush, verify no writeback,
    //   then dispatch FADD.D and verify it completes normally.
    // -----------------------------------------------------------------
    begin : blk_flush
      logic      got;
      fpu_tag_t  tg_div, tg_add;
      tg_div = '{rd: 5'd5, fp_dest: 1'b1};
      tg_add = '{rd: 5'd6, fp_dest: 1'b1};

      // Dispatch FDIV.D
      dispatch(FP_FDIV, 1'b1, D_1_0, D_2_0, '0, tg_div);

      // Wait a few cycles into the iteration
      repeat (5) @(posedge clk);

      // Assert flush
      @(negedge clk); flush = 1;
      @(negedge clk); flush = 0;

      // Verify no writeback from the flushed FDIV
      wait_out_valid(200, got);
      if (got) begin
        $display("[flush] FAIL: out_valid fired after flush");
        errors++;
      end else begin
        $display("[flush] OK: no out_valid after flush");
      end

      // Verify busy has dropped
      @(posedge clk); #1;
      if (busy) begin
        $display("[flush] FAIL: busy_o still high after flush + drain");
        errors++;
      end else begin
        $display("[flush] OK: busy_o dropped after flush");
      end

      // Dispatch FADD.D and verify normal completion
      dispatch(FP_FADD, 1'b1, D_1_0, D_2_0, '0, tg_add);
      wait_out_valid(10, got);
      if (!got) begin
        $display("[flush] FAIL: FADD after flush did not complete");
        errors++;
      end else begin
        if (tag_out.rd != tg_add.rd) begin
          $display("[flush] FAIL: FADD tag.rd=%0d, expected %0d", tag_out.rd, tg_add.rd);
          errors++;
        end else begin
          $display("[flush] OK: FADD after flush completed, tag.rd=%0d", tag_out.rd);
        end
      end
    end

    repeat (10) @(posedge clk);

    // -----------------------------------------------------------------
    // Test 4: Back-to-back FDIV.D
    //   Dispatch FDIV.D, wait for out_valid, immediately dispatch another.
    //   The second must be accepted (busy drops after first completes).
    // -----------------------------------------------------------------
    begin : blk_b2b
      logic      got;
      fpu_tag_t  tg1, tg2;
      tg1 = '{rd: 5'd7, fp_dest: 1'b1};
      tg2 = '{rd: 5'd8, fp_dest: 1'b1};

      // First FDIV.D: 2.0 / 1.0
      dispatch(FP_FDIV, 1'b1, D_2_0, D_1_0, '0, tg1);

      // Wait for first to complete
      wait_out_valid(200, got);
      if (!got) begin
        $display("[b2b] FAIL: first FDIV.D did not complete within 200 cycles");
        errors++;
      end else begin
        if (tag_out.rd != tg1.rd) begin
          $display("[b2b] FAIL: first FDIV tag.rd=%0d, expected %0d", tag_out.rd, tg1.rd);
          errors++;
        end else begin
          $display("[b2b] OK: first FDIV.D completed, tag.rd=%0d", tag_out.rd);
        end

        // Wait one cycle for busy to drop, then dispatch second FDIV.D
        @(posedge clk); #1;

        // Dispatch second FDIV.D: 4.0 / 2.0
        dispatch(FP_FDIV, 1'b1, D_4_0, D_2_0, '0, tg2);

        // Wait for second to complete
        wait_out_valid(200, got);
        if (!got) begin
          $display("[b2b] FAIL: second FDIV.D did not complete within 200 cycles");
          errors++;
        end else begin
          if (tag_out.rd != tg2.rd) begin
            $display("[b2b] FAIL: second FDIV tag.rd=%0d, expected %0d", tag_out.rd, tg2.rd);
            errors++;
          end else begin
            $display("[b2b] OK: second FDIV.D completed, tag.rd=%0d", tag_out.rd);
          end
        end
      end
    end

    // Final result
    if (errors) begin
      $display("FAIL %0d errors", errors);
    end else begin
      $display("PASS");
    end
    $finish;
  end
endmodule
