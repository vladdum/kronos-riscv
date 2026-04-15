// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_core_fp_forwarding — integration TB: back-to-back FP ops with forwarding.
//
// Program (boot at 0x0000):
//   lui  x1, 0x3F800   ; x1 = 0x3F800000 (1.0f bit-pattern)
//   fmv.w.x f1, x1     ; f1 = NaN-boxed 1.0f
//   fmv.w.x f2, x1     ; f2 = NaN-boxed 1.0f
//   fmul.s  f3, f1, f2 ; f3 = 1.0f × 1.0f = 1.0f  (4-cycle FMUL)
//   fadd.s  f4, f3, f3 ; f4 = 1.0f + 1.0f = 2.0f  (forwarded f3)
//   lui  x5, 0x40000   ; x5 = 0x40000000
//   sw   x10, 0(x5)    ; halt  (x10=0 → pass)
//
// Expected after halt: f4 == 64'hFFFFFFFF_40000000 (NaN-boxed 2.0f).
// The forwarding network delivers the fmul result to fadd without a
// regfile write-then-read round-trip; if forwarding were absent the
// pipeline stall mechanism still guarantees correctness (result via stall),
// but the TB verifies the correct value regardless.

`timescale 1ns/1ps
module tb_core_fp_forwarding;
  import kronos_pkg::*;

  // -----------------------------------------------------------------------
  // Memory: 256 B / 64 words
  // -----------------------------------------------------------------------
  logic [31:0] mem [64];

  // -----------------------------------------------------------------------
  // Clock / reset
  // -----------------------------------------------------------------------
  logic clk  = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  kronos_axi_req_t  instr_req, data_req;
  kronos_axi_resp_t instr_rsp, data_rsp;

  kronos_top u_top (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .instr_axi_req_o (instr_req),
    .instr_axi_rsp_i (instr_rsp),
    .data_axi_req_o  (data_req),
    .data_axi_rsp_i  (data_rsp),
    .irq_timer_i     (1'b0),
    .irq_fast_i      (15'd0),
    .boot_addr_i     (32'h0)
  );

  // -----------------------------------------------------------------------
  // AXI slave — instruction port
  // -----------------------------------------------------------------------
  logic        instr_r_pend;
  logic [31:0] instr_r_data_q;

  always_comb begin
    instr_rsp          = '0;
    instr_rsp.ar_ready = 1'b1;
    instr_rsp.r_valid  = instr_r_pend;
    instr_rsp.r.data   = instr_r_data_q;
    instr_rsp.r.last   = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_r_pend   <= 1'b0;
      instr_r_data_q <= '0;
    end else begin
      if (instr_r_pend && instr_req.r_ready) begin
        if (instr_req.ar_valid) begin
          instr_r_data_q <= mem[instr_req.ar.addr[7:2]];
        end else begin
          instr_r_pend <= 1'b0;
        end
      end else if (!instr_r_pend && instr_req.ar_valid) begin
        instr_r_data_q <= mem[instr_req.ar.addr[7:2]];
        instr_r_pend   <= 1'b1;
      end
    end
  end

  // -----------------------------------------------------------------------
  // AXI slave — data port
  // -----------------------------------------------------------------------
  logic        data_r_pend;
  logic [31:0] data_r_data_q;
  logic        data_aw_done;
  logic        data_w_done;
  logic [31:0] data_aw_addr_q;
  logic [31:0] data_w_data_q;
  logic [ 3:0] data_w_strb_q;
  logic        data_b_pend;
  int          halted;

  always_comb begin
    data_rsp          = '0;
    data_rsp.ar_ready = 1'b1;
    data_rsp.aw_ready = 1'b1;
    data_rsp.w_ready  = 1'b1;
    data_rsp.r_valid  = data_r_pend;
    data_rsp.r.data   = data_r_data_q;
    data_rsp.r.last   = 1'b1;
    data_rsp.b_valid  = data_b_pend;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_r_pend    <= 1'b0;
      data_r_data_q  <= '0;
      data_aw_done   <= 1'b0;
      data_w_done    <= 1'b0;
      data_aw_addr_q <= '0;
      data_w_data_q  <= '0;
      data_w_strb_q  <= '0;
      data_b_pend    <= 1'b0;
      halted         <= 0;
    end else begin
      if (data_r_pend && data_req.r_ready) begin
        if (data_req.ar_valid) begin
          data_r_data_q <= mem[data_req.ar.addr[7:2]];
        end else begin
          data_r_pend <= 1'b0;
        end
      end else if (!data_r_pend && data_req.ar_valid) begin
        data_r_data_q <= mem[data_req.ar.addr[7:2]];
        data_r_pend   <= 1'b1;
      end

      if (data_req.aw_valid) begin
        data_aw_addr_q <= data_req.aw.addr;
        data_aw_done   <= 1'b1;
      end
      if (data_req.w_valid) begin
        data_w_data_q <= data_req.w.data;
        data_w_strb_q <= data_req.w.strb;
        data_w_done   <= 1'b1;
      end

      if ((data_aw_done || data_req.aw_valid) &&
          (data_w_done  || data_req.w_valid)  && !data_b_pend) begin
        automatic logic [31:0] waddr = data_aw_done ? data_aw_addr_q : data_req.aw.addr;
        automatic logic [31:0] wdata = data_w_done  ? data_w_data_q  : data_req.w.data;
        automatic logic [ 3:0] wstrb = data_w_done  ? data_w_strb_q  : data_req.w.strb;
        if ((waddr & 32'hC000_0000) == 32'h4000_0000) begin
          halted <= halted + 1;
        end else begin
          automatic int wi = int'(waddr[7:2]);
          if (wstrb[0]) mem[wi][ 7: 0] <= wdata[ 7: 0];
          if (wstrb[1]) mem[wi][15: 8] <= wdata[15: 8];
          if (wstrb[2]) mem[wi][23:16] <= wdata[23:16];
          if (wstrb[3]) mem[wi][31:24] <= wdata[31:24];
        end
        data_aw_done <= 1'b0;
        data_w_done  <= 1'b0;
        data_b_pend  <= 1'b1;
      end

      if (data_b_pend && data_req.b_ready) begin
        data_b_pend <= 1'b0;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Test body
  // -----------------------------------------------------------------------
  int errors;

  initial begin
    for (int i = 0; i < 64; i++) mem[i] = 32'h0000_0013; // NOP

    // Instruction program
    mem[0] = 32'h3F80_00B7; // lui  x1, 0x3F800   ; x1 = 1.0f bits
    mem[1] = 32'hF000_80D3; // fmv.w.x f1, x1     ; f1 = NaN-boxed 1.0f
    mem[2] = 32'hF000_8153; // fmv.w.x f2, x1     ; f2 = NaN-boxed 1.0f
    mem[3] = 32'h1020_81D3; // fmul.s  f3, f1, f2 ; f3 = 1.0f (FMUL 4cy)
    mem[4] = 32'h0031_8253; // fadd.s  f4, f3, f3 ; f4 = 2.0f (fwd f3)
    mem[5] = 32'h4000_02B7; // lui  x5, 0x40000   ; x5 = 0x40000000
    mem[6] = 32'h00A2_A023; // sw   x10, 0(x5)    ; halt

    errors = 0;

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;

    fork
      begin : wait_halt
        wait (halted > 0);
      end
      begin : timeout
        repeat (700) @(posedge clk);
        $display("FAIL tb_core_fp_forwarding: timeout (no halt within 700 cycles)");
        errors++;
        $finish(1);
      end
    join_any
    disable fork;

    @(posedge clk);

    // Check: f4 = NaN-boxed 2.0f = 0xFFFFFFFF_40000000
    if (u_top.u_regfile_fp.rf[4] !== 64'hFFFF_FFFF_4000_0000) begin
      $display("FAIL tb_core_fp_forwarding: f4 = %016h, expected FFFFFFFF40000000",
               u_top.u_regfile_fp.rf[4]);
      errors++;
    end else begin
      $display("PASS tb_core_fp_forwarding: f4 = %016h", u_top.u_regfile_fp.rf[4]);
    end

    $finish(errors != 0);
  end

endmodule
