// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_hardfloat_smoke;
  logic [32:0] rec;      // 33-bit recoded single
  logic [31:0] fp;

  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_f2rec (
    .in(32'h3F80_0000),  // 1.0f
    .out(rec)
  );
  recFNToFN #(.expWidth(8), .sigWidth(24)) u_rec2f (
    .in(rec),
    .out(fp)
  );

  initial begin
    #1;
    if (fp !== 32'h3F80_0000) $fatal(1, "round-trip failed: %h", fp);
    $display("hardfloat smoke ok: 1.0 round-trip = %h", fp);
    $finish;
  end
endmodule
