// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_csr.sv — machine-mode CSR file for Stage 5 (RV64IMAFD)
// Implements mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mip.
// Handles trap entry (ECALL/EBREAK/illegal), MRET, and CSR read/write.
// Stage 5a adds FFLAGS/FRM/FCSR floating-point CSRs and mstatus.FS storage.
// All CSR data paths are 64 bits wide (MXL=10, XLEN=64).
module kronos_csr #(
  // MISA extension bits [25:0]. Default = I+M+A+C+F+D (bits 8,12,0,2,5,3).
  parameter logic [25:0] MISA_EXT = 26'h0_112D
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic [11:0] addr_i,
  input  logic [2:0]  funct3_i,
  input  logic        use_imm_i,
  input  logic [63:0] rs1_data_i,
  input  logic [4:0]  rs1_addr_i,
  output logic [63:0] rdata_o,
  output logic        valid_o,
  // Trap interface
  input  logic        trap_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_cause_i,
  input  logic        mret_i,
  output logic [63:0] trap_vector_o,
  output logic [63:0] mepc_o,
  // Interrupts
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  output logic        irq_pending_o,
  // Stage 5a: FP CSR interface
  input  logic [4:0]  fflags_delta_i,
  input  logic        fflags_we_i,
  input  logic        fp_rd_we_i,        // any FP destination write this cycle
  output logic [2:0]  frm_o
);

  // -------------------------------------------------------------------------
  // Machine-mode CSRs (state registers)
  // -------------------------------------------------------------------------
  logic [63:0] mstatus;   // 0x300
  logic [63:0] mie;       // 0x304
  logic [63:0] mtvec;     // 0x305
  logic [63:0] mscratch;  // 0x340
  logic [63:0] mepc;      // 0x341
  logic [63:0] mcause;    // 0x342

  // FCSR = {FRM[2:0], FFLAGS[4:0]} — 8 bits, zero-extended to 64 for reads.
  logic [7:0]  fcsr_q;    // 0x001/0x002/0x003

  // -------------------------------------------------------------------------
  // Read-only / combinational CSRs
  // -------------------------------------------------------------------------
  logic [63:0] misa;
  logic [63:0] mip;

  // MISA: MXL=10 (64-bit) in bits [63:62], extension bits from parameter
  assign misa = {2'b10, 36'b0, MISA_EXT};

  // MIP: fast IRQs at [30:16], timer at [7] — zero-extended to 64 bits
  assign mip  = {33'b0, irq_fast_i, 4'b0, 1'b0, 3'b0, irq_timer_i, 3'b0, 1'b0, 3'b0};

  // -------------------------------------------------------------------------
  // CSR write data (combinational)
  // -------------------------------------------------------------------------
  logic [63:0] csr_wdata;
  logic [63:0] csr_new_val;
  logic        fp_csr_sw_write;

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  assign trap_vector_o = {mtvec[63:2], 2'b00};  // direct mode only
  assign mepc_o        = mepc;
  assign irq_pending_o = |(mip & mie) & mstatus[3]; // MIE bit
  assign valid_o       = req_i;
  assign frm_o         = fcsr_q[7:5];

  // -------------------------------------------------------------------------
  // CSR read (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (addr_i)
      12'h001: rdata_o = {59'b0, fcsr_q[4:0]};           // FFLAGS
      12'h002: rdata_o = {61'b0, fcsr_q[7:5]};           // FRM
      12'h003: rdata_o = {56'b0, fcsr_q};                 // FCSR
      12'h300: rdata_o = mstatus;
      12'h301: rdata_o = misa;
      12'h304: rdata_o = mie;
      12'h305: rdata_o = mtvec;
      12'h340: rdata_o = mscratch;
      12'h341: rdata_o = mepc;
      12'h342: rdata_o = mcause;
      12'h344: rdata_o = mip;
      default: rdata_o = 64'hDEAD_C5A0_DEAD_C5A0; // unimplemented CSR
    endcase
  end

  always_comb begin
    csr_wdata   = use_imm_i ? {59'b0, rs1_addr_i} : rs1_data_i;
    csr_new_val = rdata_o;  // default: no change
    unique case (funct3_i[1:0])
      2'b01:   csr_new_val = csr_wdata;              // CSRRW / CSRRWI
      2'b10:   csr_new_val = rdata_o | csr_wdata;    // CSRRS / CSRRSI
      2'b11:   csr_new_val = rdata_o & ~csr_wdata;   // CSRRC / CSRRCI
      default: csr_new_val = rdata_o;
    endcase
  end

  // SW write to any FP CSR (fflags=0x001, frm=0x002, fcsr=0x003) marks FS=Dirty.
  assign fp_csr_sw_write = req_i &
                           (addr_i == 12'h001
                          | addr_i == 12'h002
                          | addr_i == 12'h003);

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus  <= 64'h0000_0000_0000_3800; // MPP=11, FS=01 (Initial) — FP enabled at boot
      mie      <= '0;
      mtvec    <= '0;
      mscratch <= '0;
      mepc     <= '0;
      mcause   <= '0;
      fcsr_q   <= 8'h00;
    end else begin
      // Trap entry (highest priority)
      if (trap_i) begin
        mepc       <= {32'b0, trap_pc_i};
        mcause     <= {32'b0, trap_cause_i};
        mstatus[7] <= mstatus[3]; // MPIE = MIE
        mstatus[3] <= 1'b0;       // MIE = 0 (disable interrupts on trap)
      end
      // MRET: restore interrupt state
      if (mret_i) begin
        mstatus[3] <= mstatus[7]; // MIE = MPIE
        mstatus[7] <= 1'b1;       // MPIE = 1
      end
      // CSR write
      if (req_i) begin
        unique case (addr_i)
          12'h001: fcsr_q[4:0] <= csr_new_val[4:0];
          12'h002: fcsr_q[7:5] <= csr_new_val[2:0];
          12'h003: fcsr_q      <= csr_new_val[7:0];
          12'h300: mstatus  <= csr_new_val;
          12'h304: mie      <= csr_new_val;
          12'h305: mtvec    <= csr_new_val;
          12'h340: mscratch <= csr_new_val;
          12'h341: mepc     <= csr_new_val;
          12'h342: mcause   <= csr_new_val;
          default: ; // read-only or unimplemented: ignore write
        endcase
      end
      // Sticky FFLAGS accumulation from FPU writeback (OR on top of CSR writes)
      if (fflags_we_i) fcsr_q[4:0] <= fcsr_q[4:0] | fflags_delta_i;
      // mstatus.FS becomes Dirty (11) on any FP register or fcsr write.
      // Placed after the CSR-write case so HW-set wins over a same-cycle SW
      // write that would otherwise leave FS at a non-Dirty value.
      if (fp_rd_we_i || fflags_we_i || fp_csr_sw_write) begin
        mstatus[14:13] <= 2'b11;
      end
    end
  end

endmodule
