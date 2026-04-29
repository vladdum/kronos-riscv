// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_busy;
  import kronos_pkg::*;

  logic clk;
  logic rst_n;

  // Lookup ports
  logic [4:0]   rs1_int_addr, rs2_int_addr, rs1_fp_addr, rs2_fp_addr;
  busy_entry_t  rs1_int, rs2_int, rs1_fp, rs2_fp;

  // Dispatch / commit / flush
  logic         dispatch;
  logic         dispatch_rd_fp;
  logic [4:0]   dispatch_rd_addr;
  rob_idx_t     dispatch_rob_idx;

  logic         commit;
  logic         commit_rd_fp;
  logic [4:0]   commit_rd_addr;
  rob_idx_t     commit_rob_idx;

  logic                       flush;
  rob_entry_t [ROB_DEPTH-1:0] rob_q;
  rob_idx_t                   flush_new_head, flush_new_tail;

  int errors = 0;

  kronos_busy u_busy (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .rs1_int_addr_i    (rs1_int_addr),
    .rs2_int_addr_i    (rs2_int_addr),
    .rs1_fp_addr_i     (rs1_fp_addr),
    .rs2_fp_addr_i     (rs2_fp_addr),
    .rs1_int_o         (rs1_int),
    .rs2_int_o         (rs2_int),
    .rs1_fp_o          (rs1_fp),
    .rs2_fp_o          (rs2_fp),
    .dispatch_i        (dispatch),
    .dispatch_rd_fp_i  (dispatch_rd_fp),
    .dispatch_rd_addr_i(dispatch_rd_addr),
    .dispatch_rob_idx_i(dispatch_rob_idx),
    .commit_i          (commit),
    .commit_rd_fp_i    (commit_rd_fp),
    .commit_rd_addr_i  (commit_rd_addr),
    .commit_rob_idx_i  (commit_rob_idx),
    .flush_i           (flush),
    .rob_q_i           (rob_q),
    .flush_new_head_i  (flush_new_head),
    .flush_new_tail_i  (flush_new_tail)
  );

  always #5 clk = ~clk;

  task automatic check(input string name, input bit cond);
    if (!cond) begin
      $display("FAIL: %s", name);
      errors++;
    end
  endtask

  initial begin
    clk             = 0;
    rst_n           = 0;
    rs1_int_addr    = '0; rs2_int_addr = '0;
    rs1_fp_addr     = '0; rs2_fp_addr  = '0;
    dispatch        = 0;  dispatch_rd_fp = 0; dispatch_rd_addr = '0; dispatch_rob_idx = '0;
    commit          = 0;  commit_rd_fp   = 0; commit_rd_addr   = '0; commit_rob_idx   = '0;
    flush           = 0;  flush_new_head = '0; flush_new_tail   = '0;
    rob_q           = '{default: '0};

    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // ---- TEST 1: empty table reports !busy on every register --------------
    for (int r = 0; r < 32; r++) begin
      rs1_int_addr = r[4:0];
      rs1_fp_addr  = r[4:0];
      #1;
      check($sformatf("int_busy[x%0d]==0 after reset", r), rs1_int.busy == 1'b0);
      check($sformatf("fp_busy[f%0d]==0 after reset",  r), rs1_fp.busy  == 1'b0);
    end

    // ---- TEST 2: dispatch sets busy with the right ROB idx ----------------
    dispatch         = 1;
    dispatch_rd_fp   = 0;
    dispatch_rd_addr = 5'd5;
    dispatch_rob_idx = 4'h3;
    @(posedge clk); #1;
    dispatch         = 0;
    rs1_int_addr     = 5'd5; #1;
    check("int x5 busy after dispatch",            rs1_int.busy     == 1'b1);
    check("int x5 prod_idx == 3 after dispatch",   rs1_int.prod_idx == 4'h3);

    // ---- TEST 3: WAW — second dispatch overwrites prod_idx ---------------
    dispatch         = 1;
    dispatch_rd_addr = 5'd5;
    dispatch_rob_idx = 4'h7;
    @(posedge clk); #1;
    dispatch         = 0;
    rs1_int_addr     = 5'd5; #1;
    check("int x5 prod_idx == 7 after WAW dispatch", rs1_int.prod_idx == 4'h7);
    check("int x5 still busy after WAW dispatch",     rs1_int.busy     == 1'b1);

    // ---- TEST 4: x0 dispatch is a no-op ----------------------------------
    dispatch         = 1;
    dispatch_rd_addr = 5'd0;
    dispatch_rob_idx = 4'hA;
    @(posedge clk); #1;
    dispatch         = 0;
    rs1_int_addr     = 5'd0; #1;
    check("int x0 stays !busy after dispatch", rs1_int.busy == 1'b0);

    // ---- TEST 5: fp dispatch goes to fp_busy_q only ----------------------
    dispatch         = 1;
    dispatch_rd_fp   = 1;
    dispatch_rd_addr = 5'd0;       // f0 is a real FP reg
    dispatch_rob_idx = 4'h2;
    @(posedge clk); #1;
    dispatch         = 0;
    rs1_fp_addr      = 5'd0;       // expect busy
    rs1_int_addr     = 5'd0; #1;   // expect !busy (different table)
    check("fp f0 busy after fp dispatch",         rs1_fp.busy  == 1'b1);
    check("fp f0 prod_idx == 2 after dispatch",   rs1_fp.prod_idx == 4'h2);
    check("int x0 unaffected by fp dispatch",     rs1_int.busy == 1'b0);

    // ---- TEST 6: commit clears busy when prod_idx matches ----------------
    // First, set up: dispatch x6 with rob_idx=8.
    dispatch         = 1;
    dispatch_rd_fp   = 0;
    dispatch_rd_addr = 5'd6;
    dispatch_rob_idx = 4'h8;
    @(posedge clk); #1;
    dispatch         = 0;
    // Now commit it.
    commit           = 1;
    commit_rd_fp     = 0;
    commit_rd_addr   = 5'd6;
    commit_rob_idx   = 4'h8;
    @(posedge clk); #1;
    commit           = 0;
    rs1_int_addr     = 5'd6; #1;
    check("int x6 !busy after matching commit", rs1_int.busy == 1'b0);

    // ---- TEST 7: commit does NOT clear if a younger producer is in flight -
    // Dispatch two writers to x7 (WAW): rob 4'h2 then 4'h6. prod_idx=6.
    dispatch         = 1;
    dispatch_rd_addr = 5'd7;
    dispatch_rob_idx = 4'h2;
    @(posedge clk); #1;
    dispatch_rob_idx = 4'h6;
    @(posedge clk); #1;
    dispatch         = 0;
    // Now commit the older one (rob_idx=2) — should NOT clear busy.
    commit           = 1;
    commit_rd_addr   = 5'd7;
    commit_rob_idx   = 4'h2;
    @(posedge clk); #1;
    commit           = 0;
    rs1_int_addr     = 5'd7; #1;
    check("int x7 stays busy after older commit",          rs1_int.busy     == 1'b1);
    check("int x7 prod_idx still 6 after older commit",    rs1_int.prod_idx == 4'h6);
    // Now commit the younger one — should clear.
    commit           = 1;
    commit_rob_idx   = 4'h6;
    @(posedge clk); #1;
    commit           = 0;
    rs1_int_addr     = 5'd7; #1;
    check("int x7 !busy after younger commit", rs1_int.busy == 1'b0);

    // ---- TEST 8: flush rebuilds busy from surviving ROB entries ----------
    // Set up: dispatch x10 (rob 4'h0) and x11 (rob 4'h1) and x10-WAW (rob 4'h2).
    dispatch         = 1;
    dispatch_rd_addr = 5'd10; dispatch_rob_idx = 4'h0; @(posedge clk); #1;
    dispatch_rd_addr = 5'd11; dispatch_rob_idx = 4'h1; @(posedge clk); #1;
    dispatch_rd_addr = 5'd10; dispatch_rob_idx = 4'h2; @(posedge clk); #1;
    dispatch         = 0;

    // Now flush everything younger than rob 4'h1 (i.e. 4'h2 dies, leaving 4'h0
    // and 4'h1 alive). x10 should revert to prod_idx=0, x11 stays at prod_idx=1.
    rob_q = '{default: '0};
    rob_q[4'h0].valid       = 1'b1;
    rob_q[4'h0].dec.rd_wen  = 1'b1;
    rob_q[4'h0].dec.rd      = 5'd10;
    rob_q[4'h0].dec.rd_fp   = 1'b0;
    rob_q[4'h1].valid       = 1'b1;
    rob_q[4'h1].dec.rd_wen  = 1'b1;
    rob_q[4'h1].dec.rd      = 5'd11;
    rob_q[4'h1].dec.rd_fp   = 1'b0;
    flush          = 1;
    flush_new_head = 4'h0;
    flush_new_tail = 4'h2;     // exclusive — entries 0 and 1 survive
    @(posedge clk); #1;
    flush          = 0;
    rs1_int_addr = 5'd10; #1;
    check("int x10 prod_idx reverts to 0 after flush", rs1_int.prod_idx == 4'h0);
    check("int x10 still busy after flush",            rs1_int.busy     == 1'b1);
    rs1_int_addr = 5'd11; #1;
    check("int x11 prod_idx stays 1 after flush",      rs1_int.prod_idx == 4'h1);
    check("int x11 still busy after flush",            rs1_int.busy     == 1'b1);

    // ---- TEST 9: full flush (no survivors) clears all busy ---------------
    flush          = 1;
    flush_new_head = 4'h0;
    flush_new_tail = 4'h0;     // empty range
    rob_q          = '{default: '0};   // all invalid
    @(posedge clk); #1;
    flush          = 0;
    rs1_int_addr = 5'd10; #1; check("int x10 cleared on full flush", rs1_int.busy == 1'b0);
    rs1_int_addr = 5'd11; #1; check("int x11 cleared on full flush", rs1_int.busy == 1'b0);

    if (errors == 0) $display("PASS: tb_busy (lookup-on-empty)");
    else             $display("FAIL: tb_busy with %0d errors", errors);
    $finish;
  end

endmodule
