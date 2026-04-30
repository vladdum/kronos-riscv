// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

// Stage 6a unit testbench for kronos_csr — privilege & supervisor extensions.
// Drives the CSR module standalone and verifies:
//   1.  Reset state (priv=M, mstatus=0x1800, pmpcfg0=0)
//   2.  sstatus<->mstatus mirror (SUM bit)
//   3.  medeleg WARL: bit 11 hardwired 0
//   4.  mideleg WARL: only bits {1, 5, 9} writable
//   5.  pmpcfg.A=01 collapse to A=00
//   6.  pmpcfg L=1 lock prevents subsequent updates
//   7.  mret transition (M -> S via MPP)
//   8.  sret transition (S -> U via SPP)
//   9.  counter-enable U gate (mcounteren/scounteren on 0xC00)
//   10. CSR access privilege check (U attempting M-mode CSR)
module tb_priv_csr;
  import kronos_pkg::*;

  // ------------------------------------------------------------------------
  // Local CSR address constants (not exposed in kronos_pkg)
  // ------------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS = 12'h300;
  localparam logic [11:0] CSR_CYCLE   = 12'hC00;

  // Mask of bits we expect to remain set after writing all-ones to mideleg.
  localparam logic [XLEN-1:0] MIDELEG_MASK = 64'h0000_0000_0000_0222;
  // Mask of bits expected to remain after writing all-ones to medeleg.
  localparam logic [XLEN-1:0] MEDELEG_MASK = 64'h0000_0000_0000_B7FF;

  // ------------------------------------------------------------------------
  // Clock / reset
  // ------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------------
  // DUT inputs
  // ------------------------------------------------------------------------
  logic            req_i;
  logic [11:0]     addr_i;
  logic [2:0]      funct3_i;
  logic            use_imm_i;
  logic [XLEN-1:0] rs1_data_i;
  logic [4:0]      rs1_addr_i;
  logic            trap_i;
  logic [31:0]     trap_pc_i;
  logic [31:0]     trap_cause_i;
  logic [31:0]     trap_tval_i;
  logic            mret_i;
  logic            sret_i;
  logic            irq_timer_i;
  logic [14:0]     irq_fast_i;
  logic            irq_msi_i;
  logic            irq_mei_i;
  logic            irq_ssi_i;
  logic            irq_sti_i;
  logic            irq_sei_i;
  logic [4:0]      fflags_delta_i;
  logic            fflags_we_i;
  logic            fp_rd_we_i;
  logic            instret_retire_i;
  logic [31:0]     event_bus_i;
  logic [XLEN-1:0] trig_csr_rdata_i;
  logic            trig_csr_match_i;

  // ------------------------------------------------------------------------
  // DUT outputs
  // ------------------------------------------------------------------------
  logic [XLEN-1:0]  rdata_o;
  logic             valid_o;
  logic [XLEN-1:0]  trap_vector_o;
  logic [XLEN-1:0]  mepc_o;
  logic [XLEN-1:0]  sepc_o;
  priv_e            priv_o;
  logic [XLEN-1:0]  mstatus_o;
  logic             irq_pending_o;
  logic [4:0]       irq_cause_o;
  logic [2:0]       frm_o;
  logic             trig_csr_we_o;
  logic [XLEN-1:0]  trig_csr_wdata_o;
  logic             csr_illegal_o;
  logic [7:0][7:0]  pmpcfg_o;
  logic [7:0][53:0] pmpaddr_o;

  // ------------------------------------------------------------------------
  // Stimulus state (mid-module declarations forbidden — declared up front)
  // ------------------------------------------------------------------------
  int              fail_count;
  logic [XLEN-1:0] v;
  logic            illegal;

  // ------------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------------
  kronos_csr u_dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .req_i(req_i),
    .addr_i(addr_i),
    .funct3_i(funct3_i),
    .use_imm_i(use_imm_i),
    .rs1_data_i(rs1_data_i),
    .rs1_addr_i(rs1_addr_i),
    .rdata_o(rdata_o),
    .valid_o(valid_o),
    .trap_i(trap_i),
    .trap_pc_i(trap_pc_i),
    .trap_cause_i(trap_cause_i),
    .trap_tval_i(trap_tval_i),
    .mret_i(mret_i),
    .sret_i(sret_i),
    .trap_vector_o(trap_vector_o),
    .mepc_o(mepc_o),
    .sepc_o(sepc_o),
    .priv_o(priv_o),
    .mstatus_o(mstatus_o),
    .irq_timer_i(irq_timer_i),
    .irq_fast_i(irq_fast_i),
    .irq_msi_i(irq_msi_i),
    .irq_mei_i(irq_mei_i),
    .irq_ssi_i(irq_ssi_i),
    .irq_sti_i(irq_sti_i),
    .irq_sei_i(irq_sei_i),
    .irq_pending_o(irq_pending_o),
    .irq_cause_o(irq_cause_o),
    .fflags_delta_i(fflags_delta_i),
    .fflags_we_i(fflags_we_i),
    .fp_rd_we_i(fp_rd_we_i),
    .frm_o(frm_o),
    .instret_retire_i(instret_retire_i),
    .event_bus_i(event_bus_i),
    .trig_csr_rdata_i(trig_csr_rdata_i),
    .trig_csr_match_i(trig_csr_match_i),
    .trig_csr_we_o(trig_csr_we_o),
    .trig_csr_wdata_o(trig_csr_wdata_o),
    // Stage 6c: post-write CSR value — unused in this TB (T3 wires it at top).
    .csr_new_val_o(),
    .csr_illegal_o(csr_illegal_o),
    .pmpcfg_o(pmpcfg_o),
    .pmpaddr_o(pmpaddr_o),
    // Stage 6b: SFENCE.VMA passthrough + satp fields.  Tied off / left
    // unconnected — this TB exercises CSR semantics, not translation.
    .sfence_vma_i        (1'b0),
    .sfence_va_i         (64'b0),
    .sfence_asid_i       (16'b0),
    .sfence_va_valid_i   (1'b0),
    .sfence_asid_valid_i (1'b0),
    .sfence_vma_o        (),
    .sfence_va_o         (),
    .sfence_asid_o       (),
    .sfence_va_valid_o   (),
    .sfence_asid_valid_o (),
    .satp_mode_o         (),
    .satp_asid_o         (),
    .satp_ppn_o          ()
  );

  // ------------------------------------------------------------------------
  // Helper tasks
  // ------------------------------------------------------------------------
  // CSRRW — write `v` to CSR `a` (rs1_addr=1 so write fires).
  task automatic csr_write(input logic [11:0] a, input logic [XLEN-1:0] v);
    @(posedge clk);
    addr_i     = a;
    funct3_i   = 3'b001;     // CSRRW
    use_imm_i  = 1'b0;
    rs1_data_i = v;
    rs1_addr_i = 5'd1;
    req_i      = 1'b1;
    @(posedge clk);
    req_i      = 1'b0;
  endtask

  // CSRRS rs1=x0 — read-only.  Returns rdata and same-cycle csr_illegal.
  task automatic csr_read(input  logic [11:0]     a,
                          output logic [XLEN-1:0] v,
                          output logic            illegal);
    @(posedge clk);
    addr_i     = a;
    funct3_i   = 3'b010;     // CSRRS
    use_imm_i  = 1'b0;
    rs1_data_i = 64'h0;
    rs1_addr_i = 5'd0;
    req_i      = 1'b1;
    // Sample combinational outputs after they have settled but before the
    // next posedge consumes the request.
    @(negedge clk);
    v       = rdata_o;
    illegal = csr_illegal_o;
    @(posedge clk);
    req_i   = 1'b0;
  endtask

  task automatic pulse_mret;
    @(posedge clk);
    mret_i = 1'b1;
    @(posedge clk);
    mret_i = 1'b0;
  endtask

  task automatic pulse_sret;
    @(posedge clk);
    sret_i = 1'b1;
    @(posedge clk);
    sret_i = 1'b0;
  endtask

  // Drop privilege to U via MPP=U + mret.  Caller must already be in M.
  task automatic drop_to_u;
    csr_write(CSR_MSTATUS, 64'h0000_0000_0000_0000);   // mstatus.MPP=00 (U)
    pulse_mret;
  endtask

  // Drop privilege to S via MPP=S + mret.
  task automatic drop_to_s;
    csr_write(CSR_MSTATUS, 64'h0000_0000_0000_0800);   // mstatus.MPP=01 (S)
    pulse_mret;
  endtask

  // ------------------------------------------------------------------------
  // Stimulus
  // ------------------------------------------------------------------------
  initial begin
    // Drive every input to a defined value before any clock edge.
    req_i            = 1'b0;
    addr_i           = 12'h0;
    funct3_i         = 3'b000;
    use_imm_i        = 1'b0;
    rs1_data_i       = 64'h0;
    rs1_addr_i       = 5'h0;
    trap_i           = 1'b0;
    trap_pc_i        = 32'h0;
    trap_cause_i     = 32'h0;
    trap_tval_i      = 32'h0;
    mret_i           = 1'b0;
    sret_i           = 1'b0;
    irq_timer_i      = 1'b0;
    irq_fast_i       = 15'h0;
    irq_msi_i        = 1'b0;
    irq_mei_i        = 1'b0;
    irq_ssi_i        = 1'b0;
    irq_sti_i        = 1'b0;
    irq_sei_i        = 1'b0;
    fflags_delta_i   = 5'h0;
    fflags_we_i      = 1'b0;
    fp_rd_we_i       = 1'b0;
    instret_retire_i = 1'b0;
    event_bus_i      = 32'h0;
    trig_csr_rdata_i = 64'h0;
    trig_csr_match_i = 1'b0;
    fail_count       = 0;

    // Reset for several cycles.
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ----------------------------------------------------------------------
    // Case 1: reset state
    // ----------------------------------------------------------------------
    if (priv_o !== PRIV_M) begin
      $display("FAIL case1: priv_o=%h expected PRIV_M", priv_o);
      fail_count++;
    end
    csr_read(CSR_MSTATUS, v, illegal);
    if (v !== 64'h0000_0000_0000_1800) begin
      $display("FAIL case1: mstatus reset=%h expected 0x1800", v);
      fail_count++;
    end
    csr_read(CSR_PMPCFG0, v, illegal);
    if (v !== 64'h0) begin
      $display("FAIL case1: pmpcfg0 reset=%h expected 0", v);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 2: sstatus mirror — SUM (bit 18)
    // ----------------------------------------------------------------------
    csr_write(CSR_SSTATUS, 64'h0000_0000_0004_0000);   // sstatus: bit 18
    csr_read (CSR_MSTATUS, v, illegal);
    if (v[18] !== 1'b1) begin
      $display("FAIL case2a: mstatus.SUM not set via sstatus write (mstatus=%h)", v);
      fail_count++;
    end
    csr_write(CSR_SSTATUS, 64'h0);                     // clear sstatus.SUM
    csr_read (CSR_MSTATUS, v, illegal);
    if (v[18] !== 1'b0) begin
      $display("FAIL case2b: mstatus.SUM not cleared via sstatus (mstatus=%h)", v);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 3: medeleg[11] is hardwired 0
    // ----------------------------------------------------------------------
    csr_write(CSR_MEDELEG, 64'hFFFF_FFFF_FFFF_FFFF);
    csr_read (CSR_MEDELEG, v, illegal);
    if (v[11] !== 1'b0) begin
      $display("FAIL case3: medeleg[11] readback=%h expected 0", v[11]);
      fail_count++;
    end
    if (v !== MEDELEG_MASK) begin
      $display("FAIL case3: medeleg readback=%h expected %h", v, MEDELEG_MASK);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 4: mideleg WARL — only bits {1, 5, 9} writable
    // ----------------------------------------------------------------------
    csr_write(CSR_MIDELEG, 64'hFFFF_FFFF_FFFF_FFFF);
    csr_read (CSR_MIDELEG, v, illegal);
    if (v !== MIDELEG_MASK) begin
      $display("FAIL case4: mideleg readback=%h expected %h", v, MIDELEG_MASK);
      fail_count++;
    end
    if (v[3] !== 1'b0) begin
      $display("FAIL case4: mideleg[3] should be 0 (got %h)", v);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 5: pmpcfg.A=01 (TOR) collapses to A=00 (OFF); A=11 (NAPOT) preserved
    // ----------------------------------------------------------------------
    // First write NAPOT (A=11) — must be preserved.
    csr_write(CSR_PMPCFG0, 64'h0000_0000_0000_0018);
    csr_read (CSR_PMPCFG0, v, illegal);
    if (v[7:0] !== 8'h18) begin
      $display("FAIL case5a: pmpcfg0[byte0] NAPOT readback=%h expected 0x18", v[7:0]);
      fail_count++;
    end
    // Now write TOR (A=01) — must collapse to OFF (A=00 → byte=0x00).
    csr_write(CSR_PMPCFG0, 64'h0000_0000_0000_0008);
    csr_read (CSR_PMPCFG0, v, illegal);
    if (v[7:0] !== 8'h00) begin
      $display("FAIL case5b: pmpcfg0[byte0] TOR collapse readback=%h expected 0x00", v[7:0]);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 6: pmpcfg lock — L=1 prevents subsequent writes to that byte
    // ----------------------------------------------------------------------
    csr_write(CSR_PMPCFG0, 64'h0000_0000_0000_0080);   // L=1
    csr_read (CSR_PMPCFG0, v, illegal);
    if (v[7:0] !== 8'h80) begin
      $display("FAIL case6a: pmpcfg0[byte0] lock-set readback=%h expected 0x80", v[7:0]);
      fail_count++;
    end
    csr_write(CSR_PMPCFG0, 64'h0000_0000_0000_0018);   // try NAPOT — locked!
    csr_read (CSR_PMPCFG0, v, illegal);
    if (v[7:0] !== 8'h80) begin
      $display("FAIL case6b: pmpcfg0[byte0] lock-honour readback=%h expected 0x80", v[7:0]);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 7: mret transition — MPP=S → priv=S, MPP cleared to U
    // ----------------------------------------------------------------------
    csr_write(CSR_MSTATUS, 64'h0000_0000_0000_0800);   // MPP = 01 (S)
    pulse_mret;
    if (priv_o !== PRIV_S) begin
      $display("FAIL case7: post-mret priv_o=%h expected PRIV_S", priv_o);
      fail_count++;
    end
    csr_read(CSR_MSTATUS, v, illegal);
    if (v[12:11] !== 2'b00) begin
      $display("FAIL case7: post-mret mstatus.MPP=%h expected 00", v[12:11]);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 8: sret transition — already in S; SPP=U → priv=U
    // ----------------------------------------------------------------------
    // sstatus mask exposes SPP (bit 8); writing 0 to sstatus clears SPP.
    csr_write(CSR_SSTATUS, 64'h0);                     // sstatus.SPP = 0
    pulse_sret;
    if (priv_o !== PRIV_U) begin
      $display("FAIL case8: post-sret priv_o=%h expected PRIV_U", priv_o);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 9: counter-enable U gate
    //
    // Sub-case 9a: mcounteren/scounteren = 0 → U-mode read of cycle traps.
    // Sub-case 9b: mcounteren/scounteren = 1 → U-mode read of cycle is legal.
    //
    // From U-mode we cannot rewrite mcounteren, so we issue a synchronous
    // reset between sub-cases to land back in M and reconfigure.
    // ----------------------------------------------------------------------
    // We are in U at this point.
    csr_read(CSR_CYCLE, v, illegal);                   // cycle (U-RO alias)
    if (illegal !== 1'b1) begin
      $display("FAIL case9a: U read of cycle with mcounteren=0 illegal=%b expected 1",
               illegal);
      fail_count++;
    end

    // Reset the DUT and reconfigure for sub-case 9b.
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    csr_write(CSR_MCOUNTEREN, 64'h0000_0000_0000_0001);   // mcounteren[0]=1
    csr_write(CSR_SCOUNTEREN, 64'h0000_0000_0000_0001);   // scounteren[0]=1
    drop_to_u;
    csr_read(CSR_CYCLE, v, illegal);
    if (illegal !== 1'b0) begin
      $display("FAIL case9b: U read of cycle with mcounteren=1,scounteren=1 illegal=%b expected 0",
               illegal);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Case 10: CSR access privilege check — U attempting to read mstatus
    // ----------------------------------------------------------------------
    // Still in U-mode from case 9b.
    csr_read(CSR_MSTATUS, v, illegal);                 // mstatus (M-mode CSR)
    if (illegal !== 1'b1) begin
      $display("FAIL case10: U read of mstatus illegal=%b expected 1", illegal);
      fail_count++;
    end

    // ----------------------------------------------------------------------
    // Wrap-up
    // ----------------------------------------------------------------------
    if (fail_count == 0) begin
      $display("tb_priv_csr: PASS");
    end else begin
      $display("tb_priv_csr: FAIL (%0d cases failed)", fail_count);
    end
    $finish;
  end

  // ------------------------------------------------------------------------
  // Watchdog
  // ------------------------------------------------------------------------
  initial begin
    #200000;
    $display("tb_priv_csr: TIMEOUT");
    $finish;
  end

endmodule
