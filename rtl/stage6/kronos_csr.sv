// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_csr.sv — machine-mode CSR file for Stage 5 (RV64IMAFD)
// Implements mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mip.
// Handles trap entry (ECALL/EBREAK/illegal), MRET, and CSR read/write.
// Stage 5a adds FFLAGS/FRM/FCSR floating-point CSRs and mstatus.FS storage.
// All CSR data paths are 64 bits wide (MXL=10, kronos_pkg::XLEN=64).
module kronos_csr
  import kronos_pkg::*;
#(
  // MISA extension bits [25:0]. Default = I+M+A+C+F+D (bits 8,12,0,2,5,3).
  parameter logic [25:0] MISA_EXT = 26'h0_112D
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic [11:0] addr_i,
  input  logic [2:0]  funct3_i,
  input  logic        use_imm_i,
  input  logic [kronos_pkg::XLEN-1:0] rs1_data_i,
  input  logic [4:0]      rs1_addr_i,
  output logic [kronos_pkg::XLEN-1:0] rdata_o,
  output logic        valid_o,
  // Trap interface
  input  logic        trap_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,
  input  logic        sret_i,
  // SFENCE.VMA passthrough.  Decode asserts sfence_vma_i for one cycle
  // when an SFENCE.VMA retires; the CSR module forwards the pulse + operands to
  // both TLBs (I-TLB and D-TLB) via the matching *_o ports.  Pure combinational
  // passthrough — no architectural state involved.
  input  logic              sfence_vma_i,
  input  logic [kronos_pkg::XLEN-1:0]   sfence_va_i,
  input  logic [15:0]       sfence_asid_i,
  input  logic              sfence_va_valid_i,
  input  logic              sfence_asid_valid_i,
  output logic              sfence_vma_o,
  output logic [kronos_pkg::XLEN-1:0]   sfence_va_o,
  output logic [15:0]       sfence_asid_o,
  output logic              sfence_va_valid_o,
  output logic              sfence_asid_valid_o,
  // satp.MODE / ASID / PPN broken out for the address-translation
  // engine (PTW, TLBs).  Driven combinationally from the satp register.
  output logic [3:0]        satp_mode_o,
  output logic [15:0]       satp_asid_o,
  output logic [43:0]       satp_ppn_o,
  output logic [kronos_pkg::XLEN-1:0] trap_vector_o,
  output logic [kronos_pkg::XLEN-1:0] mepc_o,
  // sepc output for sret target redirection (kronos_top reads this
  // when an SRET advances out of EX).
  output logic [kronos_pkg::XLEN-1:0] sepc_o,
  // current privilege level (M/S/U)
  output priv_e           priv_o,
  // full mstatus exposed for top-level (TW/TSR/TVM consultation).
  output logic [kronos_pkg::XLEN-1:0] mstatus_o,
  // Interrupts
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  // standard RISC-V interrupt sources (priv-spec § 3.1.9).
  // Driven from the platform/PLIC by kronos_top.  Default 0 keeps the legacy
  // irq_timer/irq_fast platform IRQs functional.
  input  logic        irq_msi_i,        // machine software interrupt
  input  logic        irq_mei_i,        // machine external interrupt
  input  logic        irq_ssi_i,        // supervisor software interrupt
  input  logic        irq_sti_i,        // supervisor timer interrupt
  input  logic        irq_sei_i,        // supervisor external interrupt
  output logic        irq_pending_o,
  // one-hot priority-encoded interrupt cause.  Mirrors the bit index
  // of the asserted interrupt in mip & mie, gated by mstatus.MIE/SIE and the
  // current privilege.  Used by kronos_top to drive trap_cause_i.
  output logic [4:0]  irq_cause_o,
  // FP CSR interface
  input  logic [4:0]  fflags_delta_i,
  input  logic        fflags_we_i,
  input  logic        fp_rd_we_i,        // any FP destination write this cycle
  output logic [2:0]  frm_o,
  // Zicntr: instruction retirement pulse (mem_wb_q.valid & pipeline advance).
  // Asserted once per retired instruction.  Tie to 0 for stages without Zicntr.
  input  logic        instret_retire_i,
  // Zihpm event bus.  Bit i high if event ID i fires this cycle.
  // Indexed by mhpmeventX[7:0] (event IDs >= 32 increment no counter).
  input  logic [31:0] event_bus_i,
  // hand-off for Sdtrig CSRs (0x7A0..0x7A4).  When trig_csr_match_i
  // is high, the trigger module owns this CSR read; csr_rdata is sourced from
  // trig_csr_rdata_i instead of the local mux.  Writes are forwarded to the
  // trigger module via trig_csr_we_o below.
  input  logic [kronos_pkg::XLEN-1:0] trig_csr_rdata_i,
  input  logic            trig_csr_match_i,
  output logic            trig_csr_we_o,    // 1 = current cycle is a trigger CSR write
  // post-write CSR value (combinational, valid for any csrrs/csrrc/csrrw).
  // Routed to retire_csr_wdata_o at top so the Sail-vs-Kronos trace diff sees
  // the new CSR value rather than the RS1 operand.
  output logic [kronos_pkg::XLEN-1:0] csr_new_val_o,
  output logic [kronos_pkg::XLEN-1:0] trig_csr_wdata_o, // CSR new value (after CSRRS/CSRRC)
  // illegal-CSR-access aggregate output.  Currently driven by the
  // counter-access gate (mcounteren/scounteren).  T11 will OR additional
  // sources (privilege/RO-write checks) into this signal.  Top-level wiring
  // happens in T13 — leaving this unconnected for now is expected (PINMISSING).
  output logic        csr_illegal_o,
  // PMP cfg/addr fan-out to the two kronos_pmp instances in
  // kronos_top.  Packed-array form mirrors the kronos_pmp port shape.
  output logic [15:0][7:0]  pmpcfg_o,
  output logic [15:0][53:0] pmpaddr_o
);

  // -------------------------------------------------------------------------
  // 1. Constants — repeated CSR write-mask localparams (rule R9)
  // -------------------------------------------------------------------------
  // S-mode interrupt bits (SSIE/STIE/SEIE → SSIP/STIP/SEIP).  Used by mideleg
  // WARL mask, the SIE/SIP windows, and the irq_eff S-mode IRQ path.
  localparam logic [kronos_pkg::XLEN-1:0] SMODE_IRQ_MASK   = 64'h0000_0000_0000_0222;
  // mstatus M-mode writable-bit mask (Stage 6a-implemented bits; see decode).
  localparam logic [kronos_pkg::XLEN-1:0] MSTATUS_M_MASK   = 64'h0000_0000_007E_79AA;
  // sstatus S-visible writable-bit mask (used for both write-decode and read).
  localparam logic [kronos_pkg::XLEN-1:0] SSTATUS_RW_MASK  = 64'h8000_0003_000D_E162;
  // SSTATUS read mask without SD (bit 63) — SD is recomputed from FS == 11.
  localparam logic [kronos_pkg::XLEN-2:0] SSTATUS_RD_MASK  = 63'h0000_0003_000D_E162;
  // medeleg WARL mask (bits 0..15 except 11/14 hardwired 0).
  localparam logic [kronos_pkg::XLEN-1:0] MEDELEG_MASK     = 64'h0000_0000_0000_B7FF;

  // -------------------------------------------------------------------------
  // 3. State registers (driven by always_ff)
  // -------------------------------------------------------------------------
  // privilege state.  Reset → M.
  // Updated on trap entry, mret, sret (see always_ff block).
  priv_e priv_q;

  // Machine-mode CSRs
  logic [kronos_pkg::XLEN-1:0] mstatus;   // 0x300
  logic [kronos_pkg::XLEN-1:0] mie;       // 0x304
  logic [kronos_pkg::XLEN-1:0] mtvec;     // 0x305
  logic [kronos_pkg::XLEN-1:0] mscratch;  // 0x340
  logic [kronos_pkg::XLEN-1:0] mepc;      // 0x341
  logic [kronos_pkg::XLEN-1:0] mcause;    // 0x342
  logic [kronos_pkg::XLEN-1:0] mtval;     // 0x343
  logic [kronos_pkg::XLEN-1:0] medeleg;   // 0x302  -- per-cause sync exception delegation
  logic [kronos_pkg::XLEN-1:0] mideleg;   // 0x303  -- per-cause interrupt delegation
  // software-written shadow of the SSIP/STIP/SEIP bits.
  // We keep `mip` itself as a continuous assign for hardware-driven bits
  // (irq_timer/irq_fast).  CSR writes (M-mode: SSIP/STIP/SEIP, S-mode: SSIP)
  // land in mip_sw; the read mux/path uses (mip | mip_sw).  This is the less
  // invasive of the two T7 options — no register conversion of mip required.
  logic [kronos_pkg::XLEN-1:0] mip_sw;

  // S-mode CSRs.
  // sstatus / sip / sie are *windows* into mstatus/mip/mie — handled in
  // the read mux and write decode below.
  logic [kronos_pkg::XLEN-1:0] stvec;          // bit[1:0] hardwired 00 (Direct)
  logic [kronos_pkg::XLEN-1:0] sscratch;
  logic [kronos_pkg::XLEN-1:0] sepc;           // bit[0] hardwired 0
  logic [kronos_pkg::XLEN-1:0] scause;
  logic [kronos_pkg::XLEN-1:0] stval;
  logic [kronos_pkg::XLEN-1:0] satp;           // MODE reads as 0 in 6a
  logic [31:0]     scounteren;
  logic [kronos_pkg::XLEN-1:0] senvcfg;        // hardwired 0 in 6a

  // FCSR = {FRM[2:0], FFLAGS[4:0]} — 8 bits, zero-extended to 64 for reads.
  logic [7:0]  fcsr_q;    // 0x001/0x002/0x003

  // Zicntr counters — read-only user-mode counters (mirrored from m-mode
  // mcycle/minstret in a full implementation; here we just expose free-running
  // counters at 0xC00/0xC02 so ACT4 Zicntr tests pass).
  logic [kronos_pkg::XLEN-1:0] mcycle;    // 0xB00 / 0xC00 (U-mode alias)
  logic [kronos_pkg::XLEN-1:0] minstret;  // 0xB02 / 0xC02 (U-mode alias)

  // Zihpm counter-control + event counters (Stage 5c).
  // mcountinhibit (0x320) — bit X gates increment of counter X:
  //   bit 0  = mcycle, bit 1 = reserved (RAZ/WI), bit 2 = minstret,
  //   bits 3..10 = mhpmcounter3..10.
  logic [10:0] mcountinhibit;

  // mcounteren (0x306) — bit X gates S/U-mode access to counter X
  // at CSR addresses 0xC00 + X (cycle/time/instret/hpmcounter3..31).
  // Paired with scounteren (already declared above) for U-mode gating.
  logic [31:0] mcounteren;

  // PMP — 16 regions (pmpcfg0/pmpcfg2 + pmpaddr0..15 active).
  logic [7:0]  pmpcfg_q   [0:15];  // per-region cfg byte
  logic [53:0] pmpaddr_q  [0:15];  // per-region addr (PA[55:2])

  // mhpmcounter3..10 — 8 programmable 64-bit event counters.
  // Indexed as mhpmcounter[3]..mhpmcounter[10]; entries [0..2] are unused
  // (their CSR slots are mcycle/reserved/minstret which live above).
  logic [kronos_pkg::XLEN-1:0] mhpmcounter [3:10];

  // mhpmevent3..10 — paired event-select registers (only bits [7:0] used).
  logic [7:0]  mhpmevent   [3:10];

  // -------------------------------------------------------------------------
  // 4. Combinational signals
  // -------------------------------------------------------------------------
  // Read-only / hardware-driven CSR views
  logic [kronos_pkg::XLEN-1:0] misa;
  logic [kronos_pkg::XLEN-1:0] mip;

  // CSR write-data path
  logic [kronos_pkg::XLEN-1:0] csr_wdata;
  logic [kronos_pkg::XLEN-1:0] csr_new_val;
  logic            fp_csr_sw_write;

  // trap delegation routing.  When priv != M and the cause's
  // medeleg/mideleg bit is set, the trap is taken to S-mode (stvec) instead
  // of M-mode (mtvec).  M-mode traps NEVER delegate.
  logic       delegate_to_s;
  logic [4:0] cause_idx;

  // interrupt-priority encoder outputs (see always_comb below).
  logic [kronos_pkg::XLEN-1:0] irq_eff;
  logic [4:0]      irq_cause_int;
  logic            irq_pending_int;

  // counter-access gating + CSR-access privilege check outputs.
  logic counter_access_illegal;
  logic priv_check_fail;
  // Per-access minimum privilege from CSR addr bits [9:8] (rule R2: promoted
  // from previously-`automatic` locals inside the priv-check always_comb).
  logic [1:0] required_priv;
  priv_e      min_priv;

  // MISA: MXL=10 (64-bit) in bits [63:62], extension bits from parameter
  assign misa = {2'b10, 36'b0, MISA_EXT};

  // MIP: standard RV bits (MEIP=11, SEIP=9, MTIP=7, STIP=5, MSIP=3, SSIP=1)
  // OR'd with the existing platform IRQs (irq_fast_i at [30:16], irq_timer_i
  // at [7] kept for backwards-compatible OpenSoC integration).
  // Bit-by-bit MSB→LSB layout:
  //   [63:31] = 33'b0
  //   [30:16] = irq_fast_i (15 bits, platform)
  //   [15:12] = 4'b0
  //   [11]    = MEIP (irq_mei_i)
  //   [10]    = 0
  //   [9]     = SEIP (irq_sei_i)
  //   [8]     = 0
  //   [7]     = MTIP (irq_timer_i)
  //   [6]     = 0
  //   [5]     = STIP (irq_sti_i)
  //   [4]     = 0
  //   [3]     = MSIP (irq_msi_i)
  //   [2]     = 0
  //   [1]     = SSIP (irq_ssi_i)
  //   [0]     = 0
  // Width: 33 + 15 + 4 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 = 64.
  assign mip  = {33'b0, irq_fast_i,
                 4'b0,
                 irq_mei_i,   1'b0,
                 irq_sei_i,   1'b0,
                 irq_timer_i, 1'b0,
                 irq_sti_i,   1'b0,
                 irq_msi_i,   1'b0,
                 irq_ssi_i,   1'b0};

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  assign trap_vector_o = delegate_to_s ? stvec : mtvec;
  assign mepc_o        = mepc;
  assign sepc_o        = sepc;
  assign valid_o       = req_i;
  assign frm_o         = fcsr_q[7:5];
  assign priv_o        = priv_q;
  assign mstatus_o     = mstatus;

  // SFENCE.VMA pulse passthrough (decode → both TLBs).
  assign sfence_vma_o        = sfence_vma_i;
  assign sfence_va_o         = sfence_va_i;
  assign sfence_asid_o       = sfence_asid_i;
  assign sfence_va_valid_o   = sfence_va_valid_i;
  assign sfence_asid_valid_o = sfence_asid_valid_i;

  // satp fields broken out for the translation engine.
  assign satp_mode_o = satp[63:60];
  assign satp_asid_o = satp[59:44];
  assign satp_ppn_o  = satp[43:0];

  // -------------------------------------------------------------------------
  // interrupt priority encoder.
  //
  // Priority order (RISC-V Privileged § 3.1.9):
  //   MEI > MSI > MTI > SEI > SSI > STI
  //
  // Gating:
  //   - M-mode interrupts fire when mstatus.MIE=1 OR priv != M (priv-spec § 3.1.6.1).
  //     For simplicity we follow the original behaviour: gate by mstatus[3]
  //     (MIE) — already the case before this change; M-mode IRQs taken in S/U
  //     would require priv-asymmetric gating that the existing trap path does
  //     not yet implement.  This matches the prior 1-bit irq_pending_o.
  //   - S-mode interrupts fire when mstatus.SIE=1 AND priv != M (priv != M
  //     because in M-mode, S-mode IRQs are masked unless delegated AND priv<M).
  // -------------------------------------------------------------------------
  assign irq_eff = (mip | mip_sw) & mie;

  always_comb begin
    irq_pending_int = 1'b0;
    irq_cause_int   = 5'd0;
    if      (irq_eff[11] & mstatus[3])                      begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd11;        // MEI
    end else if (irq_eff[3]  & mstatus[3])                  begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd3;         // MSI
    end else if (irq_eff[7]  & mstatus[3])                  begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd7;         // MTI
    end else if (irq_eff[9]  & mstatus[1] & (priv_q != PRIV_M)) begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd9;         // SEI
    end else if (irq_eff[1]  & mstatus[1] & (priv_q != PRIV_M)) begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd1;         // SSI
    end else if (irq_eff[5]  & mstatus[1] & (priv_q != PRIV_M)) begin
      irq_pending_int = 1'b1; irq_cause_int = 5'd5;         // STI
    end
  end

  assign irq_pending_o = irq_pending_int;
  assign irq_cause_o   = irq_cause_int;

  // PMP cfg/addr packed-array fan-out to kronos_pmp.
  always_comb begin
    for (int i = 0; i < 16; i++) begin
      pmpcfg_o[i]  = pmpcfg_q[i];
      pmpaddr_o[i] = pmpaddr_q[i];
    end
  end

  // synchronous delegation decision (exceptions vs interrupts).
  // Bit 31 of mcause distinguishes interrupts from exceptions.
  always_comb begin
    cause_idx     = trap_cause_i[4:0];
    delegate_to_s = trap_i &
                    (priv_q != PRIV_M) &
                    ( (~trap_cause_i[31] & medeleg[cause_idx]) |
                      ( trap_cause_i[31] & mideleg[cause_idx]) );
  end

  // -------------------------------------------------------------------------
  // CSR read (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    // Default (rule R7) — overridden by every legal CSR address below; the
    // unique-case `default` arm preserves the trigger-CSR override path.
    rdata_o = 64'hDEAD_C5A0_DEAD_C5A0;
    unique case (addr_i)
      12'h001: rdata_o = {59'b0, fcsr_q[4:0]};           // FFLAGS
      12'h002: rdata_o = {61'b0, fcsr_q[7:5]};           // FRM
      12'h003: rdata_o = {56'b0, fcsr_q};                 // FCSR
      12'h300: rdata_o = {(mstatus[14:13] == 2'b11), mstatus[62:0]}; // bit63=SD, derived from FS
      12'h301: rdata_o = misa;
      kronos_pkg::CSR_MEDELEG: rdata_o = medeleg;
      kronos_pkg::CSR_MIDELEG: rdata_o = mideleg;
      12'h304: rdata_o = mie;
      12'h305: rdata_o = mtvec;
      kronos_pkg::CSR_MCOUNTEREN: rdata_o = {32'd0, mcounteren};
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
      12'h343: rdata_o = mtval;
      12'h344: rdata_o = mip | mip_sw;
      // PMP CSRs.  pmpcfg0 packs cfg bytes 0..7; pmpcfg2 packs 8..15.
      kronos_pkg::CSR_PMPCFG0: rdata_o = {pmpcfg_q[7], pmpcfg_q[6], pmpcfg_q[5], pmpcfg_q[4],
                              pmpcfg_q[3], pmpcfg_q[2], pmpcfg_q[1], pmpcfg_q[0]};
      kronos_pkg::CSR_PMPCFG2: rdata_o = {pmpcfg_q[15], pmpcfg_q[14], pmpcfg_q[13], pmpcfg_q[12],
                              pmpcfg_q[11], pmpcfg_q[10], pmpcfg_q[9],  pmpcfg_q[8]};
      12'h3B0: rdata_o = {10'd0, pmpaddr_q[0]};
      12'h3B1: rdata_o = {10'd0, pmpaddr_q[1]};
      12'h3B2: rdata_o = {10'd0, pmpaddr_q[2]};
      12'h3B3: rdata_o = {10'd0, pmpaddr_q[3]};
      12'h3B4: rdata_o = {10'd0, pmpaddr_q[4]};
      12'h3B5: rdata_o = {10'd0, pmpaddr_q[5]};
      12'h3B6: rdata_o = {10'd0, pmpaddr_q[6]};
      12'h3B7: rdata_o = {10'd0, pmpaddr_q[7]};
      12'h3B8: rdata_o = {10'd0, pmpaddr_q[8]};
      12'h3B9: rdata_o = {10'd0, pmpaddr_q[9]};
      12'h3BA: rdata_o = {10'd0, pmpaddr_q[10]};
      12'h3BB: rdata_o = {10'd0, pmpaddr_q[11]};
      12'h3BC: rdata_o = {10'd0, pmpaddr_q[12]};
      12'h3BD: rdata_o = {10'd0, pmpaddr_q[13]};
      12'h3BE: rdata_o = {10'd0, pmpaddr_q[14]};
      12'h3BF: rdata_o = {10'd0, pmpaddr_q[15]};
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
      // S-mode CSRs
      kronos_pkg::CSR_STVEC:      rdata_o = {stvec[63:2], 2'b00};
      kronos_pkg::CSR_SSCRATCH:   rdata_o = sscratch;
      kronos_pkg::CSR_SEPC:       rdata_o = {sepc[63:1], 1'b0};
      kronos_pkg::CSR_SCAUSE:     rdata_o = scause;
      kronos_pkg::CSR_STVAL:      rdata_o = stval;
      kronos_pkg::CSR_SATP:       rdata_o = satp;
      kronos_pkg::CSR_SCOUNTEREN: rdata_o = {32'd0, scounteren};
      kronos_pkg::CSR_SENVCFG:    rdata_o = senvcfg;
      // SSTATUS: S-visible bits + SD computed from FS (mstatus[63] is never
      // written; the SD bit must be derived from FS == 2'b11 just like the
      // master mstatus read above).
      kronos_pkg::CSR_SSTATUS:    rdata_o = {(mstatus[14:13] == 2'b11),
                                  63'(mstatus[62:0] & SSTATUS_RD_MASK)};
      kronos_pkg::CSR_SIE:        rdata_o = mie & SMODE_IRQ_MASK;            // SSIE/STIE/SEIE
      kronos_pkg::CSR_SIP:        rdata_o = (mip | mip_sw) & SMODE_IRQ_MASK;
      default: rdata_o = trig_csr_match_i ? trig_csr_rdata_i : 64'hDEAD_C5A0_DEAD_C5A0;
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
  assign fp_csr_sw_write  = req_i &
                           (addr_i == 12'h001
                          | addr_i == 12'h002
                          | addr_i == 12'h003);
  assign trig_csr_we_o    = req_i & trig_csr_match_i & (funct3_i[1:0] != 2'b00);
  assign trig_csr_wdata_o = csr_new_val;
  // re-derive mstatus/sstatus SD bit (bit 63) from the *new* FS so
  // the retire trace matches Sail's post-write CSR read view. csr_new_val uses
  // rdata_o (SD computed from old FS) OR'd with the operand — correct for the
  // architectural write (mstatus_q discards bit 63 anyway), but the trace needs
  // the post-write read view.
  assign csr_new_val_o     = ((addr_i == 12'h300) || (addr_i == 12'h100))
                             ? {(csr_new_val[14:13] == 2'b11), csr_new_val[62:0]}
                             : csr_new_val;

  // -------------------------------------------------------------------------
  // counter-access gating (mcounteren / scounteren)
  // -------------------------------------------------------------------------
  // S-mode access to addresses 0xC00..0xC1F (cycle/time/instret/hpmcounter3..31)
  // is gated by mcounteren[idx]; U-mode access is additionally gated by
  // scounteren[idx].  Bit clear ⇒ illegal-instruction trap.  M-mode is never
  // gated.  Counter-en covers both reads and explicit-write attempts (the
  // latter trap on read-only write violations regardless, but the spec gates
  // the access itself).
  always_comb begin
    counter_access_illegal = 1'b0;
    if (req_i && (addr_i[11:5] == 7'b1100000)) begin // 0xC00..0xC1F
      if (priv_q == PRIV_S) begin
        counter_access_illegal = ~mcounteren[addr_i[4:0]];
      end else if (priv_q == PRIV_U) begin
        counter_access_illegal = ~mcounteren[addr_i[4:0]] | ~scounteren[addr_i[4:0]];
      end
    end
  end

  // -------------------------------------------------------------------------
  // CSR-access privilege check (Privileged Spec § 2.1)
  // -------------------------------------------------------------------------
  // CSR address bits [9:8] encode the minimum privilege required to access the
  // CSR.  Any access where priv_q < addr_i[9:8] is illegal-instruction.  The
  // reserved encoding 2'b10 is treated as M-mode for safety.
  always_comb begin
    // Defaults (rule R7).
    priv_check_fail = 1'b0;
    required_priv   = addr_i[9:8];                   // CSR addr bits [9:8] = min priv
    // Treat reserved 2'b10 same as M for safety.
    min_priv        = (required_priv == 2'b10) ? PRIV_M : priv_e'(required_priv);
    if (req_i) begin
      priv_check_fail = (priv_q < min_priv);
    end
  end

  assign csr_illegal_o = counter_access_illegal | priv_check_fail;

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus  <= 64'h0000_0000_0000_1800; // MPP=11, FS=00 (Off) — matches Sail; common.S sets FS=Dirty in prologue
      mie      <= {kronos_pkg::XLEN{1'b0}};
      mtvec    <= {kronos_pkg::XLEN{1'b0}};
      mscratch <= {kronos_pkg::XLEN{1'b0}};
      mepc     <= {kronos_pkg::XLEN{1'b0}};
      mcause   <= {kronos_pkg::XLEN{1'b0}};
      mtval    <= {kronos_pkg::XLEN{1'b0}};
      medeleg  <= {kronos_pkg::XLEN{1'b0}};
      mideleg  <= {kronos_pkg::XLEN{1'b0}};
      mip_sw   <= {kronos_pkg::XLEN{1'b0}};
      fcsr_q   <= 8'h00;
      mcycle   <= {kronos_pkg::XLEN{1'b0}};
      minstret <= {kronos_pkg::XLEN{1'b0}};
      mcountinhibit <= 11'b0;
      mcounteren    <= 32'b0;
      priv_q   <= PRIV_M;
      // S-mode CSRs reset
      stvec       <= {kronos_pkg::XLEN{1'b0}};
      sscratch    <= {kronos_pkg::XLEN{1'b0}};
      sepc        <= {kronos_pkg::XLEN{1'b0}};
      scause      <= {kronos_pkg::XLEN{1'b0}};
      stval       <= {kronos_pkg::XLEN{1'b0}};
      satp        <= {kronos_pkg::XLEN{1'b0}};
      scounteren  <= 32'b0;
      senvcfg     <= {kronos_pkg::XLEN{1'b0}};
      for (int i = 3; i <= 10; i++) begin
        mhpmcounter[i] <= {kronos_pkg::XLEN{1'b0}};
        mhpmevent[i]   <= 8'b0;
      end
      // PMP reset — all regions OFF (A=00) and unlocked.
      for (int i = 0; i < 16; i++) begin
        pmpcfg_q[i]  <= 8'h00;
        pmpaddr_q[i] <= 54'b0;
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
                              & ~(req_i & (addr_i == 12'(12'hB00 + i)))) begin
          mhpmcounter[i] <= mhpmcounter[i] + 64'd1;
        end
      end

      // Trap entry / xRET state update.  trap_i takes priority over mret/sret;
      // the if/else-if chain enforces that ordering.
      if (trap_i) begin
        if (delegate_to_s) begin
          // Trap delegated to S-mode.
          sepc           <= {32'b0, trap_pc_i};
          scause         <= {32'b0, trap_cause_i};
          stval          <= {32'b0, trap_tval_i};
          mstatus[5]     <= mstatus[1];        // SPIE = SIE
          mstatus[1]     <= 1'b0;              // SIE  = 0
          mstatus[8]     <= priv_q[0];         // SPP  = priv_q[0]  (S=>1, U=>0)
          priv_q         <= PRIV_S;
        end else begin
          // Trap taken to M-mode (default).
          mepc           <= {32'b0, trap_pc_i};
          mcause         <= {32'b0, trap_cause_i};
          mtval          <= {32'b0, trap_tval_i};
          mstatus[7]     <= mstatus[3];        // MPIE = MIE
          mstatus[3]     <= 1'b0;              // MIE  = 0
          mstatus[12:11] <= priv_q;            // MPP  = priv_q
          priv_q         <= PRIV_M;
        end
      end
      // MRET: restore interrupt state and privilege from MPP.  Per Priv §
      // 3.1.6.3, when xPP != M the xRET also clears MPRV.
      else if (mret_i) begin
        mstatus[3]     <= mstatus[7]; // MIE = MPIE
        mstatus[7]     <= 1'b1;       // MPIE = 1
        priv_q         <= priv_e'(mstatus[12:11]);
        mstatus[12:11] <= PRIV_U;
        if (mstatus[12:11] != PRIV_M) mstatus[17] <= 1'b0;  // MPRV cleared
      end
      // SRET: SIE/SPIE swap, SPP cleared, privilege restored from SPP.  SRET
      // always returns to S or U (never M), so MPRV is unconditionally cleared.
      else if (sret_i) begin
        mstatus[1]   <= mstatus[5];           // SIE  ← SPIE
        mstatus[5]   <= 1'b1;                 // SPIE ← 1
        mstatus[8]   <= 1'b0;                 // SPP  ← U
        mstatus[17]  <= 1'b0;                 // MPRV cleared (SPP is never M)
        priv_q       <= priv_e'({1'b0, mstatus[8]});
      end
      // CSR write (overrides default counter tick on the same cycle)
      if (req_i) begin
        unique case (addr_i)
          12'h001: fcsr_q[4:0] <= csr_new_val[4:0];
          12'h002: fcsr_q[7:5] <= csr_new_val[2:0];
          12'h003: fcsr_q      <= csr_new_val[7:0];
          12'h300: begin
            // Stage 6a-implemented bits: SIE(1), MIE(3), SPIE(5), MPIE(7), SPP(8),
            // MPP(12:11), FS(14:13), MPRV(17), SUM(18), MXR(19), TVM(20), TW(21),
            // TSR(22). FS is software-controllable for FP context-switch tracking.
            // XS(16:15) and SD(63) are managed by hardware — preserve them.
            mstatus <= (mstatus     & ~MSTATUS_M_MASK)
                     | (csr_new_val &  MSTATUS_M_MASK);
          end
          // medeleg WARL: bits 0..15 writable except bit 11 (M-ecall, hardwired 0);
          // bits 14 and 16+ also hardwired 0.
          kronos_pkg::CSR_MEDELEG: medeleg <= csr_new_val & MEDELEG_MASK;
          // mideleg WARL: only SSIE/STIE/SEIE delegation bits writable.
          kronos_pkg::CSR_MIDELEG: mideleg <= csr_new_val & SMODE_IRQ_MASK;
          12'h304: mie      <= csr_new_val;
          12'h305: mtvec    <= csr_new_val;
          kronos_pkg::CSR_MCOUNTEREN: mcounteren <= csr_new_val[31:0];
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
          12'h343: mtval    <= csr_new_val;
          // mip: software-writable bits land in mip_sw shadow.  From M-mode
          // SSIP/STIP/SEIP are writable; from S-mode (via 0x344 isn't legal,
          // but if reached) only SSIP would be — the privilege check is in
          // the decode/illegal-instr path, so here we accept all three bits.
          12'h344: mip_sw <= (mip_sw & ~SMODE_IRQ_MASK)
                           | (csr_new_val & SMODE_IRQ_MASK);
          // PMP cfg writes (pmpcfg0/pmpcfg2).  Per-byte WARL:
          //  - L=1 ⇒ drop write to that byte AND its paired pmpaddr.
          //  - A=01 (TOR) collapses to A=00 (OFF) — Stage 6 supports OFF/NAPOT only.
          //  - WPRI bits [6:5] read 0.
          kronos_pkg::CSR_PMPCFG0: begin
            for (int i = 0; i < 8; i++) begin
              if (~pmpcfg_q[i][7]) begin
                // WARL: WPRI bits [6:5] clear; A=01 (TOR) collapses to A=00 (OFF).
                pmpcfg_q[i][7]   <=  csr_new_val[i*8 + 7];                        // L
                pmpcfg_q[i][6:5] <=  2'b00;                                       // WPRI
                pmpcfg_q[i][4:3] <= (csr_new_val[i*8 + 4 -: 2] == 2'b01)
                                    ? 2'b00 : csr_new_val[i*8 + 4 -: 2];          // A
                pmpcfg_q[i][2:0] <=  csr_new_val[i*8 +: 3];                       // X/W/R
              end
            end
          end
          kronos_pkg::CSR_PMPCFG2: begin
            for (int i = 0; i < 8; i++) begin
              if (~pmpcfg_q[i+8][7]) begin
                // WARL: WPRI bits [6:5] clear; A=01 (TOR) collapses to A=00 (OFF).
                pmpcfg_q[i+8][7]   <=  csr_new_val[i*8 + 7];                      // L
                pmpcfg_q[i+8][6:5] <=  2'b00;                                     // WPRI
                pmpcfg_q[i+8][4:3] <= (csr_new_val[i*8 + 4 -: 2] == 2'b01)
                                      ? 2'b00 : csr_new_val[i*8 + 4 -: 2];        // A
                pmpcfg_q[i+8][2:0] <=  csr_new_val[i*8 +: 3];                     // X/W/R
              end
            end
          end
          // pmpaddr0..15: 54-bit PA[55:2]; lock-aware.
          12'h3B0: if (~pmpcfg_q[0][7]) pmpaddr_q[0] <= csr_new_val[53:0];
          12'h3B1: if (~pmpcfg_q[1][7]) pmpaddr_q[1] <= csr_new_val[53:0];
          12'h3B2: if (~pmpcfg_q[2][7]) pmpaddr_q[2] <= csr_new_val[53:0];
          12'h3B3: if (~pmpcfg_q[3][7]) pmpaddr_q[3] <= csr_new_val[53:0];
          12'h3B4: if (~pmpcfg_q[4][7]) pmpaddr_q[4] <= csr_new_val[53:0];
          12'h3B5: if (~pmpcfg_q[5][7]) pmpaddr_q[5] <= csr_new_val[53:0];
          12'h3B6: if (~pmpcfg_q[6][7]) pmpaddr_q[6] <= csr_new_val[53:0];
          12'h3B7: if (~pmpcfg_q[7][7]) pmpaddr_q[7] <= csr_new_val[53:0];
          12'h3B8: if (~pmpcfg_q[8][7])  pmpaddr_q[8]  <= csr_new_val[53:0];
          12'h3B9: if (~pmpcfg_q[9][7])  pmpaddr_q[9]  <= csr_new_val[53:0];
          12'h3BA: if (~pmpcfg_q[10][7]) pmpaddr_q[10] <= csr_new_val[53:0];
          12'h3BB: if (~pmpcfg_q[11][7]) pmpaddr_q[11] <= csr_new_val[53:0];
          12'h3BC: if (~pmpcfg_q[12][7]) pmpaddr_q[12] <= csr_new_val[53:0];
          12'h3BD: if (~pmpcfg_q[13][7]) pmpaddr_q[13] <= csr_new_val[53:0];
          12'h3BE: if (~pmpcfg_q[14][7]) pmpaddr_q[14] <= csr_new_val[53:0];
          12'h3BF: if (~pmpcfg_q[15][7]) pmpaddr_q[15] <= csr_new_val[53:0];
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
          // S-mode CSRs
          kronos_pkg::CSR_STVEC:      stvec       <= {csr_new_val[63:2], 2'b00};
          kronos_pkg::CSR_SSCRATCH:   sscratch    <= csr_new_val;
          kronos_pkg::CSR_SEPC:       sepc        <= {csr_new_val[63:1], 1'b0};
          kronos_pkg::CSR_SCAUSE:     scause      <= csr_new_val;
          kronos_pkg::CSR_STVAL:      stval       <= csr_new_val;
          kronos_pkg::CSR_SATP: begin
            // WARL on MODE.  Only Bare/Sv39/Sv48 are supported; on
            // any other MODE the *entire* write is dropped (per priv-spec WARL
            // rules — we choose to keep the legal previous value rather than
            // accept a partially-modified satp).
            if (csr_new_val[63:60] == kronos_pkg::SATP_MODE_BARE |
                csr_new_val[63:60] == kronos_pkg::SATP_MODE_SV39 |
                csr_new_val[63:60] == kronos_pkg::SATP_MODE_SV48) begin
              satp <= csr_new_val;
            end
          end
          kronos_pkg::CSR_SCOUNTEREN: scounteren  <= csr_new_val[31:0];
          kronos_pkg::CSR_SENVCFG:    /* WARL=0 in 6a; ignore writes */ ;
          kronos_pkg::CSR_SSTATUS: begin
            // Only S-visible bits writable; preserve the rest of mstatus.
            mstatus <= (mstatus & ~SSTATUS_RW_MASK)
                     | (csr_new_val & SSTATUS_RW_MASK);
          end
          kronos_pkg::CSR_SIE: begin
            mie <= (mie & ~SMODE_IRQ_MASK)
                 | (csr_new_val & SMODE_IRQ_MASK);
          end
          kronos_pkg::CSR_SIP: begin
            // S-mode view of mip: only SSIP (bit 1) is writable from S-mode.
            // Land the write in the mip_sw shadow register; the kronos_pkg::CSR_SIP read
            // path returns (mip | mip_sw) masked to the S-visible bits.
            // M-mode software can write SSIP/STIP/SEIP via 0x344 above.
            mip_sw <= (mip_sw & ~64'h0000_0000_0000_0002)
                    | (csr_new_val & 64'h0000_0000_0000_0002);
          end
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
