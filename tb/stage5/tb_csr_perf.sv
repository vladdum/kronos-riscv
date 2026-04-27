// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Unit testbench for performance counters in kronos_csr (Stage 5c).
// Drives the CSR module standalone and verifies Zicntr + partial Zihpm
// behavior: register read/write, mcountinhibit gating, programmable
// event-mux increment, and SW-write-vs-event precedence.
module tb_csr_perf;
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
  logic [4:0]  fflags_delta = '0;
  logic        fflags_we = 0;
  logic [2:0]  frm;
  logic        irq_timer = 0;
  logic [14:0] irq_fast = '0;
  logic        irq_pending;
  logic        instret_retire = 0;
  logic [31:0] event_bus = '0;

  kronos_csr u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .addr_i(addr), .funct3_i(funct3), .use_imm_i(use_imm),
    .rs1_data_i(rs1_data), .rs1_addr_i(rs1_addr),
    .rdata_o(rdata), .valid_o(valid),
    .trap_i(trap), .trap_pc_i(trap_pc), .trap_cause_i(trap_cause),
    .mret_i(mret), .trap_vector_o(trap_vector), .mepc_o(mepc_out),
    .irq_timer_i(irq_timer), .irq_fast_i(irq_fast), .irq_pending_o(irq_pending),
    .fflags_delta_i(fflags_delta), .fflags_we_i(fflags_we),
    .fp_rd_we_i(1'b0),
    .instret_retire_i(instret_retire),
    .event_bus_i(event_bus),
    // Stage 5h Sdtrig hand-off — not exercised here; inputs zero, outputs unconnected.
    .trig_csr_rdata_i('0),
    .trig_csr_match_i(1'b0),
    .trig_csr_we_o(),
    .trig_csr_wdata_o(),
    .frm_o(frm)
  );

  always #5 clk = ~clk;

  // CSRRW (write rs1_data to addr)
  task automatic csrrw(input logic [11:0] a, input logic [63:0] d);
    @(negedge clk); req = 1; addr = a; funct3 = 3'b001; use_imm = 0; rs1_data = d;
    @(negedge clk); req = 0;
  endtask

  // CSRRSI rs1=0 (pure read)
  task automatic csrread(input logic [11:0] a, output logic [63:0] d);
    @(negedge clk); req = 1; addr = a; funct3 = 3'b010; use_imm = 1; rs1_addr = 0;
    @(posedge clk) #1; d = rdata;
    @(negedge clk) req = 0;
  endtask

  logic [63:0] v;
  initial begin
    req = 0; addr = 0; funct3 = 0; use_imm = 0; rs1_data = 0; rs1_addr = 0;
    #12 rst_n = 1;

    // Smoke check: misa is readable.
    csrread(12'h301, v);
    if (v[63:62] !== 2'b10) $fatal(1, "tb_csr_perf: misa MXL: %h", v);

    // ---- Test: SW writes to new CSRs are observable ----

    // mcountinhibit (0x320): write 0x7FF, read back 0x7FF (only bits [10:0]).
    csrrw(12'h320, 64'h0000_0000_0000_07FF);
    csrread(12'h320, v);
    if (v[10:0] !== 11'h7FF || v[63:11] !== 53'b0)
      $fatal(1, "mcountinhibit: %h", v);

    // mhpmevent3..10: write distinct event IDs, read back.
    csrrw(12'h323, 64'd3);
    csrrw(12'h324, 64'd4);
    csrrw(12'h325, 64'd5);
    csrrw(12'h326, 64'd6);
    csrrw(12'h327, 64'd7);
    csrrw(12'h328, 64'd8);
    csrrw(12'h329, 64'd9);
    csrrw(12'h32A, 64'd10);
    csrread(12'h323, v); if (v[7:0] !== 8'd3)  $fatal(1, "mhpmevent3: %h", v);
    csrread(12'h324, v); if (v[7:0] !== 8'd4)  $fatal(1, "mhpmevent4: %h", v);
    csrread(12'h325, v); if (v[7:0] !== 8'd5)  $fatal(1, "mhpmevent5: %h", v);
    csrread(12'h326, v); if (v[7:0] !== 8'd6)  $fatal(1, "mhpmevent6: %h", v);
    csrread(12'h327, v); if (v[7:0] !== 8'd7)  $fatal(1, "mhpmevent7: %h", v);
    csrread(12'h328, v); if (v[7:0] !== 8'd8)  $fatal(1, "mhpmevent8: %h", v);
    csrread(12'h329, v); if (v[7:0] !== 8'd9)  $fatal(1, "mhpmevent9: %h", v);
    csrread(12'h32A, v); if (v[7:0] !== 8'd10) $fatal(1, "mhpmevent10: %h", v);

    // mhpmcounter3..10: write distinct values, read back.
    csrrw(12'hB03, 64'hAAAA_AAAA_0000_0003);
    csrrw(12'hB04, 64'hAAAA_AAAA_0000_0004);
    csrrw(12'hB0A, 64'hAAAA_AAAA_0000_000A);
    csrread(12'hB03, v); if (v !== 64'hAAAA_AAAA_0000_0003) $fatal(1, "mhpmcounter3 RW: %h", v);
    csrread(12'hB04, v); if (v !== 64'hAAAA_AAAA_0000_0004) $fatal(1, "mhpmcounter4 RW: %h", v);
    csrread(12'hB0A, v); if (v !== 64'hAAAA_AAAA_0000_000A) $fatal(1, "mhpmcounter10 RW: %h", v);
    // U-mode alias mirrors the M-mode storage.
    csrread(12'hC0A, v); if (v !== 64'hAAAA_AAAA_0000_000A) $fatal(1, "hpmcounter10 alias: %h", v);

    // mcycle / minstret are M-mode writable (Zicntr).
    csrrw(12'hB00, 64'h0);
    csrread(12'hB00, v);
    if (v >= 64'd100) $fatal(1, "mcycle SW-write didn't take effect: %h", v);

    csrrw(12'hB02, 64'h0);
    csrread(12'hB02, v);
    if (v !== 64'h0) $fatal(1, "minstret SW-write didn't take effect: %h", v);

    // ---- Test: event-mux + counter increment ----

    // Configure: mhpmcounter3 counts event ID 0x05.
    csrrw(12'h323, 64'h05);                       // mhpmevent3 = 5
    csrrw(12'hB03, 64'h0);                        // mhpmcounter3 = 0
    csrrw(12'h320, 64'h0);                        // mcountinhibit = 0 (all running)

    // Pulse event_bus[5] high for 4 negedges; counter should increment 4 times.
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); event_bus = 32'h0020;       // bit 5
    end
    @(negedge clk); event_bus = 32'h0;
    csrread(12'hB03, v);
    if (v !== 64'd4) $fatal(1, "mhpmcounter3 expected 4, got %h", v);

    // ---- Test: mhpmcounterX does NOT increment when its event ID is unselected ----
    csrrw(12'hB04, 64'h0);
    csrrw(12'h324, 64'h08);                       // mhpmevent4 = 8 (unselected by bus)
    @(negedge clk); event_bus = 32'h0020;
    @(negedge clk); event_bus = 32'h0;
    csrread(12'hB04, v);
    if (v !== 64'd0) $fatal(1, "mhpmcounter4 should not have ticked: %h", v);

    // ---- Test: mcountinhibit gates increment ----
    csrrw(12'h320, 64'h7FF);                      // inhibit ALL counters
    csrread(12'hB03, v);
    begin
      static logic [63:0] before_v = '0;
      before_v = v;
      for (int i = 0; i < 8; i++) begin
        @(negedge clk); event_bus = 32'h0020;
      end
      @(negedge clk); event_bus = 32'h0;
      csrread(12'hB03, v);
      if (v !== before_v) $fatal(1, "mcountinhibit failed to freeze: %h vs %h", v, before_v);
    end
    csrrw(12'h320, 64'h0);

    // ---- Test: SW-write-wins-on-same-cycle precedence ----
    // Set event_bus and req=1 on the same negedge so they hit the same posedge.
    csrrw(12'hB03, 64'h0);
    @(negedge clk);
    event_bus = 32'h0020;                         // bit 5 asserted
    req = 1; addr = 12'hB03; funct3 = 3'b001; use_imm = 0;
    rs1_data = 64'hDEAD_BEEF_DEAD_BEEF;           // CSRRW: write DEAD_BEEF...
    @(negedge clk); req = 0; event_bus = 32'h0;
    csrread(12'hB03, v);
    if (v !== 64'hDEAD_BEEF_DEAD_BEEF)
      $fatal(1, "SW write should win, got %h", v);

    // ---- Test: out-of-range event ID does not increment ----
    csrrw(12'h325, 64'h10);                       // mhpmevent5 = 0x10 (>= 16)
    csrrw(12'hB05, 64'h0);
    @(negedge clk); event_bus = 32'hFFFF;
    @(negedge clk); event_bus = 32'h0;
    csrread(12'hB05, v);
    if (v !== 64'd0) $fatal(1, "out-of-range event ID should be inert: %h", v);

    // ---- Test: mcycle stops when mcountinhibit[0] set ----
    csrrw(12'h320, 64'h001);                      // inhibit only mcycle
    csrread(12'hB00, v);
    begin
      static logic [63:0] before_v = '0;
      before_v = v;
      repeat (5) @(posedge clk);
      csrread(12'hB00, v);
      if (v !== before_v)
        $fatal(1, "mcycle should be frozen by mcountinhibit[0]: %h vs %h", v, before_v);
    end
    csrrw(12'h320, 64'h0);

    // ---- Test: minstret ticks only when instret_retire fires and bit 2 clear ----
    csrrw(12'hB02, 64'h0);                        // minstret = 0
    @(negedge clk); instret_retire = 1;
    @(negedge clk); instret_retire = 0;
    @(negedge clk); instret_retire = 1;
    @(negedge clk); instret_retire = 0;
    csrread(12'hB02, v);
    if (v !== 64'd2) $fatal(1, "minstret expected 2, got %h", v);

    // ---- Test: CSR access to an UNRELATED address must not suppress counter tick ----
    csrrw(12'h323, 64'h05);                       // mhpmevent3 = 5
    csrrw(12'hB03, 64'h0);                        // mhpmcounter3 = 0
    csrrw(12'h320, 64'h0);                        // mcountinhibit = 0
    // Drive event_bus[5] high while doing a CSR read of mstatus (unrelated addr).
    @(negedge clk); event_bus = 32'h0020; req = 1; addr = 12'h300;
                    funct3 = 3'b010; use_imm = 1; rs1_addr = 0;
    @(negedge clk); event_bus = 32'h0; req = 0;
    csrread(12'hB03, v);
    if (v === 64'd0)
      $fatal(1, "unrelated CSR access suppressed counter tick: %h", v);

    // ---- Test: CSRRC clears bits ----
    // Use mscratch (a plain RW CSR) to avoid side-effects.
    csrrw(12'h340, 64'hFFFF_FFFF_FFFF_FFFF);      // mscratch = all ones
    @(negedge clk); req = 1; addr = 12'h340; funct3 = 3'b011; use_imm = 0;
                    rs1_data = 64'h0000_0000_FFFF_FFFF;
    @(negedge clk); req = 0;
    csrread(12'h340, v);
    if (v !== 64'hFFFF_FFFF_0000_0000) $fatal(1, "CSRRC mscratch: %h", v);

    // ---- Test: trap_i body executes ----
    // Drive trap with a known PC and cause; verify mepc/mcause/mstatus updates.
    csrrw(12'h300, 64'h0000_0000_0000_3888);      // mstatus: MIE=1, MPP=11, FS=01
    @(negedge clk); trap = 1; trap_pc = 32'h0000_1000; trap_cause = 32'd2;
    @(negedge clk); trap = 0;
    csrread(12'h341, v);
    if (v !== 64'h0000_0000_0000_1000) $fatal(1, "trap mepc: %h", v);
    csrread(12'h342, v);
    if (v[31:0] !== 32'd2) $fatal(1, "trap mcause: %h", v);
    csrread(12'h300, v);
    if (v[3] !== 1'b0) $fatal(1, "trap mstatus.MIE not cleared: %h", v);
    if (v[7] !== 1'b1) $fatal(1, "trap mstatus.MPIE not set from MIE: %h", v);

    // ---- Test: mret_i body restores interrupt state ----
    @(negedge clk); mret = 1;
    @(negedge clk); mret = 0;
    csrread(12'h300, v);
    if (v[3] !== 1'b1) $fatal(1, "mret mstatus.MIE not restored: %h", v);
    if (v[7] !== 1'b1) $fatal(1, "mret mstatus.MPIE not set: %h", v);

    // ---- Test: read all M-mode CSRs (covers read decoder branches) ----
    csrread(12'h304, v);                          // mie
    csrread(12'h305, v);                          // mtvec
    csrread(12'h344, v);                          // mip
    csrread(12'hC01, v);                          // time alias

    // ---- Test: write all M-mode CSRs (covers write decoder branches) ----
    csrrw(12'h001, 64'h0);                        // FFLAGS — also marks FS Dirty
    csrrw(12'h002, 64'h0);                        // FRM — also marks FS Dirty
    csrrw(12'h003, 64'h0);                        // FCSR — also marks FS Dirty
    csrrw(12'h300, 64'h0000_0000_0000_3888);      // mstatus
    csrrw(12'h304, 64'hDEAD_BEEF_DEAD_BEEF);      // mie
    csrrw(12'h305, 64'hCAFE_BABE_CAFE_BABE);      // mtvec
    csrrw(12'h340, 64'hAA);                       // mscratch
    csrrw(12'h341, 64'hBB);                       // mepc
    csrrw(12'h342, 64'hCC);                       // mcause

    // ---- Test: read mhpmcounter6,7,8,9 (covers remaining counter slots) ----
    csrread(12'hB06, v);
    csrread(12'hB07, v);
    csrread(12'hB08, v);
    csrread(12'hB09, v);

    // ---- Test: write mhpmcounter6,7,8,9 ----
    csrrw(12'hB06, 64'h6);
    csrrw(12'hB07, 64'h7);
    csrrw(12'hB08, 64'h8);
    csrrw(12'hB09, 64'h9);
    csrread(12'hB06, v); if (v !== 64'h6) $fatal(1, "mhpmcounter6 RW: %h", v);
    csrread(12'hB07, v); if (v !== 64'h7) $fatal(1, "mhpmcounter7 RW: %h", v);
    csrread(12'hB08, v); if (v !== 64'h8) $fatal(1, "mhpmcounter8 RW: %h", v);
    csrread(12'hB09, v); if (v !== 64'h9) $fatal(1, "mhpmcounter9 RW: %h", v);

    $display("tb_csr_perf PASS");
    $finish;
  end
endmodule
