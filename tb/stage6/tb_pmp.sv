// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_pmp;
  import kronos_pkg::*;

  logic [15:0][7:0]  pmpcfg;
  logic [15:0][53:0] pmpaddr;
  priv_e             priv;
  logic              valid;
  logic [55:0]       addr;
  logic [2:0]        size;
  logic              is_fetch, is_load, is_store;
  logic              fault;
  logic [55:0]       fault_addr;

  kronos_pmp #(.N(16)) u_dut (
    .pmpcfg_i     (pmpcfg),
    .pmpaddr_i    (pmpaddr),
    .priv_i       (priv),
    .valid_i      (valid),
    .addr_i       (addr),
    .size_i       (size),
    .is_fetch_i   (is_fetch),
    .is_load_i    (is_load),
    .is_store_i   (is_store),
    .fault_o      (fault),
    .fault_addr_o (fault_addr)
  );

  task automatic clear_all;
    pmpcfg  = '0;
    pmpaddr = '0;
    valid   = 0;
    is_fetch = 0; is_load = 0; is_store = 0;
    addr     = '0;
    size     = '0;
    priv     = PRIV_M;
    #1;
  endtask

  // Build one cfg byte: {L, 2'b00 (WPRI), A[1:0], X, W, R}.
  function automatic logic [7:0] mkcfg(input logic l, input logic [1:0] a,
                                        input logic x, input logic w, input logic r);
    return {l, 2'b00, a, x, w, r};
  endfunction

  // NAPOT pmpaddr for [base, base+size_bytes), size_bytes a power of 2 >= 8.
  function automatic logic [53:0] mknapot(input logic [55:0] base,
                                           input int unsigned size_bytes);
    automatic int unsigned trailing_ones = $clog2(size_bytes) - 3;  // size_bytes/4 has log2-1 ones
    automatic logic [53:0] tail_mask = (54'd1 << trailing_ones) - 54'd1;
    return (base[55:2] & ~tail_mask) | tail_mask;
  endfunction

  int errors = 0;
  task automatic expect_fault(input string name,
                              input logic want,
                              input priv_e p,
                              input logic [55:0] a,
                              input logic [2:0] sz,
                              input logic isf, input logic isl, input logic iss);
    priv = p; valid = 1; addr = a; size = sz;
    is_fetch = isf; is_load = isl; is_store = iss;
    #1;
    if (fault !== want) begin
      $display("FAIL %s: priv=%0d addr=%h fault=%b want=%b", name, p, a, fault, want);
      errors++;
    end
    valid = 0; #1;
  endtask

  initial begin
    clear_all;
    #5;

    // ----- Test 1: NA4 hit, S-mode read with R=1 -> no fault -----
    pmpaddr[0] = 54'h00000000_004000;        // PA[55:2] = 0x4000 -> addr = 0x10000
    pmpcfg[0]  = mkcfg(.l(0), .a(2'b10), .x(0), .w(0), .r(1));
    expect_fault("NA4 read S R=1", 1'b0, PRIV_S, 56'h0000_0000_0001_0000, 3'd2, 0, 1, 0);

    // ----- Test 2: NA4 hit, S-mode write with W=0 -> fault -----
    expect_fault("NA4 write S W=0", 1'b1, PRIV_S, 56'h0000_0000_0001_0000, 3'd2, 0, 0, 1);

    // ----- Test 3: NAPOT 4 KB hit, U-mode read with R=1 -> no fault -----
    pmpaddr[1] = mknapot(56'h0000_0000_0002_0000, 4096);
    pmpcfg[1]  = mkcfg(.l(0), .a(2'b11), .x(1), .w(1), .r(1));
    expect_fault("NAPOT 4K read U RWX", 1'b0, PRIV_U,
                 56'h0000_0000_0002_0010, 3'd0, 0, 1, 0);

    // ----- Test 4: NAPOT 1 MB hit -----
    pmpaddr[2] = mknapot(56'h0000_0000_0040_0000, 1024*1024);
    pmpcfg[2]  = mkcfg(.l(0), .a(2'b11), .x(0), .w(0), .r(1));
    expect_fault("NAPOT 1M read S R=1", 1'b0, PRIV_S,
                 56'h0000_0000_0040_1234, 3'd0, 0, 1, 0);

    // ----- Test 5: Region priority -- region 0 R=0 shadows region 1 R=1 -----
    clear_all;
    pmpaddr[0] = mknapot(56'h0000_0000_0008_0000, 4096);
    pmpcfg[0]  = mkcfg(.l(0), .a(2'b11), .x(0), .w(0), .r(0));   // deny
    pmpaddr[1] = mknapot(56'h0000_0000_0008_0000, 4096);
    pmpcfg[1]  = mkcfg(.l(0), .a(2'b11), .x(0), .w(0), .r(1));   // allow
    expect_fault("priority deny shadows allow", 1'b1, PRIV_S,
                 56'h0000_0000_0008_0000, 3'd2, 0, 1, 0);

    // ----- Test 6: M-mode bypass when L=0 -----
    expect_fault("M bypass unlocked deny", 1'b0, PRIV_M,
                 56'h0000_0000_0008_0000, 3'd2, 0, 1, 0);

    // ----- Test 7: M-mode trapped when L=1 (locked, deny applies to M too) -----
    pmpcfg[0]  = mkcfg(.l(1), .a(2'b11), .x(0), .w(0), .r(0));
    expect_fault("M trapped locked deny", 1'b1, PRIV_M,
                 56'h0000_0000_0008_0000, 3'd2, 0, 1, 0);

    // ----- Test 8: No region matches -- M passes, S faults -----
    clear_all;
    expect_fault("no match M passes", 1'b0, PRIV_M, 56'h0000_dead_beef_babe, 3'd2, 0, 1, 0);
    expect_fault("no match S faults", 1'b1, PRIV_S, 56'h0000_dead_beef_babe, 3'd2, 0, 1, 0);

    // ----- Test 9: NA4 cross-region access (size > 4) -> fault -----
    clear_all;
    pmpaddr[0] = 54'h00000000_004000;
    pmpcfg[0]  = mkcfg(.l(0), .a(2'b10), .x(0), .w(0), .r(1));
    expect_fault("NA4 8B access faults", 1'b1, PRIV_S,
                 56'h0000_0000_0001_0000, 3'd3, 0, 1, 0);

    // ----- Test 10: entry 8 hit (PMP_CFG2 region) -- S-mode read with R=1 -----
    clear_all;
    pmpaddr[8] = mknapot(56'h0000_0000_0040_0000, 4096);
    pmpcfg[8]  = mkcfg(.l(0), .a(2'b11), .x(0), .w(0), .r(1));
    expect_fault("entry 8 NAPOT 4K read S R=1", 1'b0, PRIV_S,
                 56'h0000_0000_0040_0010, 3'd2, 0, 1, 0);

    // ----- Test 11: entry 15 hit + lock semantics -----
    clear_all;
    pmpaddr[15] = mknapot(56'h0000_0000_0080_0000, 4096);
    pmpcfg[15]  = mkcfg(.l(1), .a(2'b11), .x(0), .w(0), .r(1));   // L=1
    expect_fault("entry 15 NAPOT 4K read S R=1 (locked, allowed)", 1'b0, PRIV_S,
                 56'h0000_0000_0080_0020, 3'd2, 0, 1, 0);
    // M-mode locked region applies to M too. R=1 so reads still pass.
    expect_fault("entry 15 locked M read still passes (R=1)", 1'b0, PRIV_M,
                 56'h0000_0000_0080_0020, 3'd2, 0, 1, 0);
    // M-mode trapped on write (W=0)
    expect_fault("entry 15 locked M write fails (W=0)", 1'b1, PRIV_M,
                 56'h0000_0000_0080_0020, 3'd2, 0, 0, 1);

    if (errors == 0) $display("tb_pmp: PASS");
    else             $display("tb_pmp: FAIL %0d", errors);
    $finish;
  end

endmodule
