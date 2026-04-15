// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module tb_fpu_scoreboard;
  logic       clk = 0, rst_n = 0, flush = 0;
  logic       dispatch_req, dispatch_fp, dispatch_int;
  logic [2:0] dispatch_latency;  // 1..5
  logic       dispatch_ok;

  logic dispatch_ok_comb;

  kronos_fpu_scoreboard u_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .req_i(dispatch_req), .fp_dest_i(dispatch_fp), .int_dest_i(dispatch_int),
    .latency_i(dispatch_latency), .grant_comb_o(dispatch_ok_comb), .grant_o(dispatch_ok)
  );
  always #5 clk = ~clk;

  task automatic dispatch(input logic fp, input logic intw, input int lat,
                          input bit expect_ok);
    @(negedge clk) dispatch_req = 1; dispatch_fp = fp; dispatch_int = intw;
                   dispatch_latency = lat[2:0];
    @(posedge clk) #1;
    if (dispatch_ok !== expect_ok)
      $fatal(1, "lat=%0d fp=%b int=%b expect=%b got=%b",
             lat, fp, intw, expect_ok, dispatch_ok);
    @(negedge clk) dispatch_req = 0;
  endtask

  initial begin
    dispatch_req = 0; dispatch_fp = 0; dispatch_int = 0; dispatch_latency = 0;
    #12 rst_n = 1;

    // FMA (lat=5) then FCVT (lat=2): writeback cycles 5 and 2 — no collision.
    dispatch(1, 0, 5, 1'b1);
    dispatch(1, 0, 2, 1'b1);
    // Another FMA (lat=5) now: its WB is 5 cycles from now.
    // First FMA already shifted; no collision. Expect grant.
    dispatch(1, 0, 5, 1'b1);
    // FMISC (lat=1): wb next cycle. That slot should be free.
    dispatch(1, 0, 1, 1'b1);

    // Force a collision: reset, dispatch FCVT (lat=2), one cycle later
    // FMISC (lat=1) — both land at T+2. Second must be denied.
    @(negedge clk) rst_n = 0; @(negedge clk) rst_n = 1;
    dispatch(1, 0, 2, 1'b1);
    dispatch(1, 0, 1, 1'b0);

    // Flush clears the reservation vector.
    @(negedge clk) flush = 1; @(negedge clk) flush = 0;
    dispatch(1, 0, 1, 1'b1);

    $display("tb_fpu_scoreboard PASS");
    $finish;
  end
endmodule
