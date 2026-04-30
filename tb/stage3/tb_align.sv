// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_align.sv — Unit tests for kronos_align (combinational output version).
//
// Timing model:
//   tick  = @(posedge clk) #1  — advances state, then reads comb outputs of NEW state
//   sample = #1                 — reads comb outputs of CURRENT state without advancing
//
// With combinational outputs, instr_o/instr_valid_o/is_16b_o are driven by the
// CURRENT registered state plus current inputs.  After a tick, they reflect the
// state that was clocked in on that posedge.
module tb_align;
  import kronos_pkg::*;

  logic        clk, rst_n;
  logic [31:0] rdata;
  logic        rvalid;
  logic        stall, flush;
  logic        pc_offset;
  logic [31:0] instr_out;
  logic        instr_valid;
  logic        is_16b;
  logic        align_stall, align_need_upper, align_needs_fetch;

  int failures = 0;

  kronos_align u_dut (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    .rdata_i             (rdata),
    .rvalid_i            (rvalid),
    .stall_i             (stall),
    .flush_i             (flush),
    .pc_offset_i         (pc_offset),
    .instr_o             (instr_out),
    .instr_valid_o       (instr_valid),
    .is_16b_o            (is_16b),
    .align_stall_o       (align_stall),
    .align_need_upper_o  (align_need_upper),
    .align_needs_fetch_o (align_needs_fetch)
  );

  always #5 clk = ~clk;
  // tick: advance one clock cycle, pause 1 unit after posedge to let comb settle
  task tick; @(posedge clk); #1; endtask

  initial begin
    clk = 0; rst_n = 0; rdata = 32'b0; rvalid = 0; stall = 0; flush = 0; pc_offset = 0;
    repeat(4) tick;
    rst_n = 1;

    // -----------------------------------------------------------------------
    // Test 1: Word-aligned 32-bit instruction passthrough
    // -----------------------------------------------------------------------
    // NORMAL state, rvalid=1, rdata[1:0]=11 → 32-bit passthrough
    rdata  = 32'hABCD_EF33;  // [1:0]=11 → 32-bit
    rvalid = 1;
    // Check comb outputs BEFORE posedge: NORMAL + rvalid=1 → passthrough
    #1;
    if (instr_out !== 32'hABCD_EF33 || instr_valid !== 1'b1 || is_16b !== 1'b0 || align_stall !== 1'b0) begin
      $display("FAIL T1 (pre-posedge): 32-bit passthrough: got instr=0x%08x valid=%b is_16b=%b stall=%b",
               instr_out, instr_valid, is_16b, align_stall);
      failures++;
    end
    // align_needs_fetch is 1 in NORMAL state (need to fetch next word)
    if (align_needs_fetch !== 1'b1) begin
      $display("FAIL T1: align_needs_fetch should be 1 in NORMAL state, got %b", align_needs_fetch);
      failures++;
    end
    tick;  // posedge: 32-bit → no state change (still NORMAL)
    // After tick: still NORMAL, rvalid=1 → same outputs
    if (instr_out !== 32'hABCD_EF33 || is_16b !== 1'b0 || align_stall !== 1'b0) begin
      $display("FAIL T1 (post-tick): 32-bit passthrough: got instr=0x%08x is_16b=%b stall=%b",
               instr_out, is_16b, align_stall);
      failures++;
    end
    rvalid = 0;
    tick;

    // -----------------------------------------------------------------------
    // Test 2: Word-aligned 16-bit (lower half), then buffered 16-bit
    // -----------------------------------------------------------------------
    // Feed word where lower=C.NOP(0x0001), upper=C.NOP(0x0001)
    rdata  = 32'h0001_0001;  // [1:0]=01 → lower half is 16-bit
    rvalid = 1;
    // Before posedge: NORMAL + rvalid=1 + rdata[1:0]=01 → emit decomp_lower(0x0001)=0x13
    #1;
    if (instr_out !== 32'h0000_0013 || instr_valid !== 1'b1 || is_16b !== 1'b1 || align_stall !== 1'b0) begin
      $display("FAIL T2 (pre-posedge): 16-bit lower: got instr=0x%08x valid=%b is_16b=%b stall=%b",
               instr_out, instr_valid, is_16b, align_stall);
      failures++;
    end
    tick;
    // After tick: state → BUFFERED (buf_valid=1, buf_data=0x0001)
    // Comb: BUFFERED, buf[1:0]=01 → emit decomp_buf(0x0001)=0x13, instr_valid=1, is_16b=1
    if (instr_out !== 32'h0000_0013 || instr_valid !== 1'b1 || is_16b !== 1'b1 || align_stall !== 1'b0) begin
      $display("FAIL T2a: 16-bit buffered: got instr=0x%08x valid=%b is_16b=%b stall=%b",
               instr_out, instr_valid, is_16b, align_stall);
      failures++;
    end
    // In BUFFERED state, align_needs_fetch should be 0 (buffer has data, no fetch needed)
    if (align_needs_fetch !== 1'b0) begin
      $display("FAIL T2a: align_needs_fetch should be 0 in BUFFERED state, got %b", align_needs_fetch);
      failures++;
    end
    rvalid = 0;
    tick;
    // After tick: BUFFERED consumed → NORMAL; rvalid=0 → instr_valid=0
    if (instr_valid !== 1'b0) begin
      $display("FAIL T2b: after buffer consumed, instr_valid should be 0, got %b", instr_valid);
      failures++;
    end
    tick;

    // -----------------------------------------------------------------------
    // Test 3: 32-bit instruction spanning halfword boundary (need_upper)
    // -----------------------------------------------------------------------
    // Setup: flush, then feed word where lower=C.NOP(0x0001), upper=0xAB2F([1:0]=11)
    flush = 1; pc_offset = 0; tick; flush = 0;
    rdata  = 32'hAB2F_0001;  // lower=0x0001(16-bit), upper=0xAB2F(32-bit spanning lower half)
    rvalid = 1;
    // Before posedge: NORMAL + rvalid=1 + rdata[1:0]=01 → emit decomp_lower(0x0001)=C.NOP
    #1;
    if (instr_out !== 32'h0000_0013 || instr_valid !== 1'b1 || is_16b !== 1'b1 || align_stall !== 1'b0) begin
      $display("FAIL T3a (pre-posedge): C.NOP before span: got instr=0x%08x valid=%b is_16b=%b stall=%b",
               instr_out, instr_valid, is_16b, align_stall);
      failures++;
    end
    tick;
    // After tick: BUFFERED (buf_valid=1, buf_data=0xAB2F), buf[1:0]=11 → no instruction yet
    if (instr_valid !== 1'b0 || align_stall !== 1'b0) begin
      $display("FAIL T3a (post-tick): BUFFERED with [1:0]=11: instr_valid=%b align_stall=%b",
               instr_valid, align_stall);
      failures++;
    end
    rvalid = 0;

    // Cycle B: state=BUFFERED, buf[1:0]=11 → transition to NEED_UPPER
    tick;
    // After tick: need_upper_q=1, align_stall=1, align_need_upper=1
    if (align_stall !== 1'b1 || align_need_upper !== 1'b1) begin
      $display("FAIL T3b: span stall: stall=%b need_upper=%b", align_stall, align_need_upper);
      failures++;
    end
    if (align_needs_fetch !== 1'b1) begin
      $display("FAIL T3b: align_needs_fetch should be 1 in NEED_UPPER, got %b", align_needs_fetch);
      failures++;
    end

    // Cycle C: provide upper half — rdata[15:0]=0xCD12 completes the spanning insn
    // Set rvalid=0 first so the post-tick state is clean, then check before posedge
    rdata  = 32'hXXXX_CD12;
    rvalid = 1;
    // Before posedge: NEED_UPPER + rvalid=1 → instr={CD12,AB2F}=0xCD12AB2F, is_16b=0, stall=1
    #1;
    if (instr_out !== 32'hCD12AB2F || instr_valid !== 1'b1 || is_16b !== 1'b0 || align_stall !== 1'b1) begin
      $display("FAIL T3c (pre-posedge): span combine: got instr=0x%08x valid=%b is_16b=%b stall=%b",
               instr_out, instr_valid, is_16b, align_stall);
      failures++;
    end
    tick;
    // After tick: rvalid=1 was sampled → need_upper cleared, buf_valid cleared → NORMAL
    // Comb: NORMAL + rvalid=1, rdata=0xXXXXCD12, [1:0]=10 (16-bit) → instr_valid=1, is_16b=1
    // Just check the stall/need_upper flags are clear
    if (align_stall !== 1'b0 || align_need_upper !== 1'b0) begin
      $display("FAIL T3c (post-tick): stall should clear: stall=%b need_upper=%b",
               align_stall, align_need_upper);
      failures++;
    end
    rvalid = 0;
    tick;

    // -----------------------------------------------------------------------
    // Test 4: Flush to halfword-aligned PC (pc_offset_i=1)
    // -----------------------------------------------------------------------
    // Flush with pc_offset=1: next fetch word's upper half is the first instruction
    flush = 1; pc_offset = 1; tick; flush = 0; pc_offset = 0;

    // Feed word: lower=garbage(0xABCD), upper=C.NOP(0x0001)
    rdata  = 32'h0001_ABCD;  // lower=0xABCD (garbage), upper=C.NOP
    rvalid = 1;
    // Before posedge: skip_lower_q=1 → instr_valid=0
    #1;
    if (instr_valid !== 1'b0) begin
      $display("FAIL T4a (pre-posedge): skip_lower should suppress instr_valid, got %b", instr_valid);
      failures++;
    end
    tick;
    // After tick: skip_lower consumed, buf_valid=1, buf_data=0x0001 (BUFFERED)
    // Comb: BUFFERED, buf[1:0]=01 → emit C.NOP=0x13, instr_valid=1, is_16b=1
    if (instr_out !== 32'h0000_0013 || instr_valid !== 1'b1 || is_16b !== 1'b1) begin
      $display("FAIL T4b: after skip_lower, BUFFERED should emit C.NOP: got 0x%08x valid=%b is_16b=%b",
               instr_out, instr_valid, is_16b);
      failures++;
    end
    // align_needs_fetch=0 in BUFFERED state
    if (align_needs_fetch !== 1'b0) begin
      $display("FAIL T4b: align_needs_fetch should be 0 in BUFFERED state, got %b", align_needs_fetch);
      failures++;
    end
    rvalid = 0;
    tick;

    if (failures == 0) $display("PASS: all tb_align checks");
    else               $display("FAIL: %0d tb_align checks failed", failures);
    $finish;
  end
endmodule
