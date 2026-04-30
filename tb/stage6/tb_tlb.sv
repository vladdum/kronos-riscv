// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_tlb;
  import kronos_pkg::*;

  // Clock / reset
  logic            clk = 1'b0;
  logic            rst_n = 1'b0;

  // Lookup
  logic            lookup_valid;
  logic [kronos_pkg::XLEN-1:0] lookup_va;
  logic [15:0]     lookup_asid;
  priv_e           lookup_priv;
  logic            is_load, is_store, is_fetch;
  logic            sum_in, mxr_in;
  logic            lookup_hit, lookup_perm_fail;
  logic [55:0]     lookup_pa;
  logic            a_zero, d_zero;

  // Refill
  logic            refill_valid;
  logic [1:0]      refill_size;
  logic [35:0]     refill_vpn;
  logic [43:0]     refill_ppn;
  logic [15:0]     refill_asid;
  logic            refill_global;
  logic [3:0]      refill_perm;
  logic            refill_a, refill_d;

  // sfence
  logic            flush_valid;
  logic            flush_va_valid, flush_asid_valid;
  logic [kronos_pkg::XLEN-1:0] flush_va;
  logic [15:0]     flush_asid;

  // Error counter
  int              errors = 0;

  always #5 clk = ~clk;

  kronos_tlb #(.N(8)) u_dut (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .lookup_valid_i     (lookup_valid),
    .lookup_va_i        (lookup_va),
    .lookup_asid_i      (lookup_asid),
    .lookup_priv_i      (lookup_priv),
    .is_load_i          (is_load),
    .is_store_i         (is_store),
    .is_fetch_i         (is_fetch),
    .sum_i              (sum_in),
    .mxr_i              (mxr_in),
    .lookup_hit_o       (lookup_hit),
    .lookup_pa_o        (lookup_pa),
    .lookup_perm_fail_o (lookup_perm_fail),
    .lookup_a_zero_o    (a_zero),
    .lookup_d_zero_o    (d_zero),
    .refill_valid_i     (refill_valid),
    .refill_size_i      (refill_size),
    .refill_vpn_i       (refill_vpn),
    .refill_ppn_i       (refill_ppn),
    .refill_asid_i      (refill_asid),
    .refill_global_i    (refill_global),
    .refill_perm_i      (refill_perm),
    .refill_a_i         (refill_a),
    .refill_d_i         (refill_d),
    .flush_valid_i      (flush_valid),
    .flush_va_valid_i   (flush_va_valid),
    .flush_asid_valid_i (flush_asid_valid),
    .flush_va_i         (flush_va),
    .flush_asid_i       (flush_asid)
  );

  task automatic clear_inputs;
    lookup_valid     = 1'b0;
    lookup_va        = {kronos_pkg::XLEN{1'b0}};
    lookup_asid      = 16'h0;
    lookup_priv      = PRIV_M;
    is_load          = 1'b0;
    is_store         = 1'b0;
    is_fetch         = 1'b0;
    sum_in           = 1'b0;
    mxr_in           = 1'b0;
    refill_valid     = 1'b0;
    refill_size      = 2'b00;
    refill_vpn       = 36'h0;
    refill_ppn       = 44'h0;
    refill_asid      = 16'h0;
    refill_global    = 1'b0;
    refill_perm      = 4'h0;
    refill_a         = 1'b0;
    refill_d         = 1'b0;
    flush_valid      = 1'b0;
    flush_va_valid   = 1'b0;
    flush_asid_valid = 1'b0;
    flush_va         = {kronos_pkg::XLEN{1'b0}};
    flush_asid       = 16'h0;
  endtask

  task automatic do_refill(input logic [1:0]      sz,
                           input logic [35:0]     vpn,
                           input logic [43:0]     pn,
                           input logic [15:0]     aid,
                           input logic            gl,
                           input logic [3:0]      pm,
                           input logic            a,
                           input logic            d);
    @(posedge clk);
    refill_valid  = 1'b1;
    refill_size   = sz;
    refill_vpn    = vpn;
    refill_ppn    = pn;
    refill_asid   = aid;
    refill_global = gl;
    refill_perm   = pm;
    refill_a      = a;
    refill_d      = d;
    @(posedge clk);
    refill_valid = 1'b0;
  endtask

  task automatic do_lookup(input logic [kronos_pkg::XLEN-1:0] va,
                           input logic [15:0]     aid,
                           input priv_e           p,
                           input logic            isf,
                           input logic            isl,
                           input logic            iss,
                           input logic            sm,
                           input logic            mx);
    @(posedge clk);
    lookup_valid = 1'b1;
    lookup_va    = va;
    lookup_asid  = aid;
    lookup_priv  = p;
    is_fetch     = isf;
    is_load      = isl;
    is_store     = iss;
    sum_in       = sm;
    mxr_in       = mx;
    #1;  // settle combinational
  endtask

  task automatic end_lookup;
    @(posedge clk);
    lookup_valid = 1'b0;
    is_fetch     = 1'b0;
    is_load      = 1'b0;
    is_store     = 1'b0;
  endtask

  task automatic do_flush(input logic            va_v,
                          input logic            aid_v,
                          input logic [kronos_pkg::XLEN-1:0] va,
                          input logic [15:0]     aid);
    @(posedge clk);
    flush_valid      = 1'b1;
    flush_va_valid   = va_v;
    flush_asid_valid = aid_v;
    flush_va         = va;
    flush_asid       = aid;
    @(posedge clk);
    flush_valid = 1'b0;
  endtask

  task automatic check(input string name, input logic cond);
    if (!cond) begin
      $display("FAIL: %s", name);
      errors++;
    end
  endtask

  initial begin
    clear_inputs;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // ----- Test 1: 4 KB hit, S-mode read with R=1 -----
    // VPN = 0x12345; PPN = 0xABCDE; perm = R+W+X+~U
    do_refill(2'b00, 36'h0_0001_2345, 44'h0_0000_ABCDE, 16'd1, 1'b0, 4'b0_111, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0001_2345, 12'h040}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("4K hit S-mode R=1",            lookup_hit & ~lookup_perm_fail);
    check("4K PA reconstruction",         lookup_pa[31:0] == 32'hABCDE040);
    end_lookup;

    // ----- Test 2: 2 MB hit -----
    do_refill(2'b01, 36'h0_0002_0000, 44'h0_0000_C0000, 16'd1, 1'b0, 4'b0_111, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0002_0000, 12'h100}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("2M hit",                       lookup_hit & ~lookup_perm_fail);
    end_lookup;

    // ----- Test 3: ASID mismatch on non-global -----
    do_lookup({16'b0, 36'h0_0001_2345, 12'h040}, 16'd2, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("ASID mismatch -> miss",        ~lookup_hit);
    end_lookup;

    // ----- Test 4: Global override (refill with global=1) -----
    do_refill(2'b00, 36'h0_0003_0000, 44'h0_0000_AB000, 16'd5, 1'b1, 4'b0_111, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0003_0000, 12'h008}, 16'd99, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("global hits any ASID",         lookup_hit);
    end_lookup;

    // ----- Test 5: U-page accessed in S-mode without SUM=0 -> fail -----
    // refill perm: U=1, R=1; with SUM=0 should fail in S
    do_refill(2'b00, 36'h0_0004_0000, 44'h0_0000_DE000, 16'd1, 1'b0, 4'b1_001, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0004_0000, 12'h004}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("S accesses U-page SUM=0 fail", lookup_hit & lookup_perm_fail);
    end_lookup;

    // SUM=1 -> succeed
    do_lookup({16'b0, 36'h0_0004_0000, 12'h004}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
    check("S accesses U-page SUM=1 ok",   lookup_hit & ~lookup_perm_fail);
    end_lookup;

    // ----- Test 6: MXR — load on X-only page -----
    // Refill perm: U=0, X=1, W=0, R=0
    do_refill(2'b00, 36'h0_0005_0000, 44'h0_0000_F0000, 16'd1, 1'b0, 4'b0_100, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0005_0000, 12'h000}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("X-only load MXR=0 fail",       lookup_hit & lookup_perm_fail);
    end_lookup;
    do_lookup({16'b0, 36'h0_0005_0000, 12'h000}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b1);
    check("X-only load MXR=1 ok",         lookup_hit & ~lookup_perm_fail);
    end_lookup;

    // ----- Test 7: A=0 detection -----
    do_refill(2'b00, 36'h0_0006_0000, 44'h0_0000_60000, 16'd1, 1'b0, 4'b0_011, 1'b0, 1'b0);
    do_lookup({16'b0, 36'h0_0006_0000, 12'h000}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("A=0 detected on hit",          lookup_hit & a_zero);
    end_lookup;

    // ----- Test 8: D=0 + store -----
    do_refill(2'b00, 36'h0_0007_0000, 44'h0_0000_70000, 16'd1, 1'b0, 4'b0_011, 1'b1, 1'b0);
    do_lookup({16'b0, 36'h0_0007_0000, 12'h000}, 16'd1, PRIV_S,
              1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
    check("D=0 + store detected",         lookup_hit & d_zero);
    end_lookup;

    // ----- Test 9: sfence.vma full flush -----
    do_flush(1'b0, 1'b0, 64'h0, 16'h0);
    do_lookup({16'b0, 36'h0_0001_2345, 12'h040}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("full flush: prior hit gone",   ~lookup_hit);
    end_lookup;

    // ----- Test 10: sfence.vma per-VA -----
    do_refill(2'b00, 36'h0_000A_0000, 44'h0_000A_A000, 16'd1, 1'b0, 4'b0_011, 1'b1, 1'b0);
    do_refill(2'b00, 36'h0_000B_0000, 44'h0_000B_B000, 16'd1, 1'b0, 4'b0_011, 1'b1, 1'b0);
    do_flush(1'b1, 1'b0, {16'b0, 36'h0_000A_0000, 12'h0}, 16'h0);
    do_lookup({16'b0, 36'h0_000A_0000, 12'h0}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("per-VA flush: A gone",         ~lookup_hit);
    end_lookup;
    do_lookup({16'b0, 36'h0_000B_0000, 12'h0}, 16'd1, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("per-VA flush: B kept",         lookup_hit);
    end_lookup;

    // ----- Test 11: sfence.vma per-ASID -----
    do_refill(2'b00, 36'h0_000C_0000, 44'h0_000C_C000, 16'd2, 1'b0, 4'b0_011, 1'b1, 1'b0);
    do_refill(2'b00, 36'h0_000D_0000, 44'h0_000D_D000, 16'd3, 1'b0, 4'b0_011, 1'b1, 1'b0);
    do_flush(1'b0, 1'b1, 64'h0, 16'd2);
    do_lookup({16'b0, 36'h0_000C_0000, 12'h0}, 16'd2, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("per-ASID flush: 2 gone",       ~lookup_hit);
    end_lookup;
    do_lookup({16'b0, 36'h0_000D_0000, 12'h0}, 16'd3, PRIV_S,
              1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    check("per-ASID flush: 3 kept",       lookup_hit);
    end_lookup;

    if (errors == 0) $display("tb_tlb: PASS");
    else             $display("tb_tlb: FAIL %0d", errors);
    $finish;
  end

endmodule
