// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_rob;
  import kronos_pkg::*;

  logic clk;
  logic rst_n;

  // DUT-facing signals (full set; some unused until later sub-tests)
  logic                       full, empty;
  rob_idx_t                   head, tail;
  rob_entry_t [ROB_DEPTH-1:0] rob_view;
  logic [ROB_DEPTH-1:0]       is_at_head;

  logic                       dispatch;
  rob_entry_t                 dispatch_entry;
  rob_idx_t                   dispatch_idx;

  logic                       compA, compB;
  rob_idx_t                   compA_idx, compB_idx;
  logic [63:0]                compA_result, compB_result;
  logic [63:0]                compA_csr_new_val;
  logic                       compA_trap_taken;
  logic [4:0]                 compA_trap_cause;
  logic [63:0]                compA_tval;
  logic                       compA_actual_taken;
  logic [31:0]                compA_actual_target;
  logic                       compA_mispredict;
  logic [63:0]                compA_mem_addr, compA_mem_wdata;
  logic [2:0]                 compA_mem_funct3;
  logic [4:0]                 compB_fflags;

  logic                       commit;
  rob_entry_t                 commit_entry;
  rob_idx_t                   commit_idx;
  logic                       commit_block;

  logic                       branch_flush;
  rob_idx_t                   branch_flush_idx;
  logic                       trap_flush;

  int errors = 0;

  kronos_rob u_rob (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    .full_o                (full),
    .empty_o               (empty),
    .head_o                (head),
    .tail_o                (tail),
    .rob_q_o               (rob_view),
    .is_at_head_o          (is_at_head),
    .dispatch_i            (dispatch),
    .dispatch_entry_i      (dispatch_entry),
    .dispatch_idx_o        (dispatch_idx),
    .compA_i               (compA),
    .compA_idx_i           (compA_idx),
    .compA_result_i        (compA_result),
    .compA_csr_new_val_i   (compA_csr_new_val),
    .compA_trap_taken_i    (compA_trap_taken),
    .compA_trap_cause_i    (compA_trap_cause),
    .compA_tval_i          (compA_tval),
    .compA_actual_taken_i  (compA_actual_taken),
    .compA_actual_target_i (compA_actual_target),
    .compA_mispredict_i    (compA_mispredict),
    .compA_mem_addr_i      (compA_mem_addr),
    .compA_mem_wdata_i     (compA_mem_wdata),
    .compA_mem_funct3_i    (compA_mem_funct3),
    .compB_i               (compB),
    .compB_idx_i           (compB_idx),
    .compB_result_i        (compB_result),
    .compB_fflags_i        (compB_fflags),
    .commit_o              (commit),
    .commit_entry_o        (commit_entry),
    .commit_idx_o          (commit_idx),
    .commit_block_i        (commit_block),
    .branch_flush_i        (branch_flush),
    .branch_flush_idx_i    (branch_flush_idx),
    .trap_flush_i          (trap_flush)
  );

  always #5 clk = ~clk;

  task automatic check(input string name, input bit cond);
    if (!cond) begin
      $display("FAIL: %s", name);
      errors++;
    end
  endtask

  // Helper: build a dispatch entry that writes int reg `rd` and is already complete.
  function automatic rob_entry_t mk_done_entry(input logic [4:0] rd, input logic [63:0] result);
    rob_entry_t e;
    e = '0;
    e.valid       = 1'b1;
    e.complete    = 1'b1;
    e.dec.rd_wen  = 1'b1;
    e.dec.rd      = rd;
    e.dec.rd_fp   = 1'b0;
    e.result      = result;
    return e;
  endfunction

  // Helper: dispatch entry that's NOT yet complete.
  function automatic rob_entry_t mk_pending_entry(input logic [4:0] rd);
    rob_entry_t e;
    e = '0;
    e.valid       = 1'b1;
    e.complete    = 1'b0;
    e.dec.rd_wen  = 1'b1;
    e.dec.rd      = rd;
    e.dec.rd_fp   = 1'b0;
    return e;
  endfunction

  initial begin
    clk = 0; rst_n = 0;
    dispatch = 0; dispatch_entry = '0;
    compA = 0; compA_idx = '0; compA_result = '0; compA_csr_new_val = '0;
    compA_trap_taken = 0; compA_trap_cause = '0; compA_tval = '0;
    compA_actual_taken = 0; compA_actual_target = '0; compA_mispredict = 0;
    compA_mem_addr = '0; compA_mem_wdata = '0; compA_mem_funct3 = '0;
    compB = 0; compB_idx = '0; compB_result = '0; compB_fflags = '0;
    commit_block = 0;
    branch_flush = 0; branch_flush_idx = '0;
    trap_flush = 0;

    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // ---- TEST 1: empty + dispatch + immediate commit ---------------------
    check("empty after reset",  empty == 1'b1);
    check("!full after reset",  full  == 1'b0);
    check("head==0",            head  == 4'h0);
    check("tail==0",            tail  == 4'h0);

    // Dispatch a complete entry (writing x5 = 0xDEAD).
    dispatch       = 1;
    dispatch_entry = mk_done_entry(5'd5, 64'hDEAD);
    @(posedge clk); #1;
    dispatch       = 0;

    check("!empty after dispatch",          empty == 1'b0);
    check("tail advanced to 1",             tail  == 4'h1);
    check("head still 0",                   head  == 4'h0);
    check("commit_o asserted (head ready)", commit == 1'b1);
    check("commit_entry.rd == 5",           commit_entry.dec.rd == 5'd5);
    check("commit_entry.result == DEAD",    commit_entry.result == 64'hDEAD);

    @(posedge clk); #1;     // commit fires
    check("empty after commit",     empty == 1'b1);
    check("head advanced to 1",     head  == 4'h1);
    check("commit_o deasserted",    commit == 1'b0);

    // ---- TEST 2: dispatch pending → port-A completes → commit -----------
    dispatch       = 1;
    dispatch_entry = mk_pending_entry(5'd6);
    @(posedge clk); #1;
    dispatch       = 0;

    check("entry pending (commit not asserted)", commit == 1'b0);

    // Fire port A on the entry we just dispatched.
    compA          = 1;
    compA_idx      = head;     // we know the only outstanding entry is at head
    compA_result   = 64'hCAFE;
    @(posedge clk); #1;
    compA          = 0;

    check("port A made entry complete + commit_o", commit == 1'b1);
    check("commit_entry.result == CAFE",            commit_entry.result == 64'hCAFE);

    @(posedge clk); #1;
    check("commit advanced head past port-A entry", head == 4'h2);
    check("ROB now empty",                          empty == 1'b1);

    // ---- TEST 3: dispatch two entries; complete both same cycle (A and B) -
    dispatch       = 1;
    dispatch_entry = mk_pending_entry(5'd10);
    @(posedge clk); #1;
    dispatch_entry = mk_pending_entry(5'd11);
    @(posedge clk); #1;
    dispatch       = 0;

    // Fire A on idx 2 (writes x10) and B on idx 3 (writes x11) the same cycle.
    compA        = 1;
    compA_idx    = 4'h2;
    compA_result = 64'h1000;
    compB        = 1;
    compB_idx    = 4'h3;
    compB_result = 64'h2000;
    @(posedge clk); #1;
    compA = 0; compB = 0;

    // Both should be complete; head still at 2 (commit fires this cycle).
    check("rob[2] complete after port A",  rob_view[4'h2].complete == 1'b1);
    check("rob[3] complete after port B",  rob_view[4'h3].complete == 1'b1);
    check("rob[2].result == 0x1000",        rob_view[4'h2].result   == 64'h1000);
    check("rob[3].result == 0x2000",        rob_view[4'h3].result   == 64'h2000);
    check("commit_o (head=2 ready)",        commit == 1'b1);

    @(posedge clk); #1;     // commit idx 2
    @(posedge clk); #1;     // commit idx 3
    check("ROB empty after both commits", empty == 1'b1);
    check("head advanced to 4",           head == 4'h4);

    // ---- TEST 4: branch flush invalidates younger entries -----------------
    // Dispatch 3 pending entries: rob[4]=x12, rob[5]=x13, rob[6]=x14.
    dispatch = 1;
    dispatch_entry = mk_pending_entry(5'd12); @(posedge clk); #1;
    dispatch_entry = mk_pending_entry(5'd13); @(posedge clk); #1;
    dispatch_entry = mk_pending_entry(5'd14); @(posedge clk); #1;
    dispatch = 0;

    check("3 entries pending (count check)", tail == 4'h7 && head == 4'h4);

    // Flush everything younger than rob[5] (the branch is at idx 5, kills idx 6).
    branch_flush     = 1;
    branch_flush_idx = 4'h5;
    @(posedge clk); #1;
    branch_flush     = 0;

    check("tail rolled back to 6",         tail == 4'h6);
    check("rob[6] invalidated",            rob_view[4'h6].valid == 1'b0);
    check("rob[5] still valid",            rob_view[4'h5].valid == 1'b1);
    check("rob[4] still valid",            rob_view[4'h4].valid == 1'b1);

    // Drain rob[4] and rob[5] before next test.
    compA = 1; compA_idx = 4'h4; compA_result = 64'h1; @(posedge clk); #1;
    compA_idx = 4'h5; compA_result = 64'h2; @(posedge clk); #1;
    compA = 0;
    @(posedge clk); #1;
    @(posedge clk); #1;
    check("ROB empty after drain", empty == 1'b1);

    // ---- TEST 5: trap flush nukes everything -----------------------------
    dispatch = 1;
    dispatch_entry = mk_pending_entry(5'd20); @(posedge clk); #1;
    dispatch_entry = mk_pending_entry(5'd21); @(posedge clk); #1;
    dispatch = 0;

    trap_flush = 1;
    @(posedge clk); #1;
    trap_flush = 0;

    check("ROB empty after trap flush", empty == 1'b1);
    check("head reset to 0",            head == 4'h0);
    check("tail reset to 0",            tail == 4'h0);
    for (int unsigned i = 0; i < ROB_DEPTH; i++)
      check($sformatf("rob[%0d] invalid after trap flush", i), rob_view[i[3:0]].valid == 1'b0);

    if (errors == 0) $display("PASS: tb_rob (5 tests)");
    else             $display("FAIL: tb_rob with %0d errors", errors);
    $finish;
  end

endmodule
