// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// CPU-only synthesis wrapper for timing closure analysis.
// No Zynq PS IP — clock and reset come directly from top-level ports.
// The BUFG and reset synchronizer are retained so the timing environment
// matches the real KV260 implementation.
//
// AXI tie-off: identical registered loopback to kronos_kv260_top, keeping
// the IFU/LSU state machines and the register file live during synthesis.
// KEEP_HIERARCHY on u_core prevents cross-boundary constant propagation.

module kronos_cpu_synth_top
  import kronos_pkg::*;
(
  input  logic       clk_raw_i,   // raw clock input (constrained in XDC)
  input  logic       rst_raw_ni,  // raw active-low reset
  output logic [3:0] led_o,       // driven by CPU data-bus address bits
  output logic       active_o     // driven by CPU AXI request valid bits
);

  // -------------------------------------------------------------------------
  // Clock: BUFG (matches real implementation)
  // -------------------------------------------------------------------------
  logic clk_i;

  BUFG clk_buf_i (
    .I (clk_raw_i),
    .O (clk_i)
  );

  // -------------------------------------------------------------------------
  // Reset: async assert, synchronous deassertion (3-FF synchronizer)
  // -------------------------------------------------------------------------
  logic [2:0] rst_sync_q;
  logic       rst_ni;

  always_ff @(posedge clk_i or negedge rst_raw_ni) begin
    if (!rst_raw_ni) rst_sync_q <= 3'b000;
    else             rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end
  assign rst_ni = rst_sync_q[2];

  // -------------------------------------------------------------------------
  // AXI interfaces
  // -------------------------------------------------------------------------
  kronos_axi_req_t  instr_req, data_req;
  kronos_axi_resp_t instr_rsp, data_rsp;

  // Registered loopback — keeps IFU and LSU state machines live in synthesis.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_rsp <= '0;
      data_rsp  <= '0;
    end else begin
      instr_rsp.ar_ready <= instr_req.ar_valid;
      instr_rsp.r_valid  <= instr_req.ar_valid ^ instr_rsp.r_valid;
      instr_rsp.r.data   <= instr_req.ar.addr;
      instr_rsp.r.last   <= 1'b1;

      data_rsp.ar_ready  <= data_req.ar_valid;
      data_rsp.r_valid   <= data_req.ar_valid ^ data_rsp.r_valid;
      data_rsp.r.data    <= data_req.ar.addr;
      data_rsp.r.last    <= 1'b1;
      data_rsp.aw_ready  <= data_req.aw_valid;
      data_rsp.w_ready   <= data_req.w_valid;
      data_rsp.b_valid   <= data_req.aw_valid ^ data_rsp.b_valid;
    end
  end

  // -------------------------------------------------------------------------
  // kronos_top instance
  // -------------------------------------------------------------------------
  (* KEEP_HIERARCHY = "yes" *)
  kronos_top u_core (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .instr_axi_req_o (instr_req),
    .instr_axi_rsp_i (instr_rsp),
    .data_axi_req_o  (data_req),
    .data_axi_rsp_i  (data_rsp),
    .irq_timer_i     ('0),
    .irq_fast_i      ('0),
    .boot_addr_i     (32'h0000_0000)
  );

  // -------------------------------------------------------------------------
  // Outputs — must depend on CPU signals to prevent dead-code elimination.
  // -------------------------------------------------------------------------
  assign led_o    = data_req.ar.addr[3:0];
  assign active_o = instr_req.ar_valid | data_req.ar_valid;

endmodule
