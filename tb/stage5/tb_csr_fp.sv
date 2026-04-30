// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_csr_fp;
  import kronos_pkg::*;

  logic        clk = 0;
  logic        rst_n = 0;
  logic        req;
  logic [11:0] addr;
  logic [2:0]  funct3;
  logic        use_imm;
  logic [63:0] rs1_data;
  logic [4:0]  rs1_addr;
  logic [63:0] rdata;
  logic        valid;
  logic        trap = 0, mret = 0;
  logic [31:0] trap_pc = 0, trap_cause = 0;
  logic [63:0] trap_vector, mepc_out;
  logic [4:0]  fflags_delta = 5'h0;
  logic        fflags_we = 0;
  logic [2:0]  frm;
  logic        irq_timer = 0;
  logic [14:0] irq_fast = 15'h0;
  logic        irq_pending;

  kronos_csr u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .addr_i(addr), .funct3_i(funct3), .use_imm_i(use_imm),
    .rs1_data_i(rs1_data), .rs1_addr_i(rs1_addr),
    .rdata_o(rdata), .valid_o(valid),
    .trap_i(trap), .trap_pc_i(trap_pc), .trap_cause_i(trap_cause),
    .mret_i(mret), .trap_vector_o(trap_vector), .mepc_o(mepc_out),
    .irq_timer_i(irq_timer), .irq_fast_i(irq_fast), .irq_pending_o(irq_pending),
    // New FP interface
    .fflags_delta_i(fflags_delta), .fflags_we_i(fflags_we),
    .fp_rd_we_i(1'b0),
    .instret_retire_i(1'b0),
    .event_bus_i('0),
    // Stage 5h Sdtrig hand-off — not exercised here; inputs zero, outputs unconnected.
    .trig_csr_rdata_i('0),
    .trig_csr_match_i(1'b0),
    .trig_csr_we_o(),
    .csr_new_val_o(),
    .trig_csr_wdata_o(),
    .frm_o(frm)
  );

  always #5 clk = ~clk;

  task automatic csrrw(input logic [11:0] a, input logic [63:0] d);
    @(negedge clk); req = 1; addr = a; funct3 = 3'b001; use_imm = 0; rs1_data = d;
    @(negedge clk); req = 0;
  endtask

  task automatic csrread(input logic [11:0] a, output logic [63:0] d);
    @(negedge clk); req = 1; addr = a; funct3 = 3'b010; use_imm = 1; rs1_addr = 0;
    @(posedge clk) #1; d = rdata;
    @(negedge clk) req = 0;
  endtask

  logic [63:0] v;
  initial begin
    req = 0; addr = 0; funct3 = 0; use_imm = 0; rs1_data = 0; rs1_addr = 0;
    #12 rst_n = 1;

    // misa.F and misa.D must both be set
    csrread(12'h301, v);
    if (!v[5] || !v[3]) $fatal(1, "misa.F|.D not set: %h", v);

    // Write FRM, read FRM, read FCSR
    csrrw(12'h002, 64'h0000_0000_0000_0003); // rup
    csrread(12'h002, v);
    if (v[2:0] !== 3'b011) $fatal(1, "FRM write/read: %h", v);
    csrread(12'h003, v);
    if (v[7:5] !== 3'b011) $fatal(1, "FCSR.frm: %h", v);

    // Write FFLAGS directly via CSR
    csrrw(12'h001, 64'h0000_0000_0000_0005); // NV | NX
    csrread(12'h001, v);
    if (v[4:0] !== 5'b00101) $fatal(1, "FFLAGS write/read: %h", v);

    // FPU writeback sticky-OR: existing 00101 | 10010 = 10111
    @(negedge clk) fflags_delta = 5'b10010; fflags_we = 1;
    @(negedge clk) fflags_we = 0;
    csrread(12'h001, v);
    if (v[4:0] !== 5'b10111) $fatal(1, "FFLAGS sticky: %h", v);

    // frm_o port mirrors FRM field (live, not only on read)
    if (frm !== 3'b011) $fatal(1, "frm_o: %0d", frm);

    // mstatus.FS storage: write 11, read back 11 — no gating
    csrrw(12'h300, 64'h0000_0000_0000_6000); // FS=11, rest zero
    csrread(12'h300, v);
    if (v[14:13] !== 2'b11) $fatal(1, "mstatus.FS storage: %h", v);

    $display("tb_csr_fp PASS");
    $finish;
  end
endmodule
