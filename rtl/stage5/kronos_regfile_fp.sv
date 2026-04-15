// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_regfile_fp — 3R1W, 32 × 64-bit FP register file.
// - f0 is NOT hardwired to zero (unlike integer x0).
// - Read ports are asynchronous (combinatorial), matching the integer regfile.
//   Read-before-write: a write and read of the same address in the same cycle
//   returns the old value; the EX-bypass network handles this case.
module kronos_regfile_fp (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [4:0]  ra1_i,
  output logic [63:0] rd1_o,
  input  logic [4:0]  ra2_i,
  output logic [63:0] rd2_o,
  input  logic [4:0]  ra3_i,
  output logic [63:0] rd3_o,
  input  logic [4:0]  wa_i,
  input  logic [63:0] wd_i,
  input  logic        we_i
);
  logic [63:0] rf [32];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 32; i++) rf[i] <= '0;
    end else begin
      if (we_i) rf[wa_i] <= wd_i;
    end
  end

  assign rd1_o = rf[ra1_i];
  assign rd2_o = rf[ra2_i];
  assign rd3_o = rf[ra3_i];

endmodule
