// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_lsu_s3.sv — unit testbench for stage3 kronos_lsu (AXI4 FSM).
// Tests: LW, SW, LB sign-extend, AW/W split acceptance, back-to-back.
module tb_lsu_s3;
  import kronos_pkg::*;

  logic             clk, rst_n;
  logic             req, we;
  logic [31:0]      addr, wdata;
  logic [2:0]       funct3;
  logic [31:0]      rdata;
  logic             valid, mem_stall;
  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  kronos_lsu u_lsu (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .req_i       (req),
    .we_i        (we),
    .addr_i      (addr),
    .wdata_i     (wdata),
    .funct3_i    (funct3),
    .rdata_o     (rdata),
    .valid_o     (valid),
    .mem_stall_o (mem_stall),
    .axi_req_o   (axi_req),
    .axi_rsp_i   (axi_rsp)
  );

  // Clock: 10 ns period
  initial clk = 0;
  always #5 clk = ~clk;

  // Helper: assert with message
  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      $finish(1);
    end
  endtask

  // Helper: single AXI4 rising-edge tick.
  // Drives slave responses (axi_rsp) before the clock edge, then waits for
  // posedge.  Verilator's coroutine resumes after the NBA region so state_q
  // and all combinatorial outputs are stable when the task returns.
  task automatic tick(
    input logic ar_ready, r_valid, logic [63:0] r_data,
    input logic aw_ready, w_ready, b_valid
  );
    axi_rsp          = '0;
    axi_rsp.ar_ready = ar_ready;
    axi_rsp.r_valid  = r_valid;
    axi_rsp.r.data   = r_data;
    axi_rsp.r.last   = 1'b1;
    axi_rsp.aw_ready = aw_ready;
    axi_rsp.w_ready  = w_ready;
    axi_rsp.b_valid  = b_valid;
    @(posedge clk);
  endtask

  int fail = 0;

  initial begin
    // ---- Reset ----
    rst_n  = 0; req = 0; we = 0;
    addr   = '0; wdata = '0; funct3 = 3'b010;
    axi_rsp = '0;
    @(posedge clk); @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ==============================================================
    // TEST 1: LW — load word, 1-cycle AR latency, 1-cycle R latency
    // ==============================================================
    req = 1; we = 0; addr = 32'h0000_0100; funct3 = 3'b010; // LW

    // Tick 1: IDLE → LOAD_ADDR.  ar_valid is driven; slave not yet ready.
    tick(0,0,0, 0,0,0);
    check(axi_req.ar_valid,                    "T1: ar_valid not asserted in LOAD_ADDR");
    check(axi_req.ar.addr == 32'h0000_0100,    "T1: ar_addr wrong");
    check(mem_stall,                           "T1: mem_stall should be asserted");
    check(!valid,                              "T1: valid should not be asserted");

    // Tick 2: LOAD_ADDR → LOAD_DATA.  Slave accepts AR (ar_ready=1).
    tick(1,0,0, 0,0,0);
    check(!axi_req.ar_valid,  "T1: ar_valid should be 0 in LOAD_DATA");
    check(axi_req.r_ready,    "T1: r_ready should be 1 in LOAD_DATA");

    // Tick 3: LOAD_DATA → LOAD_DONE.  Slave sends read data (64-bit beat).
    // addr=0x100 → addr[2]=0 → lower lane used.
    tick(0, 1, 64'hCAFECAFE_DEAD_BEEF, 0,0,0);
    check(valid,                   "T1: valid should be asserted in LOAD_DONE");
    check(!mem_stall,              "T1: mem_stall should clear in LOAD_DONE");
    check(rdata == 32'hDEAD_BEEF,  "T1: rdata wrong");

    // De-assert req → LSU returns to IDLE
    req = 0;
    tick(0,0,0, 0,0,0);
    check(!valid, "T1: valid should clear after req=0");
    $display("TEST 1 PASS: LW");

    // ==============================================================
    // TEST 2: SW — store word
    // ==============================================================
    req = 1; we = 1; addr = 32'h0000_0200; wdata = 32'h1234_5678; funct3 = 3'b010; // SW

    // Tick 1: IDLE → STORE_SEND.  AW and W should both be asserted.
    tick(0,0,0, 0,0,0);
    check(axi_req.aw_valid,                          "T2: aw_valid not asserted");
    check(axi_req.w_valid,                           "T2: w_valid not asserted");
    check(axi_req.aw.addr == 32'h0000_0200,          "T2: aw_addr wrong");
    // SW to 0x200: addr[2]=0 → lower 32-bit lane → data replicated, strb 0F
    check(axi_req.w.data[31:0] == 32'h1234_5678,     "T2: w_data wrong");
    check(axi_req.w.strb  == 8'h0F,                  "T2: w_strb wrong for SW");
    check(axi_req.w.last,                            "T2: w_last should be 1");
    check(mem_stall,                                 "T2: mem_stall should be asserted");

    // Tick 2: STORE_SEND → STORE_RESP.  Slave accepts AW and W simultaneously.
    tick(0,0,0, 1,1,0);
    check(!axi_req.aw_valid,  "T2: aw_valid should clear after aw_ready");
    check(!axi_req.w_valid,   "T2: w_valid should clear after w_ready");
    check(axi_req.b_ready,    "T2: b_ready should be asserted in STORE_RESP");

    // Tick 3: STORE_RESP → STORE_DONE.  Slave sends B response.
    tick(0,0,0, 0,0,1);
    check(valid,     "T2: valid should fire in STORE_DONE");
    check(!mem_stall, "T2: mem_stall should clear in STORE_DONE");

    req = 0;
    tick(0,0,0, 0,0,0);
    check(!valid, "T2: valid should clear after req=0");
    $display("TEST 2 PASS: SW");

    // ==============================================================
    // TEST 3: LB — load byte, sign-extend from byte 1 (addr=0x101)
    // ==============================================================
    req = 1; we = 0; addr = 32'h0000_0101; funct3 = 3'b000; // LB
    tick(0,0,0, 0,0,0);           // IDLE → LOAD_ADDR
    tick(1,0,0, 0,0,0);           // LOAD_ADDR → LOAD_DATA (AR accepted)
    // addr=0x101: addr[2]=0 → lower lane. byte 1 = 0x8F → sign-extended = 32'hFFFF_FF8F
    // 64-bit beat: lower word = 32'h0000_8F00, upper word = don't-care.
    tick(0, 1, 64'h0000_0000_0000_8F00, 0,0,0); // LOAD_DATA → LOAD_DONE
    check(rdata == 32'hFFFF_FF8F,  "T3: LB sign-extension wrong");
    req = 0;
    tick(0,0,0, 0,0,0);           // LOAD_DONE → IDLE
    $display("TEST 3 PASS: LB sign-extend");

    // ==============================================================
    // TEST 4: AW and W accepted in different cycles
    // ==============================================================
    req = 1; we = 1; addr = 32'h0000_0300; wdata = 32'hABCD_EF01; funct3 = 3'b010;
    tick(0,0,0, 0,0,0);  // IDLE → STORE_SEND (nothing accepted yet)
    // Accept AW only
    tick(0,0,0, 1,0,0);
    check(!axi_req.aw_valid,  "T4: aw_valid should clear after aw_ready");
    check(axi_req.w_valid,    "T4: w_valid should still be asserted");
    // Accept W
    tick(0,0,0, 0,1,0);
    check(!axi_req.w_valid,  "T4: w_valid should clear after w_ready");
    check(axi_req.b_ready,   "T4: b_ready should be asserted");
    // B fires
    tick(0,0,0, 0,0,1);
    check(valid, "T4: valid should fire");
    req = 0;
    tick(0,0,0, 0,0,0);
    $display("TEST 4 PASS: AW/W split acceptance");

    // ==============================================================
    // TEST 5: Back-to-back (LW then SW)
    // ==============================================================
    // LW
    req = 1; we = 0; addr = 32'h0000_0400; funct3 = 3'b010;
    tick(0,0,0, 0,0,0);            // IDLE → LOAD_ADDR
    tick(1,0,0, 0,0,0);            // LOAD_ADDR → LOAD_DATA
    tick(0,1,64'h0000_0000_CAFE_F00D, 0,0,0); // LOAD_DATA → LOAD_DONE (addr[2]=0)
    check(rdata == 32'hCAFE_F00D,  "T5: LW rdata wrong");
    // Release LOAD_DONE
    we = 1; addr = 32'h0000_0500; wdata = 32'hBEEF_CAFE;
    req = 0;
    tick(0,0,0, 0,0,0); // LOAD_DONE → IDLE
    // SW
    req = 1;
    tick(0,0,0, 0,0,0);  // IDLE → STORE_SEND
    tick(0,0,0, 1,1,0);  // STORE_SEND → STORE_RESP
    tick(0,0,0, 0,0,1);  // STORE_RESP → STORE_DONE
    check(valid, "T5: SW valid should fire");
    req = 0;
    tick(0,0,0, 0,0,0);
    $display("TEST 5 PASS: back-to-back LW->SW");

    if (fail == 0) begin
      $display("ALL TESTS PASSED");
      $finish(0);
    end else begin
      $finish(1);
    end
  end

  // Timeout watchdog
  initial begin
    #50000;
    $display("TIMEOUT");
    $finish(1);
  end
endmodule
