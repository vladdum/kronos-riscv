// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_regfile_fp;
  logic        clk = 0;
  logic        rst_n = 0;
  logic [4:0]  ra1, ra2, ra3, wa;
  logic [63:0] rd1, rd2, rd3, wd;
  logic        we;

  kronos_regfile_fp u_dut (
    .clk_i   (clk), .rst_ni (rst_n),
    .ra1_i   (ra1), .rd1_o (rd1),
    .ra2_i   (ra2), .rd2_o (rd2),
    .ra3_i   (ra3), .rd3_o (rd3),
    .wa_i    (wa),  .wd_i  (wd), .we_i (we)
  );

  always #5 clk = ~clk;

  initial begin
    rst_n = 0; we = 0; wa = 0; wd = 0; ra1 = 0; ra2 = 0; ra3 = 0;
    #12 rst_n = 1;

    // Write f3 = 0xDEADBEEF_CAFEBABE
    @(negedge clk) we = 1; wa = 3; wd = 64'hDEAD_BEEF_CAFE_BABE;
    @(negedge clk) we = 0;

    // Read f3 on all three ports simultaneously
    @(negedge clk) ra1 = 3; ra2 = 3; ra3 = 3;
    @(posedge clk) #1;
    if (rd1 !== 64'hDEAD_BEEF_CAFE_BABE) $fatal(1, "rd1=%h", rd1);
    if (rd2 !== 64'hDEAD_BEEF_CAFE_BABE) $fatal(1, "rd2=%h", rd2);
    if (rd3 !== 64'hDEAD_BEEF_CAFE_BABE) $fatal(1, "rd3=%h", rd3);

    // Write-then-same-cycle-read does NOT forward in this regfile
    // (FP regfile has no internal bypass — the dispatch scoreboard + EX bypass
    // net handles this.)
    @(negedge clk) we = 1; wa = 7; wd = 64'h0000_0000_0000_0001; ra1 = 7;
    @(posedge clk) #1;
    if (rd1 === 64'h0000_0000_0000_0001) $fatal(1,
      "FP regfile unexpectedly internally forwarded");

    // Next cycle the new value is visible
    @(negedge clk) we = 0;
    @(posedge clk) #1;
    if (rd1 !== 64'h0000_0000_0000_0001) $fatal(1, "post-write read=%h", rd1);

    // f0 is NOT hardwired to zero in the FP regfile (unlike integer x0).
    @(negedge clk) we = 1; wa = 0; wd = 64'hFFFF_0000_FFFF_0000; ra1 = 0;
    @(negedge clk) we = 0;
    @(posedge clk) #1;
    if (rd1 !== 64'hFFFF_0000_FFFF_0000)
      $fatal(1, "f0 should be writable: %h", rd1);

    $display("tb_regfile_fp PASS");
    $finish;
  end
endmodule
