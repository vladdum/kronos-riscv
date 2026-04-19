// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPGA top-level wrapper for kronos_top on Kria KV260 (XCK26 UltraScale+).
//
// Clock:  Zynq PS pl_clk0 → BUFG  (frequency configured in synth.tcl via PS IP)
// Reset:  Zynq PS pl_resetn0 → 3-FF synchronizer → rst_ni
// Fan:    fan_en_b tied low (always-on, prevents thermal shutdown)
//
// AXI tie-off:  All AXI response inputs are driven from a registered loopback
// of the corresponding request outputs.  The XOR-feedback on the valid bits
// prevents Vivado from constant-propagating rvalid/b_valid to zero and trimming
// the IFU/LSU state machines during synthesis.  KEEP_HIERARCHY on u_core
// prevents cross-boundary constant propagation.

module kronos_kv260_top
  import kronos_pkg::*;
(
  output logic       fan_en_b,
  output logic [3:0] led,
  output logic       uart_tx,
  input  logic       uart_rx
);

  // -------------------------------------------------------------------------
  // Zynq UltraScale+ PS block — provides pl_clk0 and pl_resetn0
  // -------------------------------------------------------------------------
  logic pl_clk0_raw;
  logic pl_rst_n_raw;

  zynq_ultra_ps_e_0 ps_i (
    .pl_clk0    (pl_clk0_raw),
    .pl_resetn0 (pl_rst_n_raw)
  );

  // -------------------------------------------------------------------------
  // Clock: buffer PL clock through BUFG
  // -------------------------------------------------------------------------
  logic clk_i;

  BUFG clk_buf_i (
    .I (pl_clk0_raw),
    .O (clk_i)
  );

  // -------------------------------------------------------------------------
  // Reset: async assert, synchronous deassertion (3-FF synchronizer)
  // -------------------------------------------------------------------------
  logic [2:0] rst_sync_q;
  logic       rst_ni;

  always_ff @(posedge clk_i or negedge pl_rst_n_raw) begin
    if (!pl_rst_n_raw) rst_sync_q <= 3'b000;
    else               rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end
  assign rst_ni = rst_sync_q[2];

  // -------------------------------------------------------------------------
  // AXI interfaces
  // -------------------------------------------------------------------------
  kronos_axi_req_t  instr_req, data_req;
  kronos_axi_resp_t instr_rsp, data_rsp;

  // Registered loopback — keeps IFU and LSU state machines live in synthesis.
  //
  // r.data is set to the fetch/load address so that the instruction stream is
  // non-constant from Vivado's perspective.  Without this, constant-propagation
  // would see rdata=0 everywhere and eliminate the entire register file and ALU.
  //
  // XOR-feedback on valid bits makes rvalid/b_valid non-constant so the IFU and
  // LSU state machines remain reachable from multiple states.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_rsp <= '0;
      data_rsp  <= '0;
    end else begin
      instr_rsp.ar_ready <= instr_req.ar_valid;
      instr_rsp.r_valid  <= instr_req.ar_valid ^ instr_rsp.r_valid;
      instr_rsp.r.data   <= instr_req.ar.addr;  // instruction word = fetch addr (non-constant)
      instr_rsp.r.last   <= 1'b1;

      data_rsp.ar_ready  <= data_req.ar_valid;
      data_rsp.r_valid   <= data_req.ar_valid ^ data_rsp.r_valid;
      data_rsp.r.data    <= data_req.ar.addr;   // load word = load addr (non-constant)
      data_rsp.r.last    <= 1'b1;
      data_rsp.aw_ready  <= data_req.aw_valid;
      data_rsp.w_ready   <= data_req.w_valid;
      data_rsp.b_valid   <= data_req.aw_valid ^ data_rsp.b_valid;
    end
  end

  // -------------------------------------------------------------------------
  // kronos_top instance
  // Attribute prevents Vivado from flattening across the module boundary and
  // constant-propagating the AXI loopback values into the CPU internals.
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
  // Board outputs — must depend on CPU signals so Vivado cannot eliminate the
  // CPU as dead code.  Led[3:0] tracks the low address bits of the last data
  // memory access; uart_tx reflects whether the CPU is issuing any AXI request.
  // These connections are for timing analysis only and carry no semantic meaning.
  // -------------------------------------------------------------------------
  assign fan_en_b = 1'b0;
  assign led      = data_req.ar.addr[3:0];
  assign uart_tx  = instr_req.ar_valid | data_req.ar_valid;

  // uart_rx unused in this timing harness
  logic unused_uart_rx;
  assign unused_uart_rx = uart_rx;

endmodule
