// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_lsu_s4;
  import kronos_pkg::*;

  logic             clk, rst_n;
  logic             req, we;
  logic [31:0]      addr;
  logic [63:0]      wdata;
  logic [2:0]       funct3;
  logic [63:0]      rdata;
  logic             valid_out, mem_stall;
  logic             is_lr, is_sc, is_amo;
  logic [4:0]       amo_funct5;
  logic [63:0]      amo_src;
  logic             sc_success;
  kronos_axi_req_t  axi_req;
  kronos_axi_resp_t axi_rsp;

  kronos_lsu dut (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .req_i       (req),
    .we_i        (we),
    .addr_i      (addr),
    .wdata_i     (wdata),
    .funct3_i    (funct3),
    .rdata_o     (rdata),
    .valid_o     (valid_out),
    .mem_stall_o (mem_stall),
    .is_lr_i     (is_lr),
    .is_sc_i     (is_sc),
    .is_amo_i    (is_amo),
    .amo_funct5_i(amo_funct5),
    .amo_src_i   (amo_src),
    .sc_success_o(sc_success),
    .axi_req_o   (axi_req),
    .axi_rsp_i   (axi_rsp)
  );

  initial begin clk = 0; forever #5 clk = ~clk; end

  logic [31:0] mem [256];
  int errors = 0;

  logic [31:0] ar_addr_q;
  logic        ar_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_rsp    <= '0;
      ar_pending <= 0;
    end else begin
      axi_rsp <= '0;
      axi_rsp.ar_ready <= 1;
      axi_rsp.aw_ready <= 1;
      axi_rsp.w_ready  <= 1;

      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        ar_addr_q  <= axi_req.ar.addr;
        ar_pending <= 1;
      end

      if (ar_pending) begin
        axi_rsp.r_valid <= 1;
        axi_rsp.r.data  <= mem[ar_addr_q[9:2]];
        axi_rsp.r.last  <= 1;
        ar_pending      <= 0;
      end

      if (axi_req.aw_valid && axi_req.w_valid) begin
        for (int i = 0; i < 4; i++)
          if (axi_req.w.strb[i]) mem[axi_req.aw.addr[9:2]][i*8 +: 8] <= axi_req.w.data[i*8 +: 8];
        axi_rsp.b_valid <= 1;
      end
    end
  end

  task wait_valid;
    while (!valid_out) @(posedge clk);
  endtask

  initial begin
    rst_n = 0; req = 0; we = 0; is_lr = 0; is_sc = 0; is_amo = 0;
    amo_funct5 = 0; amo_src = 0;
    for (int i = 0; i < 256; i++) mem[i] = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    mem[0] = 32'h8000_0001;
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b010;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_80000001) begin
      $display("FAIL LW_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    req = 1; we = 0; addr = 32'h0; funct3 = 3'b110;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_80000001) begin
      $display("FAIL LWU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    req = 1; we = 1; addr = 32'h10; funct3 = 3'b011;
    wdata = 64'hDEADBEEF_CAFEBABE;
    @(posedge clk); req = 0;
    wait_valid;
    @(posedge clk);

    if (mem[4] !== 32'hCAFEBABE) begin
      $display("FAIL SD_lo: mem[4]=%08h", mem[4]); errors++;
    end
    if (mem[5] !== 32'hDEADBEEF) begin
      $display("FAIL SD_hi: mem[5]=%08h", mem[5]); errors++;
    end

    req = 1; we = 0; addr = 32'h10; funct3 = 3'b011;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hDEADBEEF_CAFEBABE) begin
      $display("FAIL LD: got %016h", rdata); errors++;
    end
    @(posedge clk);

    mem[8] = 32'h000000FF;
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b000;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_FFFFFFFF) begin
      $display("FAIL LB_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    req = 1; we = 0; addr = 32'h20; funct3 = 3'b100;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_000000FF) begin
      $display("FAIL LBU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- LR.W: load with reservation ----
    mem[16] = 32'hAABB_CCDD;
    req = 1; we = 0; addr = 32'h40; funct3 = 3'b010; is_lr = 1;
    @(posedge clk); req = 0; is_lr = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AABBCCDD) begin  // LW sign-extends to 64
      $display("FAIL LR_W: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- SC.W success: reservation matches ----
    req = 1; we = 1; addr = 32'h40; funct3 = 3'b010; is_sc = 1;
    wdata = {32'b0, 32'h1122_3344};
    @(posedge clk); req = 0; is_sc = 0;
    wait_valid;
    if (rdata !== 64'h0) begin
      $display("FAIL SC_W_success: got %016h", rdata); errors++;
    end
    if (mem[16] !== 32'h1122_3344) begin
      $display("FAIL SC_W_mem: got %08h", mem[16]); errors++;
    end
    @(posedge clk);

    // ---- SC.W fail: no prior LR (reservation cleared by previous SC) ----
    req = 1; we = 1; addr = 32'h40; funct3 = 3'b010; is_sc = 1;
    wdata = {32'b0, 32'hDEAD_BEEF};
    @(posedge clk); req = 0; is_sc = 0;
    wait_valid;
    if (rdata !== 64'h1) begin
      $display("FAIL SC_W_fail: got %016h", rdata); errors++;
    end
    if (mem[16] !== 32'h1122_3344) begin  // UNCHANGED
      $display("FAIL SC_W_fail_mem: got %08h", mem[16]); errors++;
    end
    @(posedge clk);

    // ---- AMOADD.W ----
    mem[20] = 32'd100;  // addr 0x50 (word index 20)
    req = 1; we = 0; addr = 32'h50; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00000;  // AMOADD
    amo_src = 64'd25;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    // AMO returns OLD value (100, sign-extended since funct3=W)
    if (rdata !== 64'h0000_0000_0000_0064) begin
      $display("FAIL AMOADD_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk); @(posedge clk);  // let memory write settle
    if (mem[20] !== 32'd125) begin
      $display("FAIL AMOADD_mem: got %0d", mem[20]); errors++;
    end

    // ---- AMOSWAP.W ----
    mem[24] = 32'hAAAA_BBBB;  // addr 0x60
    req = 1; we = 0; addr = 32'h60; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00001;  // AMOSWAP
    amo_src = 64'hCCCC_DDDD;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AAAABBBB) begin  // old value, sign-extended
      $display("FAIL AMOSWAP_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk); @(posedge clk);
    if (mem[24] !== 32'hCCCC_DDDD) begin
      $display("FAIL AMOSWAP_mem: got %08h", mem[24]); errors++;
    end

    if (errors == 0) $display("tb_lsu_s4: ALL PASSED");
    else $display("tb_lsu_s4: %0d FAILED", errors);
    $finish;
  end
endmodule
