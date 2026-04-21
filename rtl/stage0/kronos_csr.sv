// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_csr.sv — machine-mode CSR file for Stage 0
// Implements mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mip.
// Handles trap entry (ECALL/EBREAK/illegal), MRET, and CSR read/write.
module kronos_csr #(
  // MISA extension bits [25:0]. Default = I-only (bit 8).
  // Stage 2 passes 26'h1100 to advertise I+M.
  parameter logic [25:0] MISA_EXT = 26'h0100
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic [11:0] addr_i,
  input  logic [2:0]  funct3_i,
  input  logic        use_imm_i,
  input  logic [31:0] rs1_data_i,
  input  logic [4:0]  rs1_addr_i,
  output logic [31:0] rdata_o,
  output logic        valid_o,
  // Trap interface
  input  logic        trap_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_cause_i,
  input  logic        mret_i,
  output logic [31:0] trap_vector_o,
  output logic [31:0] mepc_o,
  // Interrupts
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  output logic        irq_pending_o
);

  // -------------------------------------------------------------------------
  // Machine-mode CSRs (state registers)
  // -------------------------------------------------------------------------
  logic [31:0] mstatus;   // 0x300
  logic [31:0] mie;       // 0x304
  logic [31:0] mtvec;     // 0x305
  logic [31:0] mscratch;  // 0x340
  logic [31:0] mepc;      // 0x341
  logic [31:0] mcause;    // 0x342

  // -------------------------------------------------------------------------
  // Read-only / combinational CSRs
  // -------------------------------------------------------------------------
  logic [31:0] misa;
  logic [31:0] mip;

  // MISA: MXL=01 (32-bit), extension bits from parameter
  assign misa = {2'b01, 4'b0, MISA_EXT};

  // MIP: fast IRQs at [30:16], timer at [7]
  assign mip  = {1'b0, irq_fast_i, 4'b0, 1'b0, 3'b0, irq_timer_i, 3'b0, 1'b0, 3'b0};

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  // Pass mtvec through unchanged.  The ACT4 test framework's RVMODEL_BOOT may
  // install _kronos_trap_handler at a 2-byte boundary when `j _kronos_boot_done`
  // is compressed to c.j despite `.option norvc`, so bit[1] of mtvec is part
  // of the actual handler address, not a MODE field.
  assign trap_vector_o = mtvec;
  assign mepc_o        = mepc;
  assign irq_pending_o = |(mip & mie) & mstatus[3]; // MIE bit
  assign valid_o       = req_i;

  // -------------------------------------------------------------------------
  // CSR read (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (addr_i)
      12'h300: rdata_o = mstatus;
      12'h301: rdata_o = misa;
      12'h304: rdata_o = mie;
      12'h305: rdata_o = mtvec;
      12'h340: rdata_o = mscratch;
      12'h341: rdata_o = mepc;
      12'h342: rdata_o = mcause;
      12'h344: rdata_o = mip;
      default: rdata_o = 32'hDEAD_C5A0; // unimplemented CSR
    endcase
  end

  // -------------------------------------------------------------------------
  // CSR write data (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] csr_wdata;
  logic [31:0] csr_new_val;

  always_comb begin
    csr_wdata   = use_imm_i ? {27'b0, rs1_addr_i} : rs1_data_i;
    csr_new_val = rdata_o;  // default: no change
    unique case (funct3_i[1:0])
      2'b01:   csr_new_val = csr_wdata;              // CSRRW / CSRRWI
      2'b10:   csr_new_val = rdata_o | csr_wdata;   // CSRRS / CSRRSI
      2'b11:   csr_new_val = rdata_o & ~csr_wdata;  // CSRRC / CSRRCI
      default: csr_new_val = rdata_o;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus  <= 32'h0000_1800; // MPP=11 (machine mode)
      mie      <= {32{1'b0}};
      mtvec    <= {32{1'b0}};
      mscratch <= {32{1'b0}};
      mepc     <= {32{1'b0}};
      mcause   <= {32{1'b0}};
    end else begin
      // Trap entry (highest priority)
      if (trap_i) begin
        mepc       <= trap_pc_i;
        mcause     <= trap_cause_i;
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
          12'h300: mstatus  <= csr_new_val;
          12'h304: mie      <= csr_new_val;
          12'h305: mtvec    <= csr_new_val;
          12'h340: mscratch <= csr_new_val;
          12'h341: mepc     <= csr_new_val;
          12'h342: mcause   <= csr_new_val;
          default: ; // read-only or unimplemented: ignore write
        endcase
      end
    end
  end

endmodule
