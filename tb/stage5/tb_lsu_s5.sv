// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_lsu_s5;
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
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .req_i           (req),
    .we_i            (we),
    .addr_i          (addr),
    .wdata_i         (wdata),
    .funct3_i        (funct3),
    .rdata_o         (rdata),
    .valid_o         (valid_out),
    .mem_stall_o     (mem_stall),
    .fp_dest_req_i   ('0),
    .fp_store_data_i ('0),
    .fp_dest_rsp_o   (),
    .fp_rdata_o      (),
    .is_lr_i         (is_lr),
    .is_sc_i         (is_sc),
    .is_amo_i        (is_amo),
    .amo_funct5_i    (amo_funct5),
    .amo_src_i       (amo_src),
    .sc_success_o    (sc_success),
    .axi_req_o       (axi_req),
    .axi_rsp_i       (axi_rsp)
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

    // LW sign-extend
    mem[0] = 32'h8000_0001;
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b010;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_80000001) begin
      $display("FAIL LW_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // LWU (zero-extend)
    req = 1; we = 0; addr = 32'h0; funct3 = 3'b110;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_80000001) begin
      $display("FAIL LWU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // SD then LD
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

    // LB sign-extend
    mem[8] = 32'h000000FF;
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b000;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_FFFFFFFF) begin
      $display("FAIL LB_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // LBU
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b100;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h00000000_000000FF) begin
      $display("FAIL LBU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // LR.W
    mem[16] = 32'hAABB_CCDD;
    req = 1; we = 0; addr = 32'h40; funct3 = 3'b010; is_lr = 1;
    @(posedge clk); req = 0; is_lr = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AABBCCDD) begin
      $display("FAIL LR_W: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // SC.W success
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

    // SC.W fail (reservation cleared)
    req = 1; we = 1; addr = 32'h40; funct3 = 3'b010; is_sc = 1;
    wdata = {32'b0, 32'hDEAD_BEEF};
    @(posedge clk); req = 0; is_sc = 0;
    wait_valid;
    if (rdata !== 64'h1) begin
      $display("FAIL SC_W_fail: got %016h", rdata); errors++;
    end
    if (mem[16] !== 32'h1122_3344) begin
      $display("FAIL SC_W_fail_mem: got %08h", mem[16]); errors++;
    end
    @(posedge clk);

    // AMOADD.W
    mem[20] = 32'd100;
    req = 1; we = 0; addr = 32'h50; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00000;
    amo_src = 64'd25;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    if (rdata !== 64'h0000_0000_0000_0064) begin
      $display("FAIL AMOADD_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk); @(posedge clk);
    if (mem[20] !== 32'd125) begin
      $display("FAIL AMOADD_mem: got %0d", mem[20]); errors++;
    end

    // AMOSWAP.W
    mem[24] = 32'hAAAA_BBBB;
    req = 1; we = 0; addr = 32'h60; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00001;
    amo_src = 64'hCCCC_DDDD;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_AAAABBBB) begin
      $display("FAIL AMOSWAP_rdata: got %016h", rdata); errors++;
    end
    @(posedge clk); @(posedge clk);
    if (mem[24] !== 32'hCCCC_DDDD) begin
      $display("FAIL AMOSWAP_mem: got %08h", mem[24]); errors++;
    end

    // SH then LH/LHU
    req = 1; we = 1; addr = 32'h70; funct3 = 3'b001;
    wdata = 64'h0000_ABCD;
    @(posedge clk); req = 0;
    wait_valid;
    @(posedge clk);

    req = 1; we = 0; addr = 32'h70; funct3 = 3'b001;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'hFFFFFFFF_FFFFABCD) begin
      $display("FAIL LH_sext: got %016h", rdata); errors++;
    end
    @(posedge clk);

    req = 1; we = 0; addr = 32'h70; funct3 = 3'b101;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h0000_0000_0000_ABCD) begin
      $display("FAIL LHU: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // AMOXOR.W
    mem[32] = 32'hFF00_FF00;
    req = 1; we = 0; addr = 32'h80; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00100; amo_src = 64'hF0F0_F0F0;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[32] !== 32'h0FF0_0FF0) begin
      $display("FAIL AMOXOR_mem: got %08h", mem[32]); errors++;
    end

    // AMOAND.W
    mem[36] = 32'hFFFF_0000;
    req = 1; we = 0; addr = 32'h90; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b01100; amo_src = 64'hFF00_FF00;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[36] !== 32'hFF00_0000) begin
      $display("FAIL AMOAND_mem: got %08h", mem[36]); errors++;
    end

    // AMOOR.W
    mem[40] = 32'h0000_FF00;
    req = 1; we = 0; addr = 32'hA0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b01000; amo_src = 64'hFF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[40] !== 32'hFF00_FF00) begin
      $display("FAIL AMOOR_mem: got %08h", mem[40]); errors++;
    end

    // AMOMIN.W (signed min: -1 vs 1 → -1 wins)
    mem[44] = 32'hFFFF_FFFF;   // -1 signed
    req = 1; we = 0; addr = 32'hB0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b10000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[44] !== 32'hFFFF_FFFF) begin
      $display("FAIL AMOMIN_mem: got %08h", mem[44]); errors++;
    end

    // AMOMAX.W (signed max: 5 vs 3 → 5 stays)
    mem[48] = 32'd5;
    req = 1; we = 0; addr = 32'hC0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b10100; amo_src = 64'd3;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[48] !== 32'd5) begin
      $display("FAIL AMOMAX_mem: got %08h", mem[48]); errors++;
    end

    // AMOMINU.W (unsigned min: 0xFFFF vs 0x1 → 0x1 wins)
    mem[52] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'hD0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b11000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[52] !== 32'd1) begin
      $display("FAIL AMOMINU_mem: got %08h", mem[52]); errors++;
    end

    // AMOMAXU.W (unsigned max: 1 vs 0xFF → 0xFF wins)
    mem[56] = 32'd1;
    req = 1; we = 0; addr = 32'hE0; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b11100; amo_src = 64'hFF;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[56] !== 32'hFF) begin
      $display("FAIL AMOMAXU_mem: got %08h", mem[56]); errors++;
    end

    // 64-bit AMO suite — covers doubleword amo_new_val paths (lines 161-169)
    // AMOXOR.D
    mem[64] = 32'hFF00_FF00; mem[65] = 32'h0000_0000;
    req = 1; we = 0; addr = 32'h100; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b00100; amo_src = 64'hF0F0_F0F0;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[64] !== 32'h0FF0_0FF0) begin
      $display("FAIL AMOXOR_D_mem: got %08h", mem[64]); errors++;
    end

    // AMOAND.D
    mem[68] = 32'hFFFF_0000; mem[69] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'h110; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b01100; amo_src = 64'hFF00_0000_FF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[68] !== 32'hFF00_0000) begin
      $display("FAIL AMOAND_D_mem_lo: got %08h", mem[68]); errors++;
    end

    // AMOOR.D
    mem[72] = 32'h0000_FF00; mem[73] = 32'h0;
    req = 1; we = 0; addr = 32'h120; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b01000; amo_src = 64'hFF00_0000;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[72] !== 32'hFF00_FF00) begin
      $display("FAIL AMOOR_D_mem: got %08h", mem[72]); errors++;
    end

    // AMOMIN.D (signed: -1 vs 1 → -1 wins)
    mem[76] = 32'hFFFF_FFFF; mem[77] = 32'hFFFF_FFFF;  // -1 as int64
    req = 1; we = 0; addr = 32'h130; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b10000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[76] !== 32'hFFFF_FFFF || mem[77] !== 32'hFFFF_FFFF) begin
      $display("FAIL AMOMIN_D_mem: %08h_%08h", mem[77], mem[76]); errors++;
    end

    // AMOMAX.D (signed: 5 vs 3 → 5 stays)
    mem[80] = 32'd5; mem[81] = 32'd0;
    req = 1; we = 0; addr = 32'h140; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b10100; amo_src = 64'd3;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[80] !== 32'd5) begin
      $display("FAIL AMOMAX_D_mem: got %08h", mem[80]); errors++;
    end

    // AMOMINU.D (unsigned: 0xFFFFFFFFFFFFFFFF vs 1 → 1 wins)
    mem[84] = 32'hFFFF_FFFF; mem[85] = 32'hFFFF_FFFF;
    req = 1; we = 0; addr = 32'h150; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b11000; amo_src = 64'd1;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[84] !== 32'd1 || mem[85] !== 32'd0) begin
      $display("FAIL AMOMINU_D_mem: %08h_%08h", mem[85], mem[84]); errors++;
    end

    // AMOMAXU.D (unsigned: 1 vs 0xFF → 0xFF wins)
    mem[88] = 32'd1; mem[89] = 32'd0;
    req = 1; we = 0; addr = 32'h160; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b11100; amo_src = 64'hFF;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[88] !== 32'hFF) begin
      $display("FAIL AMOMAXU_D_mem: got %08h", mem[88]); errors++;
    end

    // AMOADD.D (doubleword AMO — activates 64-bit amo_new_val path)
    mem[60] = 32'd10; mem[61] = 32'd0;   // 64-bit value = 10
    req = 1; we = 0; addr = 32'hF0; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b00000; amo_src = 64'd7;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[60] !== 32'd17) begin
      $display("FAIL AMOADDD_mem: got %08h", mem[60]); errors++;
    end

    // ---- Directed: load with invalid funct3=7 → default arm  [covers line 206] ----
    mem[4] = 32'hDEAD_BEEF;
    req = 1; we = 0; addr = 32'h10; funct3 = 3'b111;
    @(posedge clk); req = 0;
    wait_valid;
    if (rdata !== 64'h0) begin
      $display("FAIL LOAD_BAD_F3: got %016h", rdata); errors++;
    end
    @(posedge clk);

    // ---- Directed: AMO word with invalid funct5=2 → default arm  [covers line 153] ----
    mem[8] = 32'd10;
    req = 1; we = 0; addr = 32'h20; funct3 = 3'b010; is_amo = 1;
    amo_funct5 = 5'b00010; amo_src = 64'd7;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[8] !== 32'd0) begin
      $display("FAIL AMO_BAD_F5W: got %08h", mem[8]); errors++;
    end

    // ---- Directed: AMO dword with invalid funct5=2 → default arm  [covers line 174] ----
    mem[12] = 32'd5; mem[13] = 32'd0;
    req = 1; we = 0; addr = 32'h30; funct3 = 3'b011; is_amo = 1;
    amo_funct5 = 5'b00010; amo_src = 64'd3;
    @(posedge clk); req = 0; is_amo = 0;
    wait_valid;
    @(posedge clk); @(posedge clk);
    if (mem[12] !== 32'd0 || mem[13] !== 32'd0) begin
      $display("FAIL AMO_BAD_F5D: got %08h/%08h", mem[13], mem[12]); errors++;
    end

    if (errors == 0) $display("tb_lsu_s5: ALL PASSED");
    else $display("tb_lsu_s5: %0d FAILED", errors);
    $finish;
  end
endmodule
