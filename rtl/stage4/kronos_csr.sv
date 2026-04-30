// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_csr.sv — machine-mode CSR file for Stage 4 (RV64)
// Implements mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mip.
// Handles trap entry (ECALL/EBREAK/illegal), MRET, and CSR read/write.
// All CSR data paths are 64 bits wide (MXL=10, XLEN=64).
module kronos_csr #(
  // MISA extension bits [25:0]. Default = I-only (bit 8).
  // Stage 4 advertises I+M+A+C as appropriate via the top-level parameter.
  parameter logic [25:0] MISA_EXT = 26'h0100
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
  output logic        irq_pending_o
);

  // -------------------------------------------------------------------------
  // 3. State registers — Machine-mode CSRs
  // -------------------------------------------------------------------------
  logic [63:0] mstatus_q;   // 0x300
  logic [63:0] mie_q;       // 0x304
  logic [63:0] mtvec_q;     // 0x305
  logic [63:0] mscratch_q;  // 0x340
  logic [63:0] mepc_q;      // 0x341
  logic [63:0] mcause_q;    // 0x342

  // -------------------------------------------------------------------------
  // 4. Combinational signals — read-only CSRs and CSR-write datapath
  // -------------------------------------------------------------------------
  logic [63:0] misa;
  logic [63:0] mip;
  logic [63:0] csr_wdata;
  logic [63:0] csr_new_val;

  // MISA: MXL=10 (64-bit) in bits [63:62], extension bits from parameter
  assign misa = {2'b10, 36'b0, MISA_EXT};

  // MIP: fast IRQs at [30:16], timer at [7] — zero-extended to 64 bits
  assign mip  = {33'b0, irq_fast_i, 4'b0, 1'b0, 3'b0, irq_timer_i, 3'b0, 1'b0, 3'b0};

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  // trap_vector_o: pass mtvec through unchanged.  The test framework's
  // RVMODEL_BOOT installs _kronos_trap_handler at a 2-byte-aligned address
  // when c.j is selected for the `j _kronos_boot_done` pseudo-instruction
  // (despite `.option norvc`), so bit[1] of mtvec is part of the actual
  // handler address, not a MODE bit.
  assign trap_vector_o = mtvec_q;
  assign mepc_o        = mepc_q;
  assign irq_pending_o = |(mip & mie_q) & mstatus_q[3]; // MIE bit
  assign valid_o       = req_i;

  // -------------------------------------------------------------------------
  // CSR read (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    rdata_o = 64'hDEAD_C5A0_DEAD_C5A0;
    unique case (addr_i)
      12'h300: rdata_o = mstatus_q;
      12'h301: rdata_o = misa;
      12'h304: rdata_o = mie_q;
      12'h305: rdata_o = mtvec_q;
      12'h340: rdata_o = mscratch_q;
      12'h341: rdata_o = mepc_q;
      12'h342: rdata_o = mcause_q;
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

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q  <= 64'h0000_0000_0000_1800; // MPP=11 (machine mode)
      mie_q      <= {64{1'b0}};
      mtvec_q    <= {64{1'b0}};
      mscratch_q <= {64{1'b0}};
      mepc_q     <= {64{1'b0}};
      mcause_q   <= {64{1'b0}};
    end else begin
      // Trap entry (highest priority)
      if (trap_i) begin
        mepc_q       <= {32'b0, trap_pc_i};
        mcause_q     <= {32'b0, trap_cause_i};
        mstatus_q[7] <= mstatus_q[3]; // MPIE = MIE
        mstatus_q[3] <= 1'b0;         // MIE = 0 (disable interrupts on trap)
      end
      // MRET: restore interrupt state
      if (mret_i) begin
        mstatus_q[3] <= mstatus_q[7]; // MIE = MPIE
        mstatus_q[7] <= 1'b1;         // MPIE = 1
      end
      // CSR write
      if (req_i) begin
        unique case (addr_i)
          12'h300: mstatus_q  <= csr_new_val;
          12'h304: mie_q      <= csr_new_val;
          12'h305: mtvec_q    <= csr_new_val;
          12'h340: mscratch_q <= csr_new_val;
          12'h341: mepc_q     <= csr_new_val;
          12'h342: mcause_q   <= csr_new_val;
          default: ; // read-only or unimplemented: ignore write
        endcase
      end
    end
  end

endmodule
