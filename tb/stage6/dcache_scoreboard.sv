// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// dcache_scoreboard — pure architectural-memory mirror.
// Tracks every retired byte-write the testbench drives into the dcache and
// returns the expected load value for any address. Knows nothing about
// cache state (tags, lines, MESI) — only architectural memory contents.

module dcache_scoreboard #(
  parameter int unsigned MEM_BYTES = 1 << 16,
  parameter int unsigned MEM_BASE  = 32'h0
)(
  input logic clk_i,
  input logic rst_ni
);

  logic [7:0] mem [MEM_BYTES];

  task automatic store(input [63:0] addr, input [2:0] sz, input [63:0] data);
    int n;
    int idx;
    n = 1 << sz;
    for (int i = 0; i < n; i++) begin
      idx = int'(addr) - MEM_BASE + i;
      if (idx >= 0 && idx < MEM_BYTES) mem[idx] = data[i*8 +: 8];
    end
  endtask

  function automatic [63:0] expected(input [63:0] addr, input [2:0] sz);
    logic [63:0] v;
    int n;
    int idx;
    v = 64'h0;
    n = 1 << sz;
    for (int i = 0; i < n; i++) begin
      idx = int'(addr) - MEM_BASE + i;
      if (idx >= 0 && idx < MEM_BYTES) v[i*8 +: 8] = mem[idx];
    end
    return v;
  endfunction

  initial begin
    foreach (mem[i]) mem[i] = 8'h00;
  end

endmodule
