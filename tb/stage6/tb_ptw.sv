// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_ptw.sv — Stage 6b unit testbench for kronos_ptw.
// Drives the PTW against an in-TB associative-array memory model holding
// hand-built page tables.  Covers Sv39 walks at all leaf levels, Sv48 walks,
// invalid/reserved/misaligned PTEs, permission faults, A-bit hardware update
// via LR/SC, and SC-fail retry.

`timescale 1ns/1ps

module tb_ptw;
  import kronos_pkg::*;

  // -------------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  // -------------------------------------------------------------------------
  // PTW signals
  // -------------------------------------------------------------------------
  logic [3:0]  satp_mode;
  logic [15:0] satp_asid;
  logic [43:0] satp_ppn;
  logic        itlb_miss, dtlb_miss;
  logic [63:0] itlb_va, dtlb_va;
  logic        dtlb_is_load, dtlb_is_store;
  priv_e       miss_priv;
  logic        sum_in, mxr_in;
  logic        itlb_rfv, dtlb_rfv;
  logic [1:0]  rf_size;
  logic [35:0] rf_vpn;
  logic [43:0] rf_ppn;
  logic [15:0] rf_asid;
  logic        rf_global;
  logic [3:0]  rf_perm;
  logic        rf_a, rf_d;
  logic        pf_o;
  logic [4:0]  pf_cause;
  logic [63:0] pf_tval;
  tlb_op_e     pf_which;
  logic        dc_req_v;
  logic [55:0] dc_req_addr;
  logic        dc_req_we;
  logic [63:0] dc_req_wdata;
  logic [2:0]  dc_req_size;
  logic        dc_req_lr, dc_req_sc;
  logic        dc_rsp_v;
  logic [63:0] dc_rsp_rdata;
  logic        dc_rsp_sc_ok;
  logic        busy;

  // SC-fail injection knob (used by test 10).  Driven only by the TB initial
  // block; cleared by the TB after observing the first failed SC response.
  logic        force_sc_fail;

  // Memory model storage and busy flop.
  bit [kronos_pkg::XLEN-1:0] mem [logic [55:0]];
  logic          dc_busy_q;  // 1 = response delivered for current req pulse

  // Test bookkeeping and per-test scratch (declared module-top per coding
  // guidelines — no mid-block logic declarations).
  int          errors = 0;
  logic        refilled;
  logic        faulted;
  logic [55:0] leaf_addr;
  logic [63:0] before_pte;
  int          timeout_ix;
  int          sc_seen;

  kronos_ptw u_dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .satp_mode_i          (satp_mode),
    .satp_asid_i          (satp_asid),
    .satp_ppn_i           (satp_ppn),
    .itlb_miss_i          (itlb_miss),
    .itlb_miss_va_i       (itlb_va),
    .dtlb_miss_i          (dtlb_miss),
    .dtlb_miss_va_i       (dtlb_va),
    .dtlb_miss_is_load_i  (dtlb_is_load),
    .dtlb_miss_is_store_i (dtlb_is_store),
    .miss_priv_i          (miss_priv),
    .sum_i                (sum_in),
    .mxr_i                (mxr_in),
    .itlb_refill_valid_o  (itlb_rfv),
    .dtlb_refill_valid_o  (dtlb_rfv),
    .refill_size_o        (rf_size),
    .refill_vpn_o         (rf_vpn),
    .refill_ppn_o         (rf_ppn),
    .refill_asid_o        (rf_asid),
    .refill_global_o      (rf_global),
    .refill_perm_o        (rf_perm),
    .refill_a_o           (rf_a),
    .refill_d_o           (rf_d),
    .page_fault_o         (pf_o),
    .page_fault_cause_o   (pf_cause),
    .page_fault_tval_o    (pf_tval),
    .page_fault_which_o   (pf_which),
    .dcache_req_valid_o   (dc_req_v),
    .dcache_req_addr_o    (dc_req_addr),
    .dcache_req_we_o      (dc_req_we),
    .dcache_req_wdata_o   (dc_req_wdata),
    .dcache_req_size_o    (dc_req_size),
    .dcache_req_is_lr_o   (dc_req_lr),
    .dcache_req_is_sc_o   (dc_req_sc),
    .dcache_rsp_valid_i   (dc_rsp_v),
    .dcache_rsp_rdata_i   (dc_rsp_rdata),
    .dcache_rsp_sc_ok_i   (dc_rsp_sc_ok),
    .busy_o               (busy)
  );

  // -------------------------------------------------------------------------
  // Memory model — sparse associative array.  Single-outstanding: at most
  // one response per req=1 pulse.  rsp_v pulses for one cycle on the
  // response; rdata and sc_ok are held until the next response so the FSM
  // can examine them in its WAIT states.  SC succeeds unless force_sc_fail
  // is set; the TB clears force_sc_fail after observing the first failed SC
  // so the retry can succeed.
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dc_rsp_v     <= 1'b0;
      dc_rsp_rdata <= 64'h0;
      dc_rsp_sc_ok <= 1'b0;
      dc_busy_q    <= 1'b0;
    end else begin
      // rsp_v is a 1-cycle pulse; rdata/sc_ok hold their values.
      dc_rsp_v <= 1'b0;

      if (!dc_req_v) begin
        // Req dropped — ready to handle the next pulse.
        dc_busy_q <= 1'b0;
      end else if (!dc_busy_q) begin
        // First cycle of a new request — fire one response.
        dc_busy_q <= 1'b1;
        dc_rsp_v  <= 1'b1;
        if (dc_req_we) begin
          // SC path.
          if (force_sc_fail) begin
            dc_rsp_sc_ok <= 1'b0;
          end else begin
            mem[dc_req_addr] = dc_req_wdata;
            dc_rsp_sc_ok    <= 1'b1;
          end
          dc_rsp_rdata <= 64'h0;
        end else begin
          dc_rsp_rdata <= mem.exists(dc_req_addr) ? mem[dc_req_addr] : 64'd0;
        end
      end
      // else: busy, request still asserted — no further response.
    end
  end

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  task automatic clear_inputs;
    itlb_miss     = 1'b0;
    dtlb_miss     = 1'b0;
    itlb_va       = 64'h0;
    dtlb_va       = 64'h0;
    dtlb_is_load  = 1'b0;
    dtlb_is_store = 1'b0;
    miss_priv     = PRIV_S;
    sum_in        = 1'b0;
    mxr_in        = 1'b0;
    satp_mode     = kronos_pkg::SATP_MODE_SV39;
    satp_asid     = 16'd1;
    satp_ppn      = 44'h0_0001_0000;  // root table at PA 0x0001_0000_0000_0000
  endtask

  task automatic set_pte(input logic [55:0] addr, input logic [63:0] pte);
    mem[addr] = pte;
  endtask

  // Build a leaf PTE: V=1, perm={U,X,W,R}, G, A, D, PPN.
  function automatic logic [63:0] mk_leaf(input logic [43:0] ppn,
                                           input logic [3:0]  perm,
                                           input logic        g,
                                           input logic        a,
                                           input logic        d);
    return {10'b0, ppn, 2'b0, d, a, g, perm, 1'b1};
  endfunction

  // Pointer PTE: V=1, R=W=X=0, points to next-level PA.
  function automatic logic [63:0] mk_pointer(input logic [43:0] next_ppn);
    return {10'b0, next_ppn, 2'b0, 1'b0, 1'b0, 1'b0, 4'b0, 1'b1};
  endfunction

  task automatic kick_load_miss(input logic [63:0] va);
    @(posedge clk);
    dtlb_miss     = 1'b1;
    dtlb_va       = va;
    dtlb_is_load  = 1'b1;
    dtlb_is_store = 1'b0;
    miss_priv     = PRIV_S;
    @(posedge clk);
    dtlb_miss     = 1'b0;
    dtlb_is_load  = 1'b0;
  endtask

  task automatic wait_done(output logic refilled_o, output logic faulted_o);
    refilled_o = 1'b0;
    faulted_o  = 1'b0;
    repeat (100) begin
      @(posedge clk);
      if (dtlb_rfv | itlb_rfv) refilled_o = 1'b1;
      if (pf_o)                faulted_o  = 1'b1;
      if (refilled_o | faulted_o) return;
    end
  endtask

  task automatic check(input string n, input logic c);
    if (!c) begin
      $display("FAIL %s", n);
      errors++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------
  initial begin
    force_sc_fail = 1'b0;
    clear_inputs;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 1 — Sv39 4 KB leaf at lvl-0
    // VA = 0x0300_4000  →  VPN[2]=0, VPN[1]=0x18 (offset 0xC0),
    //                       VPN[0]=0x4 (offset 0x20).
    // satp_ppn=0x0_0001_0000 → root_table_pa = 0x0000_0010_0000_0000.
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0000, mk_pointer(44'h0_0002_0000));
    set_pte(56'h00_0000_2000_00C0, mk_pointer(44'h0_0003_0000));
    set_pte(56'h00_0000_3000_0020,
            mk_leaf(44'h0_000A_BCDE, 4'b0_011, 1'b0, 1'b1, 1'b0));

    kick_load_miss(64'h0000_0000_0300_4000);
    wait_done(refilled, faulted);
    check("T1 Sv39 4K leaf refilled",   refilled & ~faulted & dtlb_rfv);
    check("T1 Sv39 4K size = 4K",       rf_size == 2'd0);
    check("T1 Sv39 4K PPN = ABCDE",     rf_ppn  == 44'h0_000A_BCDE);
    check("T1 Sv39 4K A set on refill", rf_a);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 2 — Sv39 leaf at lvl-1 (2 MB megapage)
    // VA chosen so VPN[2]=1, VPN[1]=0x101.
    //   VA = (1<<30) | (0x101<<21) = 0x0000_0000_6020_0000.
    // root[1] points at L1 table at PPN 0x0_0010_0000;
    // L1[0x101] is leaf (PPN[8:0] must be zero for a 2 MB megapage).
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0008, mk_pointer(44'h0_0010_0000));
    set_pte(56'h00_0001_0000_0808,
            mk_leaf(44'h0_0010_0000, 4'b0_011, 1'b0, 1'b1, 1'b0));

    kick_load_miss(64'h0000_0000_6020_0000);
    wait_done(refilled, faulted);
    check("T2 Sv39 2M leaf refilled", refilled & ~faulted);
    check("T2 Sv39 2M size = 2M",     rf_size == 2'd1);
    check("T2 Sv39 2M PPN",           rf_ppn  == 44'h0_0010_0000);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 3 — Sv39 leaf at lvl-2 (1 GB gigapage)
    // VA = 0x8000_0000  →  VPN[2]=2, leaf at root[2] (offset 0x10).
    // PPN[17:0] must be zero for a 1 GB gigapage.
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0010,
            mk_leaf(44'h0_0008_0000, 4'b0_011, 1'b0, 1'b1, 1'b0));

    kick_load_miss(64'h0000_0000_8000_0000);
    wait_done(refilled, faulted);
    check("T3 Sv39 1G leaf refilled", refilled & ~faulted);
    check("T3 Sv39 1G size = 1G",     rf_size == 2'd2);
    check("T3 Sv39 1G PPN",           rf_ppn  == 44'h0_0008_0000);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 4 — Sv48 leaf at lvl-0
    // satp.MODE = Sv48.  Walk descends 4 levels.
    // VA = 0x8040_2010_00 chosen so VPN[3..0] = {1,1,1,1}.
    // root (lvl-3) PPN = satp_ppn = 0x0_0001_0000;
    // L1 (lvl-2)  PPN = 0x0_0020_0000;
    // L2 (lvl-1)  PPN = 0x0_0030_0000;
    // L3 (lvl-0)  PPN = 0x0_0040_0000.
    // ----------------------------------------------------------------------
    satp_mode = kronos_pkg::SATP_MODE_SV48;

    // root[1] (Sv48 lvl-3, VPN[3]=1) → pointer to L1 table.
    set_pte(56'h00_0000_1000_0008, mk_pointer(44'h0_0020_0000));
    // L1[1] (lvl-2, VPN[2]=1) → pointer to L2 table.
    set_pte(56'h00_0002_0000_0008, mk_pointer(44'h0_0030_0000));
    // L2[1] (lvl-1, VPN[1]=1) → pointer to L3 table.
    set_pte(56'h00_0003_0000_0008, mk_pointer(44'h0_0040_0000));
    // L3[1] (lvl-0, VPN[0]=1) → leaf, PPN = 0x0_00BE_EF00.
    set_pte(56'h00_0004_0000_0008,
            mk_leaf(44'h0_00BE_EF00, 4'b0_011, 1'b0, 1'b1, 1'b0));

    kick_load_miss(64'h0000_0080_4020_1000);
    wait_done(refilled, faulted);
    check("T4 Sv48 4K leaf refilled", refilled & ~faulted);
    check("T4 Sv48 4K size = 4K",     rf_size == 2'd0);
    check("T4 Sv48 4K PPN",           rf_ppn  == 44'h0_00BE_EF00);
    repeat (4) @(posedge clk);

    // Switch back to Sv39 for remaining tests.
    satp_mode = kronos_pkg::SATP_MODE_SV39;

    // ----------------------------------------------------------------------
    // Test 5 — Invalid PTE (V=0)
    // VA chosen so VPN[2]=3 → root[3] at offset 0x18.
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0018, 64'h0);  // V=0
    kick_load_miss(64'h0000_0000_C000_0000);  // VPN[2]=3
    wait_done(refilled, faulted);
    check("T5 invalid PTE -> page-fault", faulted & ~refilled);
    check("T5 cause = LOAD_PAGE_FAULT",   pf_cause == kronos_pkg::CAUSE_LOAD_PAGE_FAULT);
    check("T5 tval = original VA",        pf_tval == 64'h0000_0000_C000_0000);
    check("T5 which = TLB_LOAD",          pf_which == TLB_LOAD);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 6 — Reserved encoding (V=1, R=0, W=1)
    // VA picks a fresh slot: VPN[2]=4 → root[4] at offset 0x20.
    // V=1, R=0, W=1, X=1 makes it reserved per § 5.4
    // → bit pattern: V|W|X = bits 0,2,3 = 0x0D.
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0020, 64'h0000_0000_0000_000D);
    kick_load_miss(64'h0000_0001_0000_0000);  // VPN[2]=4
    wait_done(refilled, faulted);
    check("T6 reserved enc -> page-fault", faulted & ~refilled);
    check("T6 cause = LOAD_PAGE_FAULT",    pf_cause == kronos_pkg::CAUSE_LOAD_PAGE_FAULT);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 7 — Misaligned superpage
    // VA: VPN[2]=5, VPN[1]=0 → root[5] offset 0x28 → pointer; L1[0] is a
    // leaf at lvl-1 with PPN[8:0] != 0 (PPN = 0x0_0001_0001 — bit 0 set
    // means the megapage is misaligned).
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0028, mk_pointer(44'h0_0050_0000));
    set_pte(56'h00_0005_0000_0000,
            mk_leaf(44'h0_0001_0001, 4'b0_011, 1'b0, 1'b1, 1'b0));
    kick_load_miss(64'h0000_0001_4000_0000);  // VPN[2]=5, VPN[1]=0
    wait_done(refilled, faulted);
    check("T7 misaligned superpage -> page-fault", faulted & ~refilled);
    check("T7 cause = LOAD_PAGE_FAULT", pf_cause == kronos_pkg::CAUSE_LOAD_PAGE_FAULT);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 8 — Permission fault: U=1 leaf accessed in S-mode without SUM.
    // Per § 4.4.1 / SUM bit, S-mode loads from U-pages page-fault when SUM=0.
    // VA: VPN[2]=6, VPN[1]=0, VPN[0]=0 → root[6] offset 0x30, leaf at lvl-0.
    // ----------------------------------------------------------------------
    set_pte(56'h00_0000_1000_0030, mk_pointer(44'h0_0060_0000));
    set_pte(56'h00_0006_0000_0000, mk_pointer(44'h0_0061_0000));
    // perm = {U,X,W,R} = 4'b1_011 → U=1, R=1, W=1.
    set_pte(56'h00_0006_1000_0000,
            mk_leaf(44'h0_0001_2300, 4'b1_011, 1'b0, 1'b1, 1'b1));
    sum_in = 1'b0;  // S-mode w/o SUM access to U-page → fault
    kick_load_miss(64'h0000_0001_8000_0000);  // VPN[2]=6
    wait_done(refilled, faulted);
    check("T8 U-page in S w/o SUM -> page-fault", faulted & ~refilled);
    check("T8 cause = LOAD_PAGE_FAULT", pf_cause == kronos_pkg::CAUSE_LOAD_PAGE_FAULT);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 9 — A=0 path (HW set via LR/SC).  Verify mem[leaf] gets A=1 after
    // the SC, and that the refill arrives.
    // VA: VPN[2]=7, VPN[1]=0, VPN[0]=0 → root[7] offset 0x38, leaf at lvl-0.
    // ----------------------------------------------------------------------
    leaf_addr = 56'h00_0007_0000_0000;
    set_pte(56'h00_0000_1000_0038, mk_pointer(44'h0_0070_0000));
    // perm = {U,X,W,R} = 4'b0_011 (S-accessible R/W), A=0.
    set_pte(leaf_addr,
            mk_leaf(44'h0_00CA_FE00, 4'b0_011, 1'b0, 1'b0, 1'b0));
    before_pte = mem[leaf_addr];
    check("T9 leaf A=0 before walk", ((before_pte >> kronos_pkg::PTE_A_BIT) & 64'd1) == 64'd0);

    kick_load_miss(64'h0000_0001_C000_0000);  // VPN[2]=7
    wait_done(refilled, faulted);
    check("T9 A-set walk refilled",     refilled & ~faulted);
    check("T9 A=1 in mem after SC",
          ((mem[leaf_addr] >> kronos_pkg::PTE_A_BIT) & 64'd1) == 64'd1);
    check("T9 PPN preserved",
          mem[leaf_addr][53:10] == 44'h0_00CA_FE00);
    check("T9 PPN refilled",            rf_ppn == 44'h0_00CA_FE00);
    repeat (4) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 10 — SC-fail retry.  First SC fails; PTW returns to IDLE, sees the
    // still-asserted dtlb_miss, restarts the walk, second SC succeeds.
    // VA: VPN[2]=8, VPN[1]=0, VPN[0]=0 → root[8] offset 0x40, leaf at lvl-0.
    // ----------------------------------------------------------------------
    leaf_addr = 56'h00_0008_0000_0000;
    set_pte(56'h00_0000_1000_0040, mk_pointer(44'h0_0080_0000));
    // Leaf is at lvl-1 (2 MB megapage); PPN[8:0] must be 0 for alignment.
    set_pte(leaf_addr,
            mk_leaf(44'h0_00DE_A000, 4'b0_011, 1'b0, 1'b0, 1'b0));

    // Arm the SC-fail injection knob.  The TB clears it as soon as the
    // first failed SC response is delivered (then the retry succeeds).
    force_sc_fail = 1'b1;
    sc_seen       = 0;

    // Drive a held miss so the FSM, on returning to IDLE after the failed
    // SC, immediately picks the request up again.
    @(posedge clk);
    dtlb_miss     = 1'b1;
    dtlb_va       = 64'h0000_0002_0000_0000;  // VPN[2]=8
    dtlb_is_load  = 1'b1;
    dtlb_is_store = 1'b0;
    miss_priv     = PRIV_S;

    // Wait up to 400 cycles for refill (two walks + LR/SC each).
    refilled = 1'b0;
    faulted  = 1'b0;
    for (timeout_ix = 0; timeout_ix < 400; timeout_ix++) begin
      @(posedge clk);
      // Drop the SC-fail injection the cycle after we observe the first
      // SC completing (with sc_ok=0).  Gated on dc_req_sc & dc_rsp_v to
      // avoid being fooled by the LR response that precedes the SC.
      if (force_sc_fail & dc_req_sc & dc_rsp_v & (sc_seen == 0)) begin
        sc_seen       = 1;
        force_sc_fail = 1'b0;
      end
      if (dtlb_rfv) refilled = 1'b1;
      if (pf_o)     faulted  = 1'b1;
      if (refilled | faulted) break;
    end
    // Drop miss now that the walk has resolved.
    dtlb_miss    = 1'b0;
    dtlb_is_load = 1'b0;

    check("T10 SC-fail retry refilled", refilled & ~faulted);
    check("T10 PPN refilled",           rf_ppn == 44'h0_00DE_A000);
    check("T10 A=1 in mem",
          ((mem[leaf_addr] >> kronos_pkg::PTE_A_BIT) & 64'd1) == 64'd1);
    check("T10 saw an SC-fail event",   sc_seen == 1);
    repeat (4) @(posedge clk);

    if (errors == 0) $display("tb_ptw: PASS");
    else             $display("tb_ptw: FAIL %0d", errors);
    $finish;
  end

  // Hard timeout (any test stuck > 5000 cycles fails the run).
  initial begin
    repeat (5000) @(posedge clk);
    $display("tb_ptw: TIMEOUT");
    $finish;
  end

endmodule
