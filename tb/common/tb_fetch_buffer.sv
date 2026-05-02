// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Stage 6f-Phase-B unit testbench for kronos_fetch_buffer.

module tb_fetch_buffer;

  localparam int unsigned DEPTH = 4;

  // -------------------------------------------------------------------------
  // DUT pin signals
  // -------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;
  logic        flush;
  logic        enq_valid;
  logic [31:0] enq_pc;
  logic [31:0] enq_data;
  logic        enq_ready;
  logic        deq_valid;
  logic [31:0] deq_pc;
  logic [31:0] deq_data;
  logic        deq_ready;

  // Tracking
  int unsigned fail_count;

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  kronos_fetch_buffer #(
    .DEPTH (DEPTH)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .flush_i      (flush),
    .enq_valid_i  (enq_valid),
    .enq_pc_i     (enq_pc),
    .enq_data_i   (enq_data),
    .enq_ready_o  (enq_ready),
    .deq_valid_o  (deq_valid),
    .deq_pc_o     (deq_pc),
    .deq_data_o   (deq_data),
    .deq_ready_i  (deq_ready)
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
    rst_n     = 1'b0;
    flush     = 1'b0;
    enq_valid = 1'b0;
    enq_pc    = 32'h0;
    enq_data  = 32'h0;
    deq_ready = 1'b0;
    @(negedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
  endtask

  task automatic step();
    @(posedge clk);
    #1;
  endtask

  task automatic check(input string tag, input logic cond);
    if (!cond) begin
      $display("FAIL %s @ t=%0t", tag, $time);
      fail_count++;
    end
  endtask

  task automatic push(input logic [31:0] pc, input logic [31:0] d);
    enq_valid = 1'b1;
    enq_pc    = pc;
    enq_data  = d;
    @(posedge clk);
    #1;
    enq_valid = 1'b0;
    enq_pc    = 32'h0;
    enq_data  = 32'h0;
  endtask

  task automatic pop_and_check(input logic [31:0] exp_pc, input logic [31:0] exp_d, input string tag);
    deq_ready = 1'b1;
    if (deq_valid !== 1'b1) begin
      $display("FAIL %s: deq_valid low when expecting data", tag);
      fail_count++;
    end
    if (deq_pc !== exp_pc || deq_data !== exp_d) begin
      $display("FAIL %s: pc got=%h exp=%h, data got=%h exp=%h",
               tag, deq_pc, exp_pc, deq_data, exp_d);
      fail_count++;
    end
    @(posedge clk);
    #1;
    deq_ready = 1'b0;
  endtask

  // -------------------------------------------------------------------------
  // Stimulus
  // -------------------------------------------------------------------------
  initial begin
    fail_count = 0;
    do_reset();

    // Case 1: empty/full back-pressure
    check("c1.empty.deq_valid_low",     deq_valid === 1'b0);
    check("c1.empty.enq_ready_high",    enq_ready === 1'b1);
    push(32'h0000_0000, 32'hAAAA_0000);
    push(32'h0000_0004, 32'hAAAA_0001);
    push(32'h0000_0008, 32'hAAAA_0002);
    push(32'h0000_000C, 32'hAAAA_0003);
    check("c1.full.enq_ready_low", enq_ready === 1'b0);
    check("c1.full.deq_valid_high", deq_valid === 1'b1);

    // Case 2: pop 4, verify FIFO order
    pop_and_check(32'h0000_0000, 32'hAAAA_0000, "c2.pop0");
    pop_and_check(32'h0000_0004, 32'hAAAA_0001, "c2.pop1");
    pop_and_check(32'h0000_0008, 32'hAAAA_0002, "c2.pop2");
    pop_and_check(32'h0000_000C, 32'hAAAA_0003, "c2.pop3");
    check("c2.empty.after.drain", deq_valid === 1'b0);
    check("c2.empty.enq_ready",    enq_ready === 1'b1);

    // Case 3: push 2 + pop 1 + push 2 + pop 3
    push(32'h0000_1000, 32'hBBBB_0000);
    push(32'h0000_1004, 32'hBBBB_0001);
    pop_and_check(32'h0000_1000, 32'hBBBB_0000, "c3.pop0");
    push(32'h0000_1008, 32'hBBBB_0002);
    push(32'h0000_100C, 32'hBBBB_0003);
    pop_and_check(32'h0000_1004, 32'hBBBB_0001, "c3.pop1");
    pop_and_check(32'h0000_1008, 32'hBBBB_0002, "c3.pop2");
    pop_and_check(32'h0000_100C, 32'hBBBB_0003, "c3.pop3");
    check("c3.empty.after.interleave", deq_valid === 1'b0);

    // Case 4: flush mid-stream
    push(32'h0000_2000, 32'hCCCC_0000);
    push(32'h0000_2004, 32'hCCCC_0001);
    flush = 1'b1;
    @(posedge clk);
    #1;
    flush = 1'b0;
    #1;
    check("c4.flush.deq_valid_low", deq_valid === 1'b0);
    check("c4.flush.enq_ready_high", enq_ready === 1'b1);

    // Case 5: simultaneous push+pop, FB starts empty
    push(32'h0000_3000, 32'hDDDD_0000);
    enq_valid = 1'b1;
    enq_pc    = 32'h0000_3004;
    enq_data  = 32'hDDDD_0001;
    deq_ready = 1'b1;
    if (deq_pc !== 32'h0000_3000 || deq_data !== 32'hDDDD_0000) begin
      $display("FAIL c5.simul: pc=%h data=%h", deq_pc, deq_data);
      fail_count++;
    end
    @(posedge clk);
    #1;
    enq_valid = 1'b0;
    deq_ready = 1'b0;
    enq_pc    = 32'h0;
    enq_data  = 32'h0;
    // After simul push+pop with starting count=1: count remains 1, head moved
    // to 0000_3004.
    check("c5.after.simul.deq_valid", deq_valid === 1'b1);
    if (deq_pc !== 32'h0000_3004 || deq_data !== 32'hDDDD_0001) begin
      $display("FAIL c5.after: pc=%h data=%h", deq_pc, deq_data);
      fail_count++;
    end
    pop_and_check(32'h0000_3004, 32'hDDDD_0001, "c5.drain");

    // Case 6: simultaneous push+pop when full — push should NOT succeed
    // (pop happens, push is gated because count stays at DEPTH this cycle).
    push(32'h0000_4000, 32'hEEEE_0000);
    push(32'h0000_4004, 32'hEEEE_0001);
    push(32'h0000_4008, 32'hEEEE_0002);
    push(32'h0000_400C, 32'hEEEE_0003);
    check("c6.full", enq_ready === 1'b0);
    // Try simul push+pop. enq_ready must remain low while count==DEPTH.
    enq_valid = 1'b1;
    enq_pc    = 32'h0000_4010;
    enq_data  = 32'hEEEE_0099;
    deq_ready = 1'b1;
    check("c6.simul.full.enq_ready_low", enq_ready === 1'b0);
    @(posedge clk);
    #1;
    enq_valid = 1'b0;
    deq_ready = 1'b0;
    // After: count=3, head advanced. Drain remaining three in order.
    pop_and_check(32'h0000_4004, 32'hEEEE_0001, "c6.drain1");
    pop_and_check(32'h0000_4008, 32'hEEEE_0002, "c6.drain2");
    pop_and_check(32'h0000_400C, 32'hEEEE_0003, "c6.drain3");
    check("c6.empty", deq_valid === 1'b0);

    // Case 7: PC carried correctly with each entry
    push(32'hDEAD_BE00, 32'h1111_2222);
    push(32'hDEAD_BE04, 32'h3333_4444);
    pop_and_check(32'hDEAD_BE00, 32'h1111_2222, "c7.pc0");
    pop_and_check(32'hDEAD_BE04, 32'h3333_4444, "c7.pc1");

    if (fail_count == 0) begin
      $display("tb_fetch_buffer: PASS");
    end else begin
      $display("tb_fetch_buffer: FAIL (%0d cases failed)", fail_count);
    end
    $finish;
  end

  // Watchdog
  initial begin
    #20000;
    $display("tb_fetch_buffer: FAIL (watchdog)");
    $finish;
  end

endmodule
