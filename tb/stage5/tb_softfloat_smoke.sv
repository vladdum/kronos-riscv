// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_softfloat_smoke;
  import softfloat_dpi_pkg::*;
  initial begin
    automatic int unsigned r;
    sf_reset();
    // 1.0f + 1.0f = 2.0f
    r = sf_f32_add(32'h3F80_0000, 32'h3F80_0000, 8'd0);
    if (r !== 32'h4000_0000) $fatal(1, "f32_add failed: %h", r);
    $display("softfloat smoke ok: 1.0+1.0=%h flags=%0d", r, sf_exceptions());
    $finish;
  end
endmodule
