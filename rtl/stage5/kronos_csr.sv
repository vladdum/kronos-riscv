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
  output logic [2:0]  frm_o,
  // Zicntr: instruction retirement pulse (mem_wb_q.valid & pipeline advance).
  // Asserted once per retired instruction.  Tie to 0 for stages without Zicntr.
  input  logic        instret_retire_i,
  // Zihpm event bus.  Bit i high if event ID i fires this cycle.
  // Indexed by mhpmeventX[7:0] (event IDs >= 32 increment no counter).
  input  logic [31:0] event_bus_i
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

  // Zicntr counters — read-only user-mode counters (mirrored from m-mode
  // mcycle/minstret in a full implementation; here we just expose free-running
  // counters at 0xC00/0xC02 so ACT4 Zicntr tests pass).
  logic [63:0] mcycle;    // 0xB00 / 0xC00 (U-mode alias)
  logic [63:0] minstret;  // 0xB02 / 0xC02 (U-mode alias)

  // -------------------------------------------------------------------------
  // Zihpm counter-control + event counters (Stage 5c)
  // -------------------------------------------------------------------------
  // mcountinhibit (0x320) — bit X gates increment of counter X:
  //   bit 0  = mcycle, bit 1 = reserved (RAZ/WI), bit 2 = minstret,
  //   bits 3..10 = mhpmcounter3..10.
  logic [10:0] mcountinhibit;

  // mhpmcounter3..10 — 8 programmable 64-bit event counters.
  // Indexed as mhpmcounter[3]..mhpmcounter[10]; entries [0..2] are unused
  // (their CSR slots are mcycle/reserved/minstret which live above).
  logic [63:0] mhpmcounter [3:10];

  // mhpmevent3..10 — paired event-select registers (only bits [7:0] used).
  logic [7:0]  mhpmevent   [3:10];

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
  assign trap_vector_o = mtvec;
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
      12'h300: rdata_o = {(mstatus[14:13] == 2'b11), mstatus[62:0]}; // bit63=SD, derived from FS
      12'h301: rdata_o = misa;
      12'h304: rdata_o = mie;
      12'h305: rdata_o = mtvec;
      12'h320: rdata_o = {53'b0, mcountinhibit};         // mcountinhibit
      12'h323: rdata_o = {56'b0, mhpmevent[3]};
      12'h324: rdata_o = {56'b0, mhpmevent[4]};
      12'h325: rdata_o = {56'b0, mhpmevent[5]};
      12'h326: rdata_o = {56'b0, mhpmevent[6]};
      12'h327: rdata_o = {56'b0, mhpmevent[7]};
      12'h328: rdata_o = {56'b0, mhpmevent[8]};
      12'h329: rdata_o = {56'b0, mhpmevent[9]};
      12'h32A: rdata_o = {56'b0, mhpmevent[10]};
      12'h340: rdata_o = mscratch;
      12'h341: rdata_o = mepc;
      12'h342: rdata_o = mcause;
      12'h344: rdata_o = mip;
      // Zicntr (U-mode read-only views) + M-mode aliases
      12'hC00, 12'hB00: rdata_o = mcycle;                     // cycle / mcycle
      12'hC01:          rdata_o = mcycle;                     // time (mirror cycle)
      12'hC02, 12'hB02: rdata_o = minstret;                   // instret / minstret
      // Zihpm counters: M-mode RW (0xB03..0xB0A) and U-mode RO aliases (0xC03..0xC0A)
      12'hB03, 12'hC03: rdata_o = mhpmcounter[3];
      12'hB04, 12'hC04: rdata_o = mhpmcounter[4];
      12'hB05, 12'hC05: rdata_o = mhpmcounter[5];
      12'hB06, 12'hC06: rdata_o = mhpmcounter[6];
      12'hB07, 12'hC07: rdata_o = mhpmcounter[7];
      12'hB08, 12'hC08: rdata_o = mhpmcounter[8];
      12'hB09, 12'hC09: rdata_o = mhpmcounter[9];
      12'hB0A, 12'hC0A: rdata_o = mhpmcounter[10];
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
      mie      <= {64{1'b0}};
      mtvec    <= {64{1'b0}};
      mscratch <= {64{1'b0}};
      mepc     <= {64{1'b0}};
      mcause   <= {64{1'b0}};
      fcsr_q   <= 8'h00;
      mcycle   <= {64{1'b0}};
      minstret <= {64{1'b0}};
      mcountinhibit <= '0;
      for (int i = 3; i <= 10; i++) begin
        mhpmcounter[i] <= '0;
        mhpmevent[i]   <= '0;
      end
    end else begin
      // ---- Default: counters tick (gated by mcountinhibit) ----
      // mcycle (gated by mcountinhibit[0]; SW write takes priority)
      if (~mcountinhibit[0] & ~(req_i & (addr_i == 12'hB00))) mcycle <= mcycle + 64'd1;
      // minstret (gated by mcountinhibit[2] and qualified by retire; SW write takes priority)
      if (~mcountinhibit[2] & instret_retire_i & ~(req_i & (addr_i == 12'hB02)))
        minstret <= minstret + 64'd1;
      // mhpmcounterX: increment when event-mux selects the asserted bus line
      // and counter is not inhibited.  Out-of-range event IDs (>= 16) result
      // in no increment.  A same-cycle SW write to THIS counter takes priority;
      // accesses to any other CSR address must not suppress the tick.
      for (int i = 3; i <= 10; i++) begin
        if (~mcountinhibit[i] & (mhpmevent[i] < 8'd32)
                              & event_bus_i[mhpmevent[i][4:0]]
                              & ~(req_i & (addr_i == 12'(12'hB00 + i))))
          mhpmcounter[i] <= mhpmcounter[i] + 64'd1;
      end

      // Trap entry (highest priority for non-counter state)
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
      // CSR write (overrides default counter tick on the same cycle)
      if (req_i) begin
        unique case (addr_i)
          12'h001: fcsr_q[4:0] <= csr_new_val[4:0];
          12'h002: fcsr_q[7:5] <= csr_new_val[2:0];
          12'h003: fcsr_q      <= csr_new_val[7:0];
          12'h300: mstatus  <= csr_new_val & 64'h7FFF_FFFF_FFFF_FFFF;
          12'h304: mie      <= csr_new_val;
          12'h305: mtvec    <= csr_new_val;
          12'h320: mcountinhibit <= csr_new_val[10:0];
          12'h323: mhpmevent[3]  <= csr_new_val[7:0];
          12'h324: mhpmevent[4]  <= csr_new_val[7:0];
          12'h325: mhpmevent[5]  <= csr_new_val[7:0];
          12'h326: mhpmevent[6]  <= csr_new_val[7:0];
          12'h327: mhpmevent[7]  <= csr_new_val[7:0];
          12'h328: mhpmevent[8]  <= csr_new_val[7:0];
          12'h329: mhpmevent[9]  <= csr_new_val[7:0];
          12'h32A: mhpmevent[10] <= csr_new_val[7:0];
          12'h340: mscratch <= csr_new_val;
          12'h341: mepc     <= csr_new_val;
          12'h342: mcause   <= csr_new_val;
          // Counter writes — SW-write-wins precedence over default increment
          12'hB00: mcycle        <= csr_new_val;
          12'hB02: minstret      <= csr_new_val;
          12'hB03: mhpmcounter[3]  <= csr_new_val;
          12'hB04: mhpmcounter[4]  <= csr_new_val;
          12'hB05: mhpmcounter[5]  <= csr_new_val;
          12'hB06: mhpmcounter[6]  <= csr_new_val;
          12'hB07: mhpmcounter[7]  <= csr_new_val;
          12'hB08: mhpmcounter[8]  <= csr_new_val;
          12'hB09: mhpmcounter[9]  <= csr_new_val;
          12'hB0A: mhpmcounter[10] <= csr_new_val;
          default: ; // read-only or unimplemented: ignore write
        endcase
      end
      // Sticky FFLAGS accumulation from FPU writeback (OR on top of CSR writes)
      if (fflags_we_i) fcsr_q[4:0] <= fcsr_q[4:0] | fflags_delta_i;
      // mstatus.FS becomes Dirty (11) on any FP register or fcsr write.
      if (fp_rd_we_i || fflags_we_i || fp_csr_sw_write) begin
        mstatus[14:13] <= 2'b11;
      end
    end
  end

endmodule
