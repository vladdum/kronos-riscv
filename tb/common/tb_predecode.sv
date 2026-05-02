// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Stage 6f-Phase-B unit testbench for kronos_predecode.
//
// Drives the FB-side ports directly with hand-crafted (pc, word) tuples and
// verifies the (instr, pc, is_16b) emission sequence plus internal state
// transitions (via the word_consume_o handshake).

module tb_predecode;

  // -------------------------------------------------------------------------
  // DUT pin signals
  // -------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;
  logic        flush;
  logic        flush_pc_offset;

  logic        word_valid;
  logic [31:0] word_data;
  logic [31:0] word_pc;
  logic        word_consume;

  logic        instr_valid;
  logic [31:0] instr;
  logic [31:0] instr_pc;
  logic        instr_is_16b;
  logic        instr_ready;

  logic        cross_page_fault;
  logic        translate_fetch;

  // Tracking
  int unsigned fail_count;

  // Reference decompression results (for tests that emit RVC)
  localparam logic [31:0] EXP_C_NOP_DECOMP = 32'h00000013; // c.nop = 0x0001
  localparam logic [31:0] EXP_C_LI10_DECOMP = 32'h00000513; // c.li x10,0 = 0x4501

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  kronos_predecode dut (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .flush_i            (flush),
    .flush_pc_offset_i  (flush_pc_offset),
    .word_valid_i       (word_valid),
    .word_data_i        (word_data),
    .word_pc_i          (word_pc),
    .word_consume_o     (word_consume),
    .instr_valid_o      (instr_valid),
    .instr_o            (instr),
    .instr_pc_o         (instr_pc),
    .instr_is_16b_o     (instr_is_16b),
    .instr_ready_i      (instr_ready),
    .cross_page_fault_o (cross_page_fault),
    .translate_fetch_i  (translate_fetch)
  );

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  task automatic do_reset();
    rst_n           = 1'b0;
    flush           = 1'b0;
    flush_pc_offset = 1'b0;
    word_valid      = 1'b0;
    word_data       = 32'h0;
    word_pc         = 32'h0;
    instr_ready     = 1'b1;
    translate_fetch = 1'b0;
    @(negedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
  endtask

  task automatic check(input string tag, input logic cond);
    if (!cond) begin
      $display("FAIL %s @ t=%0t  iv=%b ipc=%h ii=%h is16=%b cons=%b",
               tag, $time, instr_valid, instr_pc, instr, instr_is_16b, word_consume);
      fail_count++;
    end
  endtask

  task automatic check_emit(input string tag,
                            input logic [31:0] exp_pc,
                            input logic [31:0] exp_instr,
                            input logic        exp_is_16b);
    if (instr_valid !== 1'b1) begin
      $display("FAIL %s: instr_valid=0", tag);
      fail_count++;
    end
    if (instr_pc !== exp_pc) begin
      $display("FAIL %s: pc got=%h exp=%h", tag, instr_pc, exp_pc);
      fail_count++;
    end
    if (instr !== exp_instr) begin
      $display("FAIL %s: instr got=%h exp=%h", tag, instr, exp_instr);
      fail_count++;
    end
    if (instr_is_16b !== exp_is_16b) begin
      $display("FAIL %s: is16b got=%b exp=%b", tag, instr_is_16b, exp_is_16b);
      fail_count++;
    end
  endtask

  task automatic step();
    @(posedge clk);
    #1;
  endtask

  // -------------------------------------------------------------------------
  // Stimulus
  // -------------------------------------------------------------------------
  initial begin
    fail_count = 0;
    do_reset();

    // -----------------------------------------------------------------------
    // Case 1: 32b non-spanning at pc[1]=0.
    //   Expect: emit raw 32b, pc=word_pc, is_16b=0, word_consume=1.
    // -----------------------------------------------------------------------
    word_valid = 1'b1;
    word_data  = 32'h0010_0093;     // addi x1, x0, 1
    word_pc    = 32'h0000_0100;
    instr_ready = 1'b1;
    #1;
    check_emit("c1.32b_nonspan", 32'h0000_0100, 32'h0010_0093, 1'b0);
    check("c1.consume", word_consume === 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 2: RVC at lower (pc[1]=0).
    //   Expect: emit decompressed lower, pc=word_pc, is_16b=1, no consume.
    //   Next cycle: same word, internal "lower_consumed" is 1 → reads upper.
    // -----------------------------------------------------------------------
    word_valid = 1'b1;
    word_data  = {16'h4501, 16'h4501};  // upper=c.li x10,0; lower=c.li x10,0
    word_pc    = 32'h0000_0200;
    instr_ready = 1'b1;
    #1;
    check_emit("c2a.rvc_lower", 32'h0000_0200, EXP_C_LI10_DECOMP, 1'b1);
    check("c2a.no_consume", word_consume === 1'b0);
    step();

    // Same word still on FB head. Now upper half should be emitted.
    #1;
    check_emit("c2b.rvc_upper", 32'h0000_0202, EXP_C_LI10_DECOMP, 1'b1);
    check("c2b.consume", word_consume === 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 3: span lower at upper-half (pc[1]=1) — predecode buffers half,
    //         pops FB, no emit. Next cycle combines.
    //   Setup: flush + flush_pc_offset=1 to prime word_lower_consumed_q=1.
    // -----------------------------------------------------------------------
    flush           = 1'b1;
    flush_pc_offset = 1'b1;
    word_valid      = 1'b0;
    @(posedge clk);
    #1;
    flush           = 1'b0;
    flush_pc_offset = 1'b0;
    #1;
    // First word: upper half = lower-of-32b (must end in 2'b11).
    word_valid = 1'b1;
    word_data  = 32'h0093_FFFF;   // upper half lo[1:0]=2'b11; lower half don't care
    word_pc    = 32'h0000_0300;
    instr_ready = 1'b1;
    #1;
    check("c3a.no_emit",   instr_valid === 1'b0);
    check("c3a.consume",   word_consume === 1'b1);  // span buffer + FB pop
    step();
    // Next cycle: new word with hi-half of the span (upper 16 bits ignored
    // by combine; only lower 16 used). Use a simple 32b instruction we can
    // recognise: lower = 0x0093, upper = 0x0010 → instr = 0x00100093.
    // We need word_data[15:0] = 0x0010 (the high 16 of the spanning insn).
    word_data = {16'hAAAA, 16'h0010};
    word_pc   = 32'h0000_0304;
    #1;
    check_emit("c3b.combine", 32'h0000_0302, 32'h0010_0093, 1'b0);
    // After combine: word_lower_consumed_q goes high, FB not popped this cycle.
    check("c3b.no_consume", word_consume === 1'b0);
    step();

    // Next cycle: same FB head, lower already consumed. Read upper 16 = 0xAAAA.
    // 0xAAAA[1:0] = 2'b10 → RVC. Decompressing 0xAAAA : let's just verify the
    // shape (PC=0x0306, is_16b=1, consume=1). Actual decomp value not asserted.
    #1;
    if (instr_valid !== 1'b1 || instr_pc !== 32'h0000_0306 || instr_is_16b !== 1'b1) begin
      $display("FAIL c3c.rvc_upper: iv=%b pc=%h is16=%b",
               instr_valid, instr_pc, instr_is_16b);
      fail_count++;
    end
    check("c3c.consume", word_consume === 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 4: mid-stream flush clears prev_half.
    //   Buffer a span-lower then flush; verify next post-flush emit treats
    //   prev_half as cleared.
    // -----------------------------------------------------------------------
    flush           = 1'b1;
    flush_pc_offset = 1'b1;     // re-prime upper-half-first
    @(posedge clk);
    #1;
    flush           = 1'b0;
    flush_pc_offset = 1'b0;
    word_valid = 1'b1;
    word_data  = 32'h0093_FFFF;
    word_pc    = 32'h0000_0400;
    instr_ready = 1'b1;
    #1;
    check("c4a.span_buf", word_consume === 1'b1 && instr_valid === 1'b0);
    step();
    // Now prev_half_valid_q=1.  Apply flush — should clear prev_half.
    flush = 1'b1;
    word_valid = 1'b0;
    @(posedge clk);
    #1;
    flush = 1'b0;
    // Drive a clean 32b non-spanning. predecode must NOT combine with stale prev_half.
    word_valid = 1'b1;
    word_data  = 32'h0050_0193;   // addi x3, x0, 5
    word_pc    = 32'h0000_0500;
    #1;
    check_emit("c4b.post_flush_32b", 32'h0000_0500, 32'h0050_0193, 1'b0);
    check("c4b.consume", word_consume === 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 5: backpressure — instr_ready=0 holds state.
    // -----------------------------------------------------------------------
    word_valid = 1'b1;
    word_data  = 32'h00B0_0193;     // addi x3, x0, 11
    word_pc    = 32'h0000_0600;
    instr_ready = 1'b0;
    #1;
    check_emit("c5a.held_emit", 32'h0000_0600, 32'h00B0_0193, 1'b0);
    check("c5a.no_consume", word_consume === 1'b0);
    step();
    #1;
    check_emit("c5b.still_held", 32'h0000_0600, 32'h00B0_0193, 1'b0);
    check("c5b.no_consume", word_consume === 1'b0);
    step();
    #1;
    check_emit("c5c.still_held2", 32'h0000_0600, 32'h00B0_0193, 1'b0);
    step();
    instr_ready = 1'b1;
    #1;
    check_emit("c5d.released", 32'h0000_0600, 32'h00B0_0193, 1'b0);
    check("c5d.consume", word_consume === 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 6: mixed RVC + 32b stream — verify PCs increment 2/4 correctly.
    //   Stream: c.nop @ 0x700, c.nop @ 0x702, addi @ 0x704, c.nop @ 0x708.
    //   Word A (pc=0x700) = {c.nop, c.nop} = {16'h0001, 16'h0001} = 0x00010001
    //   Word B (pc=0x704) = addi x0,x0,0  = 0x00000013
    //   Word C (pc=0x708) = {???, c.nop}  = {16'hXXXX, 16'h0001}
    //         (we don't go past the c.nop in this case.)
    // -----------------------------------------------------------------------
    instr_ready = 1'b1;

    // -- emit 1: c.nop @ 0x700 --
    word_valid = 1'b1;
    word_data  = 32'h0001_0001;
    word_pc    = 32'h0000_0700;
    #1;
    check_emit("c6.0_rvc_lo", 32'h0000_0700, EXP_C_NOP_DECOMP, 1'b1);
    check("c6.0_no_consume", word_consume === 1'b0);
    step();

    // -- emit 2: c.nop @ 0x702 (upper of same word) --
    #1;
    check_emit("c6.1_rvc_up", 32'h0000_0702, EXP_C_NOP_DECOMP, 1'b1);
    check("c6.1_consume", word_consume === 1'b1);
    step();

    // -- emit 3: addi @ 0x704 (32b non-spanning) --
    word_data = 32'h0000_0013;
    word_pc   = 32'h0000_0704;
    #1;
    check_emit("c6.2_32b", 32'h0000_0704, 32'h0000_0013, 1'b0);
    check("c6.2_consume", word_consume === 1'b1);
    step();

    // -- emit 4: c.nop @ 0x708 (lower) --
    word_data = 32'hFFFF_0001;
    word_pc   = 32'h0000_0708;
    #1;
    check_emit("c6.3_rvc_lo", 32'h0000_0708, EXP_C_NOP_DECOMP, 1'b1);
    step();
    word_valid = 1'b0;

    // -----------------------------------------------------------------------
    // Case 7: word_valid_i=0 — predecode does nothing.
    // -----------------------------------------------------------------------
    word_valid = 1'b0;
    word_data  = 32'hDEAD_BEEF;
    word_pc    = 32'h0000_0900;
    #1;
    check("c7.no_emit", instr_valid === 1'b0);
    check("c7.no_consume", word_consume === 1'b0);
    step();

    // -----------------------------------------------------------------------
    // Case 8: cross-page span at pc[11:1]==7FF with translate_fetch=1.
    // -----------------------------------------------------------------------
    flush           = 1'b1;
    flush_pc_offset = 1'b1;     // start from upper half
    @(posedge clk);
    #1;
    flush           = 1'b0;
    flush_pc_offset = 1'b0;
    translate_fetch = 1'b1;
    word_valid = 1'b1;
    word_data  = 32'h0093_FFFF;       // upper half lo[1:0]=2'b11
    word_pc    = 32'h0000_0FF8;       // upper half PC=0xFFA → pc[11:1]=7FD, not page-end
    #1;
    // Not a page boundary: should buffer the span normally, no fault.
    check("c8a.no_fault_off_boundary", cross_page_fault === 1'b0);
    step();

    // Reset and hit the actual page-end.
    flush           = 1'b1;
    flush_pc_offset = 1'b1;
    @(posedge clk);
    #1;
    flush           = 1'b0;
    flush_pc_offset = 1'b0;
    word_data = 32'h0093_FFFF;
    word_pc   = 32'h0000_0FFC;        // pc[11:1] of upper half = ?
    // word_pc is 4-byte-aligned (pc[1:0]=0); the upper-half lives at pc|2.
    // For cross-page we need pc|2's [11:1] == 7FF, so pc[11:0] must be 0xFFC.
    // 0xFFC | 2 = 0xFFE → pc[11:1] = 11'h7FF. Good.
    #1;
    check("c8b.fault_active", cross_page_fault === 1'b1);
    check("c8b.no_emit", instr_valid === 1'b0);
    check("c8b.no_consume", word_consume === 1'b0);
    step();
    translate_fetch = 1'b0;
    word_valid = 1'b0;

    if (fail_count == 0) begin
      $display("tb_predecode: PASS");
    end else begin
      $display("tb_predecode: FAIL (%0d cases failed)", fail_count);
    end
    $finish;
  end

  // Watchdog
  initial begin
    #20000;
    $display("tb_predecode: FAIL (watchdog)");
    $finish;
  end

endmodule
