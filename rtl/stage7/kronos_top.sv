// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stage 7a top: in-order issue, out-of-order completion via 16-entry ROB.
// Single-issue dispatch. FPU + muldiv complete asynchronously into the ROB.
// ALU/LSU/CSR/branch share an in-pipe completion port. Side-effect
// instructions (stores, CSR, AMO/LR/SC, fences, mret/sret) wait for
// is_at_rob_head before firing.
module kronos_top
  import kronos_pkg::*;
(
  input  logic             clk_i,
  input  logic             rst_ni,

  // Instruction fetch port (AXI4 read-only master)
  output kronos_axi_req_t  instr_axi_req_o,
  input  kronos_axi_resp_t instr_axi_rsp_i,

  // Data port (AXI4 read/write master)
  output kronos_axi_req_t  data_axi_req_o,
  input  kronos_axi_resp_t data_axi_rsp_i,

  input  logic             irq_timer_i,
  input  logic [14:0]      irq_fast_i,
  // Stage 6a: standard RISC-V interrupt inputs (priv-spec § 3.1.9).
  // Default-driven 0 by SoC integrations that have not yet been updated;
  // the legacy irq_timer_i / irq_fast_i platform IRQ ports remain operational.
  input  logic             irq_msi_i,
  input  logic             irq_mei_i,
  input  logic             irq_ssi_i,
  input  logic             irq_sti_i,
  input  logic             irq_sei_i,
  input  logic [31:0]      boot_addr_i,

  // ----------------------------------------------------------------------
  // Debug/trace outputs (simulation-only; unconnected in synthesis targets).
  // Expose committed instruction state for Sail differential tracing.
  // Driven from mem_wb_q in the cycle it advances past WB.
  // ----------------------------------------------------------------------
  output logic        retire_valid_o,
  output logic [63:0] retire_pc_o,
  output logic [31:0] retire_instr_o,
  output logic        retire_rd_wen_o,
  output logic [4:0]  retire_rd_o,
  output logic [63:0] retire_rd_wdata_o,
  output logic        retire_fp_wen_o,
  output logic [4:0]  retire_fp_rd_o,
  output logic [63:0] retire_fp_wdata_o,
  output logic        retire_mem_wen_o,
  output logic [63:0] retire_mem_addr_o,
  output logic [63:0] retire_mem_wdata_o,
  output logic [2:0]  retire_mem_funct3_o,
  output logic        retire_csr_wen_o,
  output logic [11:0] retire_csr_addr_o,
  output logic [63:0] retire_csr_wdata_o,
  // Trap-taken pulse: high for one cycle on trap entry (debug/coverage only).
  output logic        retire_trap_taken_o,
  output logic [31:0] retire_trap_cause_o
);

  // -------------------------------------------------------------------------
  // Pipeline registers
  // -------------------------------------------------------------------------
  if_id_reg_t  if_id_q;
  id_ex_reg_t  id_ex_q;
  ex_mem_reg_t ex_mem_q;
  logic [31:0] pc_q                              /* verilator public_flat_rd */;

  // Stage 7a: rob_idx carried per in-pipe instruction (not in the struct to
  // avoid touching shared kronos_pkg pipeline-reg types used by stage1-6).
  rob_idx_t    id_ex_rob_idx_q;
  rob_idx_t    ex_mem_rob_idx_q;

  // -------------------------------------------------------------------------
  // Pipeline enable/flush control (derived inline — hazard module removed)
  // -------------------------------------------------------------------------
  logic      pc_en, if_id_en, id_ex_en, ex_mem_en;
  logic      if_id_flush, id_ex_flush;

  // -------------------------------------------------------------------------
  // ID-stage wires
  // -------------------------------------------------------------------------
  decoded_instr_t id_dec;
  logic [63:0]    rs1_rdata_64, rs2_rdata_64;
  logic [63:0]    rs1_data_id, rs2_data_id, rs3_data_id;

  // Stage 5a: FP regfile read ports
  logic [63:0]    fp_rd1 /* verilator public_flat_rd */, fp_rd2 /* verilator public_flat_rd */, fp_rd3;

  // Stage 5a: CSR frm output
  logic [2:0]     frm;

  // Stage 7a: ID-stage ROB-keyed bypass data and stall signals
  logic [63:0]    rs1_int_data, rs2_int_data;
  logic [63:0]    rs1_fp_data,  rs2_fp_data;
  logic           rs1_int_stall, rs2_int_stall;
  logic           rs1_fp_stall,  rs2_fp_stall;
  logic           operand_stall                  /* verilator public_flat_rd */;

  // Stage 7a: drain mode for serialising ops
  logic           drain_mode_q                   /* verilator public_flat_rd */;

  // Stage 7a: dispatch control
  logic           dispatch_can_fire;

  // Stage 7a: integer and FP data forwarded for FP-rs3 (FMA)
  logic [63:0]    rs3_fp_data;

  // -------------------------------------------------------------------------
  // EX-stage wires (64-bit datapath)
  // -------------------------------------------------------------------------
  logic [63:0] fwd_rs1_data, fwd_rs2_data;
  logic [63:0] alu_a, alu_b, alu_result;
  logic [63:0] ex_result;
  logic [31:0] ex_pc_next                        /* verilator public_flat_rd */;
  logic        ex_redirect                        /* verilator public_flat_rd */;
  logic        branch_taken;
  logic        irq_pending;
  logic [4:0]  irq_cause;
  logic [63:0] csr_rdata;
  logic [63:0] trap_vector, mepc, sepc;
  logic [31:0] trap_cause                        /* verilator public_flat_rd */;
  logic [63:0] jalr_target_64;

  // Stage 6a: privilege state + protection wires.
  priv_e             priv_q;
  logic [63:0]       mstatus;
  logic              pmp_fetch_fault;
  logic [55:0]       pmp_fetch_fault_addr;
  logic              pmp_data_fault;
  logic [55:0]       pmp_data_fault_addr;
  logic [15:0][7:0]  pmpcfg;
  logic [15:0][53:0] pmpaddr;
  logic [31:0]       trap_tval;
  logic              csr_illegal;
  // Stage 6a: priv-checked control transfers (mret/sret) and TVM/TW gates.
  logic              mret_priv_fail;
  logic              sret_priv_fail;
  logic              satp_tvm_fail;
  // Stage 6a: PMP data-port size_i (3-bit log2 width: 0=1B,1=2B,2=4B,3=8B).
  logic [2:0]        pmp_data_size;

  // -------------------------------------------------------------------------
  // Stage 6b: TLB / PTW / translation-control wires.
  //
  // Two TLB lookups happen each cycle (fetch + data); both query the active
  // satp.MODE and decide whether translation is enabled (Bare → no translate;
  // Sv39/Sv48 → translate when effective priv is not M).  Translation faults
  // (TLB-perm-fail or PTW page-fault) drive the trap chain alongside the PMP
  // fault paths from Stage 6a.
  // -------------------------------------------------------------------------
  logic        itlb_hit, itlb_perm_fail, itlb_a_zero, itlb_d_zero;
  logic [55:0] itlb_pa;
  logic        dtlb_hit, dtlb_perm_fail, dtlb_a_zero, dtlb_d_zero;
  logic [55:0] dtlb_pa;
  logic        itlb_miss, dtlb_miss;
  logic        ptw_busy, ptw_pf;
  logic [4:0]  ptw_pf_cause;
  logic [63:0] ptw_pf_tval;
  tlb_op_e     ptw_pf_which;
  logic        ptw_dc_req_valid, ptw_dc_req_we, ptw_dc_req_lr, ptw_dc_req_sc;
  logic [55:0] ptw_dc_req_addr;
  logic [63:0] ptw_dc_req_wdata;
  logic [2:0]  ptw_dc_req_size;
  logic        ptw_itlb_rfv, ptw_dtlb_rfv;
  logic [1:0]  ptw_rf_size;
  logic [35:0] ptw_rf_vpn;
  logic [43:0] ptw_rf_ppn;
  logic [15:0] ptw_rf_asid;
  logic        ptw_rf_global;
  logic [3:0]  ptw_rf_perm;
  logic        ptw_rf_a, ptw_rf_d;
  logic        ptw_dc_rsp_valid, ptw_dc_rsp_sc_ok;
  logic [63:0] ptw_dc_rsp_rdata;
  logic [3:0]  satp_mode;
  logic [15:0] satp_asid;
  logic [43:0] satp_ppn;
  priv_e       eff_priv_data;
  logic        translate_data, translate_fetch;
  logic        sfence_vma, sfence_va_valid, sfence_asid_valid;
  logic [63:0] sfence_va;
  logic [15:0] sfence_asid;
  logic        wfi_priv_fail_q;
  logic        cross_page_fault;
  logic [31:0] eff_fetch_pa, eff_data_pa;
  // Stage 6b: aggregate page-fault routing.
  logic        instr_page_fault, load_page_fault, store_page_fault;
  // Stage 6b: registered data-port PA (VA→PA happens in EX, LSU consumes it
  // one stage later in MEM).  Kept alongside ex_mem_q.alu_result so the trace
  // continues to report the architectural VA in retire_mem_addr_o.
  logic [31:0] ex_mem_data_pa_q;

  // STAGE2: muldiv signals (64-bit)
  logic [63:0] muldiv_result;
  logic        muldiv_valid, muldiv_idle;
  logic        muldiv_stall;
  rob_idx_t    muldiv_rob_idx_out;
  logic        muldiv_complete_stall;

  // Fix #3: pre-registered CSR-select flag for EX forwarding mux.
  // Registered at the EX→MEM boundary; eliminates the 3-bit wb_sel compare
  // from the FWD_EXMEM combinational path.
  logic        ex_mem_csr_q;

  // STAGE3: fetch control (icache replaces old FSM)
  logic         fetch_flush;
  logic         instr_fetch_stall               /* verilator public_flat_rd */;
  // Stage 7a: combined_stall still exists but is driven differently
  // (no forwarding stall; ROB-bypass stall is operand_stall).
  logic         combined_stall                  /* verilator public_flat_rd */;
  logic         combined_stall_no_muldiv;

  // Stage 7a: ROB / busy table wires
  rob_entry_t                  dispatch_entry;
  rob_idx_t                    dispatch_idx;
  logic                        dispatch_fire              /* verilator public_flat_rd */;
  logic                        rob_full                   /* verilator public_flat_rd */;
  logic                        rob_empty;
  rob_entry_t [ROB_DEPTH-1:0]  rob_q;
  logic [ROB_DEPTH-1:0]        is_at_rob_head;
  rob_idx_t                    rob_head, rob_tail;

  logic                        compA_fire;
  rob_idx_t                    compA_idx;
  logic [63:0]                 compA_result;
  logic [63:0]                 compA_csr_new_val;
  logic                        compA_trap_taken;
  logic [4:0]                  compA_trap_cause;
  logic [63:0]                 compA_tval;
  logic                        compA_actual_taken;
  logic [31:0]                 compA_actual_target;
  logic                        compA_mispredict;
  logic [63:0]                 compA_mem_addr;
  logic [63:0]                 compA_mem_wdata;
  logic [2:0]                  compA_mem_funct3;

  logic                        compB_fire;
  rob_idx_t                    compB_idx;
  logic [63:0]                 compB_result;
  logic [4:0]                  compB_fflags;

  logic                        commit_fire;
  rob_entry_t                  commit_entry;
  rob_idx_t                    commit_idx;
  logic                        commit_block;

  logic                        branch_flush;
  rob_idx_t                    branch_flush_idx;
  logic                        trap_flush;

  busy_entry_t                 rs1_int_busy, rs2_int_busy, rs1_fp_busy, rs2_fp_busy;

  // Stage 7a: LSU/CSR at-head gate
  logic lsu_at_head;
  logic csr_at_head;

  // I-cache interface signals
  logic        icache_data_valid;
  logic [31:0] icache_data;
  logic        icache_stall;
  logic        icache_miss_pulse                 /* verilator public_flat_rd */;
  logic        fence_i_pulse;
  logic        fence_i_pulse_raw;
  logic        fence_i_active_q                 /* verilator public_flat_rd */;
  logic        dcache_flush_done;
  logic        dcache_dirty_pending;

  // STAGE3: C extension — alignment unit signals
  logic [31:0] align_instr                       /* verilator public_flat_rd */;
  logic        align_instr_valid                 /* verilator public_flat_rd */;
  logic        align_is_16b;
  logic        align_stall;
  logic        align_need_upper;
  logic        align_needs_fetch;

  // STAGE3: branch predictor
  logic        pred_taken;
  logic [31:0] pred_target;
  logic        bpred_update_en;
  logic        actual_taken;
  logic        bpred_mispredict                  /* verilator public_flat_rd */;
  logic        bpred_mispredict_target; // MEM-stage: predicted target ≠ actual target
  logic        mem_redirect                      /* verilator public_flat_rd */;
  logic        is_branch_or_jump;
  // Debug helpers — mirror id_ex_q fields for Verilator tracing
  logic        dbg_ex_valid                      /* verilator public_flat_rd */;
  logic        dbg_ex_pred_taken                 /* verilator public_flat_rd */;
  logic        dbg_align_is_16b                  /* verilator public_flat_rd */;
  assign dbg_ex_valid      = id_ex_q.valid;
  assign dbg_ex_pred_taken = id_ex_q.pred_taken;
  assign dbg_align_is_16b  = align_is_16b;

  // STAGE5a: FRM/FCSR RAW hazard detection signals (declared later in logic section)

  // -------------------------------------------------------------------------
  // MEM-stage wires (64-bit lsu data)
  // -------------------------------------------------------------------------
  logic [63:0]      lsu_rdata;
  logic             lsu_valid;
  logic             mem_stall                    /* verilator public_flat_rd */;
  logic             lsu_mem_stall;
  // mem_done_q: set when LSU signals valid_o; cleared when MEM/WB register
  // advances.  Gates req_i so LSU does not re-issue while the pipeline is
  // frozen by instr_fetch_stall.
  logic             mem_done_q;
  logic [63:0]      lsu_rdata_latch;  // holds rdata across the stall gap
  logic             amo_write_latch;  // holds is_amo_write across the stall gap

  // D-cache interface (LSU ↔ dcache)
  logic        dcache_req;
  logic [63:0] dcache_addr;
  logic [2:0]  dcache_size;
  logic        dcache_we;
  logic [63:0] dcache_wdata;
  logic        dcache_amo_req;
  logic [4:0]  dcache_amo_op;
  logic        dcache_data_valid;
  logic [63:0] dcache_rdata;
  logic        dcache_sc_success;
  logic        dcache_stall                      /* verilator public_flat_rd */;
  logic        dcache_miss_pulse                 /* verilator public_flat_rd */;

  // Stage 5a: LSU FP response
  logic             lsu_fp_dest;
  logic [63:0]      lsu_fp_rdata;

  // -------------------------------------------------------------------------
  // Stage 5a: FPU wires
  // -------------------------------------------------------------------------
  logic       fpu_out_valid;
  logic [63:0] fpu_result;
  logic [4:0]  fpu_fflags;
  fpu_tag_t    fpu_tag_out;
  logic        fpu_busy;
  fpu_tag_t    fpu_tag_in;
  rob_idx_t    fpu_rob_idx_out;

  // Stage 7a: FPU is dispatched from ID (dispatch_fire & id_dec.is_fp)
  logic        fpu_in_valid /* verilator public_flat_rd */;
  logic        fpu_fmt_d   /* verilator public_flat_rd */;
  assign fpu_fmt_d = id_dec.fmt_d;

  // Stage 5h event taxonomy (re-derived for event bus)
  logic load_use_event;
  logic fp_load_use_event;
  logic jalr_fwd_event;

  // Stage 5h: Sdtrig (trigger module) interface
  logic        trig_hit;
  logic [31:0] trig_hit_pc;
  logic [63:0] trig_csr_rdata;
  logic        trig_csr_match;
  logic        trig_csr_we;
  logic [63:0] trig_csr_wdata;

  // Stage 6c: post-write CSR value from u_csr (captured into compA at MEM completion)
  logic [63:0] csr_new_val_post;
  logic [63:0] ex_mem_csr_new_val_q;

  // ---- Stage 5c/e performance-counter event bus ----
  logic        bpred_mispredict_pulse;
  logic        fpu_busy_any;
  logic        trap_taken_pulse                  /* verilator public_flat_rd */;
  logic [31:0] event_bus                        /* verilator public_flat_rd */;

  // FPU operand muxes: for integer-source FP instructions.
  // In stage7a, these come from the ID-stage bypass data (rs1_int_data / rs2_int_data).
  logic [63:0] fpu_a_i /* verilator public_flat_rd */, fpu_b_i /* verilator public_flat_rd */;

  // FP regfile write port signals (driven at commit)
  logic        fp_we;
  logic [4:0]  fp_wa;
  logic [63:0] fp_wd;

  // -------------------------------------------------------------------------
  // PC next (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] pc_next                           /* verilator public_flat_rd */;

  // =========================================================================
  // Submodule instantiations
  // =========================================================================

  kronos_decode u_decode (
    .instr_i        (if_id_q.instr),
    .frm_i          (frm),
    .decoded_o      (id_dec),
    .illegal_insn_o ()               // mirrored into id_dec.illegal; unused here
  );

  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (id_dec.rs1),
    .rs2_addr_i  (id_dec.rs2),
    .rs1_rdata_o (rs1_rdata_64),
    .rs2_rdata_o (rs2_rdata_64),
    // Stage 7a: int regfile writes happen at commit, not WB.
    .rd_addr_i   (commit_entry.dec.rd),
    .rd_wen_i    (commit_fire & commit_entry.dec.rd_wen & ~commit_entry.dec.rd_fp
                  & ~commit_entry.trap_taken & (commit_entry.dec.rd != 5'd0)),
    .rd_wdata_i  (commit_entry.result)
  );

  // Stage 5a: FP register file
  kronos_regfile_fp u_regfile_fp (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .ra1_i   (id_dec.rs1),
    .rd1_o   (fp_rd1),
    .ra2_i   (id_dec.rs2),
    .rd2_o   (fp_rd2),
    .ra3_i   (id_dec.rs3),
    .rd3_o   (fp_rd3),
    .wa_i    (fp_wa),
    .wd_i    (fp_wd),
    .we_i    (fp_we)
  );

  // Stage 7a: kronos_forward and kronos_hazard removed.
  // Forwarding is replaced by ROB-keyed bypass at ID (see operand resolution below).
  // Hazard signals are re-derived inline.
  // muldiv_stall: in-pipe muldiv is now dispatched at ID to the muldiv unit;
  // the in-pipe stall applies when muldiv sits in EX (id_ex_q.dec.is_muldiv).
  // In stage7a, muldiv is dispatched OoO like FPU so this stall should be 0
  // when the in-pipe doesn't hold muldiv. Keep for compatibility if it somehow lands.
  assign muldiv_stall      = 1'b0;  // muldiv dispatched OoO in stage7a
  // Stage 6a: when a PMP fetch fault is active, the alignment unit suppresses
  // its instr_valid_o (see kronos_align.sv).  We must NOT treat this as a
  // pipeline stall, because the same fault asserts trap_i and ex_redirect to
  // the trap vector — gating pc_en off via instr_fetch_stall would prevent the
  // PC from reaching mtvec, and the pipeline would resume executing at the
  // faulting PC in M-mode instead of taking the trap.
  assign instr_fetch_stall = (~align_instr_valid & ~pmp_fetch_fault) | icache_stall;

  // FENCE.I detection from raw instruction bits (decoder doesn't surface it —
  // see commit 87aac14 for why we don't change the decoder).
  // FENCE.I: opcode = 7'b0001111, funct3 = 3'b001.
  //
  // Raw decode: fires whenever a FENCE.I sits in EX without a stall.  When
  // the D-cache holds dirty lines, we must drain them (writeback to AXI)
  // before the I-cache flush takes effect — otherwise self-modifying code
  // sees stale instruction bytes.  fence_i_active_q stalls the pipeline
  // until the D-cache reports flush_done; only then does fence_i_pulse fire
  // for one cycle (driving the I-cache flush and letting FENCE.I retire).
  // fence_i_pulse_raw: FENCE.I sits in EX with no non-mem stall.  We do NOT
  // include mem_stall here because mem_stall must depend combinationally on
  // this signal (to assert the stall the same cycle FENCE.I enters EX) —
  // including mem_stall would form a combinational loop.
  // Stage 7a: FENCE.I is a serialising op dispatched OoO to in-pipe only when
  // it is at the ROB head (drain mode + at_head). The raw pulse fires when
  // the instruction is in EX and the pipeline is advancing.
  assign fence_i_pulse_raw = id_ex_q.valid &
                             ~lsu_mem_stall & ~instr_fetch_stall &
                             (id_ex_q.instr[6:0]   == 7'b0001111) &
                             (id_ex_q.instr[14:12] == 3'b001);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      fence_i_active_q <= 1'b0;
    else if (fence_i_pulse_raw & dcache_dirty_pending & ~fence_i_active_q)
      fence_i_active_q <= 1'b1;
    else if (dcache_flush_done)
      fence_i_active_q <= 1'b0;
  end

  assign fence_i_pulse = fence_i_pulse_raw &
                         (~dcache_dirty_pending | dcache_flush_done);

  // Stage 7a: event taxonomy (simplified — OoO events tracked differently)
  assign load_use_event    = 1'b0;  // load-use stall replaced by ROB operand stall
  assign fp_load_use_event = 1'b0;
  assign jalr_fwd_event    = 1'b0;

  // Stage 7a: combined_stall — no FPU stall (FPU now OoO); no muldiv stall.
  // Driven by mem_stall (LSU busy) + instr_fetch_stall + dtlb_miss.
  assign combined_stall_no_muldiv = mem_stall | instr_fetch_stall
                                  | (id_ex_q.valid & dtlb_miss &
                                     ~load_page_fault & ~store_page_fault);
  assign combined_stall    = combined_stall_no_muldiv;

  // FRM/FCSR RAW hazard: a CSR write to FRM/FCSR in EX will update fcsr_q at
  // Stage 7a: FRM/FCSR RAW hazard — still needed. A CSR write to FRM/FCSR in EX
  // will update fcsr_q at posedge, but decode reads frm combinatorially.
  // With drain-mode serialisation this is handled by draining before FP dispatch,
  // but we keep the detection signals for the event bus.
  logic id_ex_is_frm_write;
  logic if_id_fp_dyn_rm;
  assign id_ex_is_frm_write = id_ex_q.valid & id_ex_q.dec.is_csr &
                               (id_ex_q.dec.csr_addr == 12'h002 |  // FRM
                                id_ex_q.dec.csr_addr == 12'h003);  // FCSR
  assign if_id_fp_dyn_rm    = if_id_q.valid &
                               (if_id_q.instr[14:12] == 3'b111) &
                               (if_id_q.instr[6:0] == 7'b1010011 |  // OP-FP
                                if_id_q.instr[6:0] == 7'b1000011 |  // FMADD
                                if_id_q.instr[6:0] == 7'b1000111 |  // FMSUB
                                if_id_q.instr[6:0] == 7'b1001011 |  // FNMSUB
                                if_id_q.instr[6:0] == 7'b1001111);  // FNMADD

  // Stage 7a: pipeline enable/flush signals (previously from kronos_hazard).
  // Rules:
  //  - dispatch_fire replaces the old id_ex_en condition (ID advances only when
  //    dispatch fires). But for non-dispatch stall (combined_stall from LSU/fetch),
  //    the in-pipe must also stall.
  //  - ex_redirect / mem_redirect flush younger stages AND must be allowed to
  //    update pc_q (redirect target) even when dispatch_stall is asserted.
  //    Keeping ~ex_redirect / ~mem_redirect in pc_en blocks the redirect and
  //    leaves the fetch stream pointed at the wrong PC after the flush.
  //  - dispatch stall: holds IF/ID when dispatch cannot fire.
  logic dispatch_stall;
  assign dispatch_stall = if_id_q.valid & ~dispatch_fire;

  assign pc_en     = ~combined_stall & (~dispatch_stall | ex_redirect | mem_redirect);
  assign if_id_en  = ~combined_stall & ~dispatch_stall;
  assign id_ex_en  = ~combined_stall;
  assign ex_mem_en = ~combined_stall;

  // Gate in-pipe redirects with ~combined_stall: when the pipeline is stalled
  // (icache miss, LSU stall), the stall takes priority over flush.  Flushing
  // while stalled drives fetch_flush → alignment unit flush → align_instr_valid=0
  // → instr_fetch_stall=1 → combined_stall stays 1 forever (deadlock).
  //
  // branch_flush is ROB-driven (from bpred_mispredict_target at MEM stage) and
  // accompanies a mem_redirect, so the alignment unit's pc_offset_i is already
  // correct via the mem_redirect path — it can be unconditional.
  //
  // trap_flush is intentionally NOT included here.  In stage7a the CSR trap
  // handling and the PC redirect to trap_vector happen at EX time (via
  // ex_redirect=1), so the alignment unit and IF/ID stage are already flushed
  // with the correct pc_offset_i at that point.  trap_flush fires later at ROB
  // commit time when the pipeline is executing correct trap-handler instructions;
  // re-flushing then would corrupt the alignment unit state and skip instructions
  // (see Bug 4 / compA_trap_taken fix above).
  assign if_id_flush = branch_flush
                     | (~combined_stall & (ex_redirect | mem_redirect));
  assign id_ex_flush = branch_flush
                     | (~combined_stall & (ex_redirect | mem_redirect));

  kronos_alu u_alu (
    .op_i      (id_ex_q.dec.alu_op),
    .a_i       (alu_a),
    .b_i       (alu_b),
    .word_op_i (id_ex_q.dec.is_word_op),
    .result_o  (alu_result)
  );

  // Stage 7a: muldiv is dispatched from ID (dispatch_fire & id_dec.is_muldiv).
  // It receives the ROB index at dispatch and returns it with the result.
  kronos_muldiv u_muldiv (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .req_i            (dispatch_fire & id_dec.is_muldiv & muldiv_idle),
    .op_i             (id_dec.muldiv_op),
    .a_i              (rs1_int_data),
    .b_i              (rs2_int_data),
    .word_op_i        (id_dec.is_word_op),
    .rob_idx_i        (dispatch_idx),
    .complete_stall_i (muldiv_complete_stall),
    .result_o         (muldiv_result),
    .busy_o           (),
    .valid_o          (muldiv_valid),
    .idle_o           (muldiv_idle),
    .rob_idx_o        (muldiv_rob_idx_out)
  );

  assign ex_result = alu_result;  // muldiv no longer in-pipe in stage7a

  // Stage 7a: CSR at-head gate
  assign csr_at_head = is_at_rob_head[ex_mem_rob_idx_q];

  // MISA_EXT = I + M + A + C + F + D extension bits (bits 8,12,0,2,5,3) = 26'h112D
  kronos_csr #(.MISA_EXT(26'h112D)) u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .req_i         (id_ex_q.valid & id_ex_q.dec.is_csr & ~combined_stall),
    .at_head_i     (csr_at_head),
    .addr_i        (id_ex_q.dec.csr_addr),
    .funct3_i      (id_ex_q.dec.csr_funct3),
    .use_imm_i     (id_ex_q.dec.csr_use_imm),
    .rs1_data_i    (fwd_rs1_data),
    .rs1_addr_i    (id_ex_q.dec.rs1),
    .rdata_o       (csr_rdata),
    .valid_o       (),
    // Gate trap_i and mret_i with ~combined_stall: CSR must only update state
    // when the pipeline is actually advancing (see stage3 comment for details).
    .trap_i        ((id_ex_q.valid & ~combined_stall &
                     (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                      id_ex_q.dec.illegal  | csr_illegal |
                      mret_priv_fail | sret_priv_fail | satp_tvm_fail |
                      wfi_priv_fail_q |
                      irq_pending | trig_hit)) |
                    pmp_fetch_fault | pmp_data_fault |
                    instr_page_fault | load_page_fault | store_page_fault),
    .trap_pc_i     (id_ex_q.pc),
    .trap_cause_i  (trap_cause),
    .trap_tval_i   (trap_tval),
    .mret_i        (id_ex_q.valid & ~combined_stall &
                    id_ex_q.dec.is_mret & ~mret_priv_fail),
    .sret_i        (id_ex_q.valid & ~combined_stall &
                    id_ex_q.dec.is_sret & ~sret_priv_fail),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .sepc_o        (sepc),
    .priv_o        (priv_q),
    .mstatus_o     (mstatus),
    .csr_illegal_o (csr_illegal),
    .pmpcfg_o      (pmpcfg),
    .pmpaddr_o     (pmpaddr),
    .irq_timer_i   (irq_timer_i),
    .irq_fast_i    (irq_fast_i),
    .irq_msi_i     (irq_msi_i),
    .irq_mei_i     (irq_mei_i),
    .irq_ssi_i     (irq_ssi_i),
    .irq_sti_i     (irq_sti_i),
    .irq_sei_i     (irq_sei_i),
    .irq_pending_o (irq_pending),
    .irq_cause_o   (irq_cause),
    // Stage 5a: FP CSR interface — fflags written at commit from ROB entry
    .fflags_delta_i (commit_entry.fflags),
    .fflags_we_i    (commit_fire & commit_entry.dec.is_fp),
    .fp_rd_we_i     (fp_we),                // drives mstatus.FS=11 on FP writeback
    .frm_o          (frm),
    // Zicntr: count at commit boundary
    .instret_retire_i (commit_fire),
    .event_bus_i      (event_bus),
    // Stage 5h
    .trig_csr_rdata_i (trig_csr_rdata),
    .trig_csr_match_i (trig_csr_match),
    .trig_csr_we_o    (trig_csr_we),
    .trig_csr_wdata_o (trig_csr_wdata),
    .csr_new_val_o    (csr_new_val_post),
    // Stage 6b: SFENCE.VMA passthrough (decode → CSR → both TLBs).
    .sfence_vma_i        (sfence_vma),
    .sfence_va_i         (sfence_va),
    .sfence_asid_i       (sfence_asid),
    .sfence_va_valid_i   (sfence_va_valid),
    .sfence_asid_valid_i (sfence_asid_valid),
    .sfence_vma_o        (),  // mirrored into local sfence_vma; unused here
    .sfence_va_o         (),
    .sfence_asid_o       (),
    .sfence_va_valid_o   (),
    .sfence_asid_valid_o (),
    // Stage 6b: satp fields broken out for the address-translation engine.
    .satp_mode_o         (satp_mode),
    .satp_asid_o         (satp_asid),
    .satp_ppn_o          (satp_ppn)
  );

  kronos_trigger u_trigger (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .csr_req_i     (id_ex_q.valid & id_ex_q.dec.is_csr & ~combined_stall),
    .csr_addr_i    (id_ex_q.dec.csr_addr),
    .csr_we_i      (trig_csr_we),
    .csr_wdata_i   (trig_csr_wdata),
    .csr_rdata_o   (trig_csr_rdata),
    .csr_match_o   (trig_csr_match),
    .ex_valid_i    (id_ex_q.valid & ~combined_stall),
    .ex_pc_i       (id_ex_q.pc),
    .ex_is_load_i  (id_ex_q.dec.is_load),
    .ex_is_store_i (id_ex_q.dec.is_store),
    .ex_mem_addr_i (alu_result),
    .hit_o         (trig_hit),
    .hit_pc_o      (trig_hit_pc)
  );

  // -------------------------------------------------------------------------
  // Stage 6a: PMP — fetch-port and data-port instances.
  //
  // Each kronos_pmp consumes a 56-bit physical address.  Stage 6a uses a
  // 32-bit physical address space, so we zero-extend.  size_i is the log2
  // byte size of the access (0=1B, 1=2B, 2=4B, 3=8B).  The fetch port always
  // queries a 4-byte access; the data port mirrors the LSU's funct3→size
  // translation.
  //
  // valid_i is gated so the fault flag is only meaningful while the access
  // is being presented to the bus.  For data accesses we additionally gate
  // on ~combined_stall to avoid driving fault_o while the pipeline is frozen
  // for unrelated reasons (otherwise a multi-cycle stall would cause repeated
  // edge-triggered traps in the trap_taken_pulse).
  // -------------------------------------------------------------------------
  always_comb begin
    unique case (id_ex_q.dec.mem_funct3)
      3'b000:  pmp_data_size = 3'd0; // LB / SB
      3'b001:  pmp_data_size = 3'd1; // LH / SH
      3'b010:  pmp_data_size = 3'd2; // LW / SW / FLW / FSW
      3'b011:  pmp_data_size = 3'd3; // LD / SD / FLD / FSD
      3'b100:  pmp_data_size = 3'd0; // LBU
      3'b101:  pmp_data_size = 3'd1; // LHU
      3'b110:  pmp_data_size = 3'd2; // LWU
      default: pmp_data_size = 3'd3;
    endcase
  end

  // PMP enforcement gate: when *no* PMP entry has cfg.A != OFF the PMP is
  // effectively not configured.  RISC-V Priv §3.7.1 makes the number of
  // implemented entries implementation-defined and explicitly permits zero.
  // Treating the all-OFF state as "PMP not implemented" lets early-boot S/U
  // code execute without first programming a wide-open region (the in-tree
  // priv tests rely on this).  The kronos_pmp module itself stays spec-strict
  // (S/U fault on no-match) so tb_pmp's directed cases keep their meaning;
  // the gate lives here at integration level only.
  logic pmp_any_active;
  always_comb begin
    pmp_any_active = 1'b0;
    for (int i = 0; i < 16; i++) begin
      if (pmpcfg[i][4:3] != 2'b00) pmp_any_active = 1'b1;
    end
  end

  logic pmp_fetch_fault_raw;
  logic [55:0] pmp_fetch_fault_addr_raw;
  logic pmp_data_fault_raw;
  logic [55:0] pmp_data_fault_addr_raw;

  kronos_pmp #(.N(16)) u_pmp_fetch (
    .pmpcfg_i     (pmpcfg),
    .pmpaddr_i    (pmpaddr),
    .priv_i       (priv_q),
    // Fetch valid: any cycle the icache is presenting a fetch address.
    .valid_i      (align_needs_fetch),
    .addr_i       ({24'b0, icache_fetch_addr}),
    .size_i       (3'd2),  // 4-byte fetch (lower bound; align reads upper word
                            // when needed via icache_fetch_addr remap).
    .is_fetch_i   (1'b1),
    .is_load_i    (1'b0),
    .is_store_i   (1'b0),
    .fault_o      (pmp_fetch_fault_raw),
    .fault_addr_o (pmp_fetch_fault_addr_raw)
  );

  assign pmp_fetch_fault      = pmp_fetch_fault_raw & pmp_any_active;
  assign pmp_fetch_fault_addr = pmp_fetch_fault_addr_raw;

  kronos_pmp #(.N(16)) u_pmp_data (
    .pmpcfg_i     (pmpcfg),
    .pmpaddr_i    (pmpaddr),
    .priv_i       (priv_q),
    // valid_i must NOT depend on combined_stall.  combined_stall includes
    // mem_stall, which depends on lsu_mem_stall, which depends on pmp_fault_i
    // (suppressed by lsu when pmp_fault_i is high) — gating valid_i on
    // ~combined_stall would close a comb loop pmp_fault → mem_stall →
    // combined_stall → valid_i → pmp_fault.  The fault flag is meaningful
    // whenever a load/store sits in EX; the trap path gates trap_i with
    // ~combined_stall so the trap only fires when the pipeline advances.
    .valid_i      (id_ex_q.valid &
                   (id_ex_q.dec.is_load | id_ex_q.dec.is_store |
                    id_ex_q.dec.is_amo)),
    // alu_result is the (rs1+imm) memory address before the EX/MEM register.
    .addr_i       ({24'b0, alu_result[31:0]}),
    .size_i       (pmp_data_size),
    .is_fetch_i   (1'b0),
    .is_load_i    (id_ex_q.dec.is_load |
                   (id_ex_q.dec.is_amo & id_ex_q.dec.is_lr)),
    .is_store_i   (id_ex_q.dec.is_store |
                   (id_ex_q.dec.is_amo & ~id_ex_q.dec.is_lr)),
    .fault_o      (pmp_data_fault_raw),
    .fault_addr_o (pmp_data_fault_addr_raw)
  );

  assign pmp_data_fault      = pmp_data_fault_raw & pmp_any_active;
  assign pmp_data_fault_addr = pmp_data_fault_addr_raw;

  // -------------------------------------------------------------------------
  // Stage 6a: priv-checked control transfers.
  //   - mret legal only from M-mode.
  //   - sret legal from M (any) or S (when mstatus.TSR=0).  U-mode → illegal.
  //   - SATP CSR access from S-mode is gated by mstatus.TVM.
  //   - WFI privilege gating (mstatus.TW) is deferred to Stage 6b alongside
  //     the MMU; no `is_wfi` decode bit exists yet.
  // -------------------------------------------------------------------------
  always_comb begin
    mret_priv_fail = id_ex_q.dec.is_mret & (priv_q != PRIV_M);
    sret_priv_fail = id_ex_q.dec.is_sret &
                     ( (priv_q == PRIV_U) |
                       ((priv_q == PRIV_S) & mstatus[22]) );  // TSR
    satp_tvm_fail  = id_ex_q.dec.is_csr &
                     (id_ex_q.dec.csr_addr == CSR_SATP) &
                     (priv_q == PRIV_S) & mstatus[20];       // TVM
  end

  // -------------------------------------------------------------------------
  // Stage 6b: translation-enable + sfence pulse + wfi priv-fail.
  //
  // Per priv-spec § 4.4 (Sv39 / Sv48 translation):
  //   - Translation is active when satp.MODE != Bare AND effective_priv != M.
  //   - For data accesses, mstatus.MPRV (bit 17) replaces priv_q with
  //     mstatus.MPP (bits 12:11) when in M-mode.
  //   - For fetch, MPRV does not apply — always use priv_q.
  //
  // SFENCE.VMA pulses for one cycle when a SFENCE.VMA retires (id_ex_q.valid
  // & is_sfence_vma & ~combined_stall).  rs1==x0 sweeps all VAs; rs2==x0
  // sweeps all ASIDs.  fwd_rs1_data / fwd_rs2_data are the EX-stage forwarded
  // operands so a producer one stage ahead is bypassed correctly.
  //
  // WFI traps to illegal-instruction when mstatus.TW (bit 21) is set and the
  // current priv is not M (priv-spec § 3.1.6.5).  Stage 6b implements WFI as
  // a NOP in M-mode and as a priv-fail trap otherwise; no actual sleep.
  // -------------------------------------------------------------------------
  assign eff_priv_data    = (priv_q == PRIV_M & mstatus[17] /*MPRV*/)
                            ? priv_e'(mstatus[12:11]) : priv_q;
  assign translate_data   = (satp_mode != SATP_MODE_BARE) & (eff_priv_data != PRIV_M);
  assign translate_fetch  = (satp_mode != SATP_MODE_BARE) & (priv_q != PRIV_M);

  assign sfence_vma         = id_ex_q.valid & id_ex_q.dec.is_sfence_vma & ~combined_stall;
  assign sfence_va          = fwd_rs1_data;
  assign sfence_asid        = fwd_rs2_data[15:0];
  assign sfence_va_valid    = (id_ex_q.dec.rs1 != 5'd0);
  assign sfence_asid_valid  = (id_ex_q.dec.rs2 != 5'd0);

  assign wfi_priv_fail_q    = id_ex_q.valid & id_ex_q.dec.is_wfi &
                              (priv_q != PRIV_M) & mstatus[21] /*TW*/ & ~combined_stall;

  // -------------------------------------------------------------------------
  // Stage 6b: TLB-miss qualifiers.
  //
  // A miss is reported only when translation is active AND the lookup is being
  // presented to the TLB this cycle AND the TLB neither hit nor reported a
  // permission fault.  When a miss is asserted the LSU / I-cache stall their
  // own AXI activity (tlb_miss_i input), and the PTW kicks off a walk to fill
  // the TLB before the access is replayed.
  // -------------------------------------------------------------------------
  assign itlb_miss = translate_fetch & align_needs_fetch & ~itlb_hit & ~itlb_perm_fail;
  // Stage 6b: A/D-bit driven re-walks.  An entry that hits with A=0, or a
  // store whose entry hits with D=0, must trigger the PTW to atomically set
  // the missing bit before the access completes.  Folded into dtlb_miss so
  // the same stall + replay machinery is reused — the PTW re-walks the page
  // table, performs an LR/SC on the leaf PTE to set A (and D for stores),
  // and refills the dTLB with the updated entry.  kronos_tlb invalidates
  // matching entries on refill so the stale A=1/D=0 line cannot keep
  // answering lookups at a lower index.
  assign dtlb_miss = translate_data & id_ex_q.valid &
                     (id_ex_q.dec.is_load | id_ex_q.dec.is_store | id_ex_q.dec.is_amo) &
                     ((~dtlb_hit & ~dtlb_perm_fail) | dtlb_a_zero | dtlb_d_zero);

  // PA muxes — when translation is off (Bare or M-mode), forward the original
  // virtual address as-is (the architectural PA == VA).  Otherwise use the
  // TLB lookup output.  Stage 6b keeps a 32-bit physical address space, so
  // we slice the low 32 bits off the 56-bit TLB output.
  assign eff_fetch_pa = translate_fetch ? itlb_pa[31:0] : icache_fetch_addr;
  assign eff_data_pa  = translate_data  ? dtlb_pa[31:0] : alu_result[31:0];

  // Aggregate page-fault flags (TLB perm-fail OR PTW page-fault on the matching
  // tlb_op_e).  cross_page_fault is treated as an instruction page-fault.
  // kronos_align gates cross_page_fault_o on translate_fetch_i, so this signal
  // is automatically zero in M-mode / Bare and only fires under active
  // translation.
  assign instr_page_fault = itlb_perm_fail |
                            (ptw_pf & (ptw_pf_which == TLB_FETCH)) |
                            cross_page_fault;
  assign load_page_fault  = (dtlb_perm_fail | (ptw_pf & (ptw_pf_which == TLB_LOAD))) &
                            id_ex_q.dec.is_load;
  assign store_page_fault = (dtlb_perm_fail | (ptw_pf & (ptw_pf_which == TLB_STORE))) &
                            (id_ex_q.dec.is_store | id_ex_q.dec.is_amo);

  // STAGE5f / Stage7a: 64-bit LSU — thin adapter to kronos_dcache.
  kronos_lsu u_lsu (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_i              (ex_mem_q.valid & (ex_mem_q.dec.is_load | ex_mem_q.dec.is_store
                         | ex_mem_q.dec.is_amo) & ~mem_done_q),
    // Stage 6a: PMP data-port permission-violation flag.  Suppresses dcache
    // request issue and the AMO request when high.
    .pmp_fault_i        (pmp_data_fault),
    // Stage 6b: dTLB miss indicator — LSU stalls and suppresses dcache issue
    // until the PTW refills the dTLB and the access is replayed.
    .tlb_miss_i         (dtlb_miss),
    // Stage 7a: at-head gate — stores/AMO/LR/SC wait for ROB head
    .at_head_i          (lsu_at_head),
    .we_i               (ex_mem_q.dec.is_store | ex_mem_q.dec.fp_store),
    // Stage 6b: addr_i is the translated PA when satp.MODE != Bare and the
    // effective priv is not M; otherwise PA == VA (alu_result).  Captured at
    // the EX→MEM boundary by ex_mem_data_pa_q.
    .addr_i             (ex_mem_data_pa_q),
    .wdata_i            (ex_mem_q.rs2_data),
    .funct3_i           (ex_mem_q.dec.mem_funct3),
    .rdata_o            (lsu_rdata),
    .valid_o            (lsu_valid),
    .mem_stall_o        (lsu_mem_stall),
    // Stage 5a: FP load/store ports
    .fp_dest_req_i      (ex_mem_q.valid &
                         (ex_mem_q.dec.fp_load | ex_mem_q.dec.fp_store) & ~mem_done_q),
    .fp_store_data_i    (ex_mem_q.rs2_data),
    .fp_dest_rsp_o      (lsu_fp_dest),
    .fp_rdata_o         (lsu_fp_rdata),
    // A-extension
    .is_lr_i            (ex_mem_q.dec.is_lr),
    .is_sc_i            (ex_mem_q.dec.is_sc),
    .is_amo_i           (ex_mem_q.dec.is_amo),
    .amo_funct5_i       (ex_mem_q.dec.amo_funct5),
    .amo_src_i          (ex_mem_q.rs2_data),
    .sc_success_o       (),
    // D-cache interface
    .dcache_req_o       (dcache_req),
    .dcache_addr_o      (dcache_addr),
    .dcache_size_o      (dcache_size),
    .dcache_we_o        (dcache_we),
    .dcache_wdata_o     (dcache_wdata),
    .dcache_amo_req_o   (dcache_amo_req),
    .dcache_amo_op_o    (dcache_amo_op),
    .dcache_data_valid_i(dcache_data_valid),
    .dcache_rdata_i     (dcache_rdata),
    .dcache_sc_success_i(dcache_sc_success),
    .dcache_stall_i     (dcache_stall)
  );

  // mem_stall extends LSU stall with the FENCE.I D-cache flush window so
  // FENCE.I is held in EX (id_ex_q.valid stays high) until the cache is
  // drained.  The kick-off term (fence_i_pulse_raw & dirty_pending) is
  // combinational so the pipeline freezes the SAME cycle FENCE.I enters EX,
  // before id_ex_q can advance.  fence_i_active_q latches one cycle later
  // and holds the stall across the rest of the flush walk.
  assign mem_stall = lsu_mem_stall | fence_i_active_q |
                     (fence_i_pulse_raw & dcache_dirty_pending);

  // D-cache instance: owns AXI master for the data port.
  kronos_dcache u_dcache (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .req_i           (dcache_req),
    .addr_i          (dcache_addr),
    .size_i          (dcache_size),
    .we_i            (dcache_we),
    .wdata_i         (dcache_wdata),
    .amo_req_i       (dcache_amo_req),
    .amo_op_i        (dcache_amo_op),
    .rsrv_clear_i    (trap_flush),
    .data_valid_o    (dcache_data_valid),
    .rdata_o         (dcache_rdata),
    .sc_success_o    (dcache_sc_success),
    .stall_o         (dcache_stall),
    // Stage 6b: PTW priority port — page-table walks bypass the LSU pipe.
    .ptw_req_valid_i (ptw_dc_req_valid),
    .ptw_req_addr_i  (ptw_dc_req_addr),
    .ptw_req_we_i    (ptw_dc_req_we),
    .ptw_req_wdata_i (ptw_dc_req_wdata),
    .ptw_req_is_lr_i (ptw_dc_req_lr),
    .ptw_req_is_sc_i (ptw_dc_req_sc),
    .ptw_rsp_valid_o (ptw_dc_rsp_valid),
    .ptw_rsp_rdata_o (ptw_dc_rsp_rdata),
    .ptw_rsp_sc_ok_o (ptw_dc_rsp_sc_ok),
    .flush_i         (fence_i_active_q),
    .flush_done_o    (dcache_flush_done),
    .dirty_pending_o (dcache_dirty_pending),
    .axi_req_o       (data_axi_req_o),
    .axi_rsp_i       (data_axi_rsp_i),
    .miss_pulse_o    (dcache_miss_pulse)
  );

  // -------------------------------------------------------------------------
  // Stage 6b: Instruction TLB.
  //
  // Looks up the current fetch VA every cycle the alignment unit asks for a
  // word (align_needs_fetch=1).  When translation is disabled (Bare or M-mode)
  // lookup_valid_i is held low so the TLB neither claims a hit nor a perm-fail.
  // SUM/MXR are M-mode bypass bits: SUM lets S read U pages, MXR lets X→R also
  // satisfy a load.  Both come from mstatus[18] (SUM) and mstatus[19] (MXR).
  // -------------------------------------------------------------------------
  kronos_tlb #(.N(8)) u_itlb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .lookup_valid_i     (translate_fetch & align_needs_fetch),
    .lookup_va_i        ({32'b0, icache_fetch_addr}),
    .lookup_asid_i      (satp_asid),
    .lookup_priv_i      (priv_q),
    .is_load_i          (1'b0),
    .is_store_i         (1'b0),
    .is_fetch_i         (1'b1),
    .sum_i              (mstatus[18]),
    .mxr_i              (mstatus[19]),
    .lookup_hit_o       (itlb_hit),
    .lookup_pa_o        (itlb_pa),
    .lookup_perm_fail_o (itlb_perm_fail),
    .lookup_a_zero_o    (itlb_a_zero),
    .lookup_d_zero_o    (itlb_d_zero),
    .refill_valid_i     (ptw_itlb_rfv),
    .refill_size_i      (ptw_rf_size),
    .refill_vpn_i       (ptw_rf_vpn),
    .refill_ppn_i       (ptw_rf_ppn),
    .refill_asid_i      (ptw_rf_asid),
    .refill_global_i    (ptw_rf_global),
    .refill_perm_i      (ptw_rf_perm),
    .refill_a_i         (ptw_rf_a),
    .refill_d_i         (ptw_rf_d),
    .flush_valid_i      (sfence_vma),
    .flush_va_valid_i   (sfence_va_valid),
    .flush_asid_valid_i (sfence_asid_valid),
    .flush_va_i         (sfence_va),
    .flush_asid_i       (sfence_asid)
  );

  // -------------------------------------------------------------------------
  // Stage 6b: Data TLB.  Symmetric to u_itlb but on the LSU data port.  The VA
  // is alu_result (rs1 + imm computed in EX) so the lookup happens in the same
  // cycle as the ALU compute, before the EX→MEM register captures the PA.
  // -------------------------------------------------------------------------
  kronos_tlb #(.N(8)) u_dtlb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .lookup_valid_i     (translate_data & id_ex_q.valid &
                         (id_ex_q.dec.is_load | id_ex_q.dec.is_store |
                          id_ex_q.dec.is_amo)),
    .lookup_va_i        (alu_result),
    .lookup_asid_i      (satp_asid),
    .lookup_priv_i      (eff_priv_data),
    .is_load_i          (id_ex_q.dec.is_load |
                         (id_ex_q.dec.is_amo & id_ex_q.dec.is_lr)),
    .is_store_i         (id_ex_q.dec.is_store |
                         (id_ex_q.dec.is_amo & ~id_ex_q.dec.is_lr)),
    .is_fetch_i         (1'b0),
    .sum_i              (mstatus[18]),
    .mxr_i              (mstatus[19]),
    .lookup_hit_o       (dtlb_hit),
    .lookup_pa_o        (dtlb_pa),
    .lookup_perm_fail_o (dtlb_perm_fail),
    .lookup_a_zero_o    (dtlb_a_zero),
    .lookup_d_zero_o    (dtlb_d_zero),
    .refill_valid_i     (ptw_dtlb_rfv),
    .refill_size_i      (ptw_rf_size),
    .refill_vpn_i       (ptw_rf_vpn),
    .refill_ppn_i       (ptw_rf_ppn),
    .refill_asid_i      (ptw_rf_asid),
    .refill_global_i    (ptw_rf_global),
    .refill_perm_i      (ptw_rf_perm),
    .refill_a_i         (ptw_rf_a),
    .refill_d_i         (ptw_rf_d),
    .flush_valid_i      (sfence_vma),
    .flush_va_valid_i   (sfence_va_valid),
    .flush_asid_valid_i (sfence_asid_valid),
    .flush_va_i         (sfence_va),
    .flush_asid_i       (sfence_asid)
  );

  // -------------------------------------------------------------------------
  // Stage 6b: Page-Table Walker.
  //
  // Activated by an iTLB or dTLB miss (priority order: dtlb > itlb, since the
  // PTW itself is a single-port walker).  Talks to the D-cache via the PTW
  // priority port so it bypasses the LSU pipe.  Refills both TLBs through the
  // shared refill_* outputs (the *_rfv valid pulses select which TLB consumes
  // the refill bundle this cycle).
  // -------------------------------------------------------------------------
  kronos_ptw u_ptw (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .satp_mode_i          (satp_mode),
    .satp_asid_i          (satp_asid),
    .satp_ppn_i           (satp_ppn),
    .itlb_miss_i          (itlb_miss),
    .itlb_miss_va_i       ({32'b0, icache_fetch_addr}),
    .dtlb_miss_i          (dtlb_miss),
    .dtlb_miss_va_i       (alu_result),
    .dtlb_miss_is_load_i  (id_ex_q.dec.is_load |
                           (id_ex_q.dec.is_amo & id_ex_q.dec.is_lr)),
    .dtlb_miss_is_store_i (id_ex_q.dec.is_store |
                           (id_ex_q.dec.is_amo & ~id_ex_q.dec.is_lr)),
    .miss_priv_i          (eff_priv_data),
    .sum_i                (mstatus[18]),
    .mxr_i                (mstatus[19]),
    .itlb_refill_valid_o  (ptw_itlb_rfv),
    .dtlb_refill_valid_o  (ptw_dtlb_rfv),
    .refill_size_o        (ptw_rf_size),
    .refill_vpn_o         (ptw_rf_vpn),
    .refill_ppn_o         (ptw_rf_ppn),
    .refill_asid_o        (ptw_rf_asid),
    .refill_global_o      (ptw_rf_global),
    .refill_perm_o        (ptw_rf_perm),
    .refill_a_o           (ptw_rf_a),
    .refill_d_o           (ptw_rf_d),
    .page_fault_o         (ptw_pf),
    .page_fault_cause_o   (ptw_pf_cause),
    .page_fault_tval_o    (ptw_pf_tval),
    .page_fault_which_o   (ptw_pf_which),
    .dcache_req_valid_o   (ptw_dc_req_valid),
    .dcache_req_addr_o    (ptw_dc_req_addr),
    .dcache_req_we_o      (ptw_dc_req_we),
    .dcache_req_wdata_o   (ptw_dc_req_wdata),
    .dcache_req_size_o    (ptw_dc_req_size),
    .dcache_req_is_lr_o   (ptw_dc_req_lr),
    .dcache_req_is_sc_o   (ptw_dc_req_sc),
    .dcache_rsp_valid_i   (ptw_dc_rsp_valid),
    .dcache_rsp_rdata_i   (ptw_dc_rsp_rdata),
    .dcache_rsp_sc_ok_i   (ptw_dc_rsp_sc_ok),
    .busy_o               (ptw_busy)
  );

  // Stage 7a: FPU top — dispatched from ID (dispatch_fire & id_dec.is_fp)
  // Operands are from the ID-stage ROB-keyed bypass.
  // FP-source ops use FP regfile / ROB bypass; int-source FP ops (FMV.W.X etc.)
  // use the integer bypass path.
  assign fpu_tag_in = '{rd: id_dec.rd, fp_dest: id_dec.rd_fp};
  assign fpu_in_valid = dispatch_fire & id_dec.is_fp &
                        ~id_dec.fp_load & ~id_dec.fp_store;

  // FPU operands: integer-source FP instructions use int bypass
  assign fpu_a_i = id_dec.rs1_fp ? rs1_fp_data : rs1_int_data;
  assign fpu_b_i = id_dec.rs2_fp ? rs2_fp_data : rs2_int_data;

  kronos_fpu_top u_fpu (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .flush_i     (branch_flush | trap_flush),
    .in_valid_i  (fpu_in_valid),
    .op_i        (id_dec.fp_op),
    .fmt_d_i     (id_dec.fmt_d),
    .rm_i        (id_dec.rm_resolved),
    .a_i         (fpu_a_i),
    .b_i         (fpu_b_i),
    .c_i         (rs3_fp_data),
    .tag_i       (fpu_tag_in),
    .rob_idx_i   (dispatch_idx),
    .busy_o      (fpu_busy),
    .out_valid_o (fpu_out_valid),
    .result_o    (fpu_result),
    .fflags_o    (fpu_fflags),
    .tag_o       (fpu_tag_out),
    .rob_idx_o   (fpu_rob_idx_out)
  );

  // Stage 7a: FP regfile write-port — commit-driven.
  // FP loads complete via in-pipe completion port A and commit from ROB head.
  always_comb begin
    fp_we = 1'b0;
    fp_wa = 5'b0;
    fp_wd = {64{1'b0}};

    if (commit_fire & commit_entry.dec.rd_fp
        & ~commit_entry.trap_taken) begin
      fp_we = 1'b1;
      fp_wa = commit_entry.dec.rd;
      fp_wd = commit_entry.result;
    end
  end

  // -------------------------------------------------------------------------
  // Stage 7a: ROB + busy table instantiation
  // -------------------------------------------------------------------------
  assign lsu_at_head = is_at_rob_head[ex_mem_rob_idx_q];

  kronos_busy u_busy (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .rs1_int_addr_i     (id_dec.rs1),
    .rs2_int_addr_i     (id_dec.rs2),
    .rs1_fp_addr_i      (id_dec.rs1),
    .rs2_fp_addr_i      (id_dec.rs2),
    .rs1_int_o          (rs1_int_busy),
    .rs2_int_o          (rs2_int_busy),
    .rs1_fp_o           (rs1_fp_busy),
    .rs2_fp_o           (rs2_fp_busy),
    .dispatch_i         (dispatch_fire),
    .dispatch_rd_fp_i   (id_dec.rd_fp),
    .dispatch_rd_addr_i (id_dec.rd),
    .dispatch_rob_idx_i (dispatch_idx),
    .commit_i           (commit_fire),
    .commit_rd_fp_i     (commit_entry.dec.rd_fp),
    .commit_rd_addr_i   (commit_entry.dec.rd),
    .commit_rob_idx_i   (commit_idx),
    .flush_i            (branch_flush | trap_flush),
    .rob_q_i            (rob_q),
    .flush_new_head_i   (rob_head),
    .flush_new_tail_i   (trap_flush ? rob_head : rob_idx_t'(branch_flush_idx + 1'b1))
  );

  kronos_rob u_rob (
    .clk_i                 (clk_i),
    .rst_ni                (rst_ni),
    .full_o                (rob_full),
    .empty_o               (rob_empty),
    .head_o                (rob_head),
    .tail_o                (rob_tail),
    .rob_q_o               (rob_q),
    .is_at_head_o          (is_at_rob_head),
    .dispatch_i            (dispatch_fire),
    .dispatch_entry_i      (dispatch_entry),
    .dispatch_idx_o        (dispatch_idx),
    .compA_i               (compA_fire),
    .compA_idx_i           (compA_idx),
    .compA_result_i        (compA_result),
    .compA_csr_new_val_i   (compA_csr_new_val),
    .compA_trap_taken_i    (compA_trap_taken),
    .compA_trap_cause_i    (compA_trap_cause),
    .compA_tval_i          (compA_tval),
    .compA_actual_taken_i  (compA_actual_taken),
    .compA_actual_target_i (compA_actual_target),
    .compA_mispredict_i    (compA_mispredict),
    .compA_mem_addr_i      (compA_mem_addr),
    .compA_mem_wdata_i     (compA_mem_wdata),
    .compA_mem_funct3_i    (compA_mem_funct3),
    .compB_i               (compB_fire),
    .compB_idx_i           (compB_idx),
    .compB_result_i        (compB_result),
    .compB_fflags_i        (compB_fflags),
    .commit_o              (commit_fire),
    .commit_entry_o        (commit_entry),
    .commit_idx_o          (commit_idx),
    .commit_block_i        (commit_block),
    .branch_flush_i        (branch_flush),
    .branch_flush_idx_i    (branch_flush_idx),
    .trap_flush_i          (trap_flush)
  );

  // I-cache instance: replaces the old 3-state fetch FSM.
  // addr_i is 64-bit (PHYS_ADDR_W); pc_q is 32-bit — zero-extend.
  // When align_need_upper=1 the alignment unit needs the NEXT sequential 32-bit
  // word.  The current word containing pc_q is at {pc_q[31:2], 2'b00}; the next
  // word is at {pc_q[31:2]+1, 2'b00}.  This correctly handles both the intra-
  // block case (pc_q[2]=0, spanning instruction within the same 8-byte block)
  // and the cross-block case (pc_q[2]=1).
  logic [31:0] icache_fetch_addr;
  assign icache_fetch_addr = align_need_upper
                             ? {pc_q[31:2] + 30'd1, 2'b00}
                             : pc_q;

  kronos_icache u_icache (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .req_i        (align_needs_fetch),
    // Stage 6b: addr_i is the translated PA when satp.MODE != Bare and priv != M;
    // otherwise PA == VA (icache_fetch_addr).
    .addr_i       ({32'b0, eff_fetch_pa}),
    .flush_i      (fence_i_pulse),
    // Stage 6a: PMP fetch-port fault input — suppresses the AXI AR phase.
    .pmp_fault_i  (pmp_fetch_fault),
    // Stage 6b: iTLB miss — suppresses the AXI AR phase until the PTW refills.
    .tlb_miss_i   (itlb_miss),
    .data_valid_o (icache_data_valid),
    .data_o       (icache_data),
    .stall_o      (icache_stall),
    .axi_req_o    (instr_axi_req_o),
    .axi_rsp_i    (instr_axi_rsp_i),
    .miss_pulse_o (icache_miss_pulse)
  );

  kronos_align u_align (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    // Stage 6b: pc_i used to detect a 32-bit fetch that straddles a 4 KiB page
    // boundary — the upper half lives on a different (potentially unmapped)
    // page, so the upper word must be re-translated through the iTLB.
    .pc_i                (pc_q),
    .rdata_i             (icache_data),
    .rvalid_i            (icache_data_valid),
    .stall_i             (align_instr_valid & ~if_id_en),
    .flush_i             (fetch_flush),
    .pc_offset_i         (mem_redirect ? ex_mem_q.pc_next[1]
                        : ex_redirect  ? ex_pc_next[1]
                        : pred_taken   ? pred_target[1]
                        :                pc_q[1]),
    // Stage 6a: PMP fetch-port fault — suppresses instr_valid_o while held.
    .pmp_fault_i         (pmp_fetch_fault),
    // Stage 6b: gate cross-page fetch faulting on translate_fetch.  Cross-page
    // 32-bit fetches are only architecturally a fault under translation; in
    // M-mode / Bare they're legal and must NOT suppress instr_valid_o.
    .translate_fetch_i   (translate_fetch),
    .instr_o             (align_instr),
    .instr_valid_o       (align_instr_valid),
    .is_16b_o            (align_is_16b),
    .align_stall_o       (align_stall),
    .align_need_upper_o  (align_need_upper),
    .align_needs_fetch_o (align_needs_fetch),
    // Stage 6b: cross-page 32-bit fetch — pulses one cycle when the upper half
    // of a misaligned 32-bit instruction crosses into a different page.  The
    // top routes this into the trap chain as an instruction page-fault.
    .cross_page_fault_o  (cross_page_fault)
  );

  kronos_bpred u_bpred (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .pc_i            (pc_q),
    .pred_taken_o    (pred_taken),
    .pred_target_o   (pred_target),
    .upd_valid_i     (bpred_update_en),
    .upd_pc_i        (id_ex_q.pc),
    .upd_taken_i     (actual_taken),
    .upd_target_i    (ex_pc_next),
    .upd_is_jal_i    (id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr)
  );

  // =========================================================================
  // PC register
  // =========================================================================
  // Priority: mem_redirect before ex_redirect so that when both fire simultaneously
  // (MEM-stage target mismatch + speculative instr in EX also generates a redirect),
  // the pipeline returns to the architecturally correct target from the MEM branch.
  assign pc_next = mem_redirect  ? ex_mem_q.pc_next
                 : ex_redirect   ? ex_pc_next
                 : pred_taken    ? pred_target
                 : align_is_16b  ? pc_q + 32'd2
                 :                 pc_q + 32'd4;

  // pc_q reset: async to constant 0, then synchronous load of boot_addr_i
  // on the first post-reset cycle. See stage5/kronos_top.sv for the full
  // explanation — using boot_addr_i directly as an async reset value
  // produced "Set+Reset same priority" GLS bugs (issue #57).
  logic boot_loaded_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q          <= 32'b0;
      boot_loaded_q <= 1'b0;
    end else if (!boot_loaded_q) begin
      pc_q          <= boot_addr_i;
      boot_loaded_q <= 1'b1;
    end else if (pc_en) begin
      pc_q          <= pc_next;
    end
  end

  // =========================================================================
  // IF stage — icache handles all fetch transactions via u_icache above.
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if_id_q <= '0;
    end else if (if_id_flush) begin
      if_id_q <= '0;
    end else if (if_id_en) begin
      if_id_q.pc          <= pc_q;
      if_id_q.instr       <= align_instr;
      if_id_q.valid       <= align_instr_valid;
      if_id_q.is_16b      <= align_is_16b;
      if_id_q.pred_taken  <= pred_taken & ~ex_redirect;
      if_id_q.pred_target <= pred_target;
    end
  end

  // =========================================================================
  // ID / DISP stage — Stage 7a ROB-keyed bypass operand resolution
  // =========================================================================

  // Integer operand resolution via busy table + ROB
  always_comb begin
    rs1_int_stall = 1'b0;
    rs1_int_data  = rs1_rdata_64;
    if (rs1_int_busy.busy) begin
      if (rob_q[rs1_int_busy.prod_idx].complete)
        rs1_int_data = rob_q[rs1_int_busy.prod_idx].result;
      else
        rs1_int_stall = 1'b1;
    end
    rs2_int_stall = 1'b0;
    rs2_int_data  = rs2_rdata_64;
    if (rs2_int_busy.busy) begin
      if (rob_q[rs2_int_busy.prod_idx].complete)
        rs2_int_data = rob_q[rs2_int_busy.prod_idx].result;
      else
        rs2_int_stall = 1'b1;
    end
    // FP rs1
    rs1_fp_stall = 1'b0;
    rs1_fp_data  = fp_rd1;
    if (rs1_fp_busy.busy) begin
      if (rob_q[rs1_fp_busy.prod_idx].complete)
        rs1_fp_data = rob_q[rs1_fp_busy.prod_idx].result;
      else
        rs1_fp_stall = 1'b1;
    end
    // FP rs2
    rs2_fp_stall = 1'b0;
    rs2_fp_data  = fp_rd2;
    if (rs2_fp_busy.busy) begin
      if (rob_q[rs2_fp_busy.prod_idx].complete)
        rs2_fp_data = rob_q[rs2_fp_busy.prod_idx].result;
      else
        rs2_fp_stall = 1'b1;
    end
  end

  // rs3 (FMA) — always FP source; no busy lookup in stage7a (simplified)
  // If rs3 is produced by an in-flight FP instruction its result may not be
  // in the regfile yet. For correctness in stage7a, use fp_rd3 (regfile) or
  // ROB bypass if the producer is complete.
  // Note: rs3 does not have its own busy entry in kronos_busy; we do a direct
  // combinational ROB scan for the last valid write. This is a O(ROB_DEPTH)
  // priority encoder and is acceptable at depth 16.
  always_comb begin
    rs3_fp_data = fp_rd3;
    for (int i = 0; i < ROB_DEPTH; i++) begin
      if (rob_q[i].valid && rob_q[i].dec.rd_wen && rob_q[i].dec.rd_fp
          && (rob_q[i].dec.rd == id_dec.rs3) && rob_q[i].complete) begin
        rs3_fp_data = rob_q[i].result;
      end
    end
  end

  // Per-instruction operand stall: only consumed source classes contribute.
  always_comb begin
    operand_stall = 1'b0;
    if (id_dec.rs1_used && !id_dec.rs1_fp)  operand_stall |= rs1_int_stall;
    if (id_dec.rs2_used && !id_dec.rs2_fp)  operand_stall |= rs2_int_stall;
    if (id_dec.rs1_fp)                       operand_stall |= rs1_fp_stall;
    if (id_dec.rs2_fp)                       operand_stall |= rs2_fp_stall;
    // No rs3 stall tracking in 7a; handled by drain_mode serialisation
    // (the FMA producing CSR write will serialize before FMA dispatch).
  end

  // -------------------------------------------------------------------------
  // Stage 7a: drain mode for serialising ops
  // -------------------------------------------------------------------------
  logic id_is_serialising;
  logic commit_is_serialising;
  assign id_is_serialising =
       id_dec.is_csr
     | id_dec.is_mret
     | id_dec.is_sret
     | id_dec.is_sfence_vma
     | id_dec.is_wfi;

  assign commit_is_serialising =
       commit_entry.dec.is_csr
     | commit_entry.dec.is_mret
     | commit_entry.dec.is_sret
     | commit_entry.dec.is_sfence_vma
     | commit_entry.dec.is_wfi;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                                         drain_mode_q <= 1'b0;
    else if (trap_flush | branch_flush)                  drain_mode_q <= 1'b0;
    else if (commit_fire && commit_is_serialising)       drain_mode_q <= 1'b0;
    else if (dispatch_fire && id_is_serialising)         drain_mode_q <= 1'b1;
  end

  // -------------------------------------------------------------------------
  // Stage 7a: dispatch fire condition
  // ~combined_stall is REQUIRED: when the pipeline is stalled (e.g. icache miss)
  // id_ex_en=0 so the instruction would never reach ex_mem_q and fire compA.
  // Dispatching while stalled allocates a ROB entry that is never completed,
  // which deadlocks commit once that entry reaches the ROB head.
  // -------------------------------------------------------------------------
  assign dispatch_can_fire =
         if_id_q.valid
       & ~combined_stall
       & ~ex_redirect     // prevent wrong-path dispatch while redirect pending
       & ~mem_redirect
       & ~trap_flush      // trap commit resets ROB; dispatch in the same cycle is lost
       & ~rob_full
       & ~operand_stall
       & ~drain_mode_q
       & ~(id_dec.is_fp     & ~id_dec.fp_load & ~id_dec.fp_store & fpu_busy)
       & ~(id_dec.is_muldiv & ~muldiv_idle);

  assign dispatch_fire = dispatch_can_fire;

  // -------------------------------------------------------------------------
  // Stage 7a: dispatch entry build
  // -------------------------------------------------------------------------
  always_comb begin
    dispatch_entry              = '0;
    dispatch_entry.valid        = 1'b1;
    dispatch_entry.complete     = id_dec.illegal;
    dispatch_entry.pc           = if_id_q.pc;
    dispatch_entry.instr        = if_id_q.instr;
    dispatch_entry.dec          = id_dec;
    dispatch_entry.trap_taken   = id_dec.illegal;
    dispatch_entry.trap_cause   = 5'd2;  // ILLEGAL_INSTRUCTION
    dispatch_entry.tval         = {32'b0, if_id_q.instr};
  end

  // -------------------------------------------------------------------------
  // Stage 7a: EX-stage — operands come from the ROB-keyed bypass
  // For in-pipe instructions that advance through EX, use the latched
  // id_ex_q operands (which were snapshotted at dispatch time = ROB-bypass values).
  // -------------------------------------------------------------------------
  assign rs1_data_id = id_dec.rs1_fp ? rs1_fp_data : rs1_int_data;
  assign rs2_data_id = id_dec.rs2_fp ? rs2_fp_data : rs2_int_data;
  assign rs3_data_id = rs3_fp_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_ex_q <= '0;
    end else if (id_ex_flush) begin
      id_ex_q <= '0;
    end else if (id_ex_en) begin
      id_ex_q.pc          <= if_id_q.pc;
      id_ex_q.dec         <= id_dec;
      id_ex_q.rs1_data    <= rs1_data_id;
      id_ex_q.rs2_data    <= rs2_data_id;
      id_ex_q.rs3_data    <= rs3_data_id;
      id_ex_q.valid       <= if_id_q.valid & dispatch_fire;
      id_ex_q.is_16b      <= if_id_q.is_16b;
      id_ex_q.pred_taken  <= if_id_q.pred_taken;
      id_ex_q.pred_target <= if_id_q.pred_target;
      id_ex_q.fwd_rs1_sel <= FWD_NONE;  // no forwarding in 7a EX — operands resolved at dispatch
      id_ex_q.fwd_rs2_sel <= FWD_NONE;
      id_ex_q.instr       <= if_id_q.instr;
      id_ex_rob_idx_q     <= dispatch_idx;
    end
  end

  // =========================================================================
  // EX stage — Stage 7a: operands already resolved at dispatch
  // =========================================================================
  // In stage7a, operands are resolved at ID/DISP via ROB bypass.
  // The EX stage receives clean operands; no forwarding mux needed.
  assign fwd_rs1_data = id_ex_q.rs1_data;
  assign fwd_rs2_data = id_ex_q.rs2_data;

  // ALU operand formation — PC zero-extends to 64, imm sign-extends to 64.
  assign alu_a = id_ex_q.dec.use_pc  ? {32'b0, id_ex_q.pc}
                                     : fwd_rs1_data;
  assign alu_b = id_ex_q.dec.use_imm ? {{32{id_ex_q.dec.imm[31]}}, id_ex_q.dec.imm}
                                     : fwd_rs2_data;

  // 64-bit branch comparison
  always_comb begin
    branch_taken = 1'b0;
    if (id_ex_q.valid & id_ex_q.dec.is_branch) begin
      unique case (id_ex_q.dec.branch_funct3)
        3'b000:  branch_taken = (fwd_rs1_data == fwd_rs2_data);
        3'b001:  branch_taken = (fwd_rs1_data != fwd_rs2_data);
        3'b100:  branch_taken = ($signed(fwd_rs1_data) <  $signed(fwd_rs2_data));
        3'b101:  branch_taken = ($signed(fwd_rs1_data) >= $signed(fwd_rs2_data));
        3'b110:  branch_taken = (fwd_rs1_data <  fwd_rs2_data);
        3'b111:  branch_taken = (fwd_rs1_data >= fwd_rs2_data);
        default: branch_taken = 1'b0;
      endcase
    end
  end

  always_comb begin
    // Sdtrig action fires before the matched instruction commits, so a
    // trigger hit takes priority over the instruction's own illegal/ecall
    // cause (RISC-V Debug Spec §5).
    //
    // Stage 6b ordering: page-fault arms come BEFORE the matching pmp arms
    // because the priv-spec defines the access-vs-translate decision as
    // "translate first, then access-check" — a missing/perm-failed translation
    // produces a page-fault even if the translated PA would also fail PMP.
    if (trig_hit) begin
      trap_cause = 32'd3;                                   // BREAKPOINT (Sdtrig)
    end else if (instr_page_fault) begin
      trap_cause = {27'b0, CAUSE_INSTR_PAGE_FAULT};         // 12
    end else if (pmp_fetch_fault) begin
      trap_cause = {27'b0, CAUSE_INSTR_ACCESS_FAULT};       // 1
    end else if (load_page_fault) begin
      trap_cause = {27'b0, CAUSE_LOAD_PAGE_FAULT};          // 13
    end else if (pmp_data_fault & id_ex_q.dec.is_load) begin
      trap_cause = {27'b0, CAUSE_LOAD_ACCESS_FAULT};        // 5
    end else if (store_page_fault) begin
      trap_cause = {27'b0, CAUSE_STORE_PAGE_FAULT};         // 15
    end else if (pmp_data_fault & id_ex_q.dec.is_store) begin
      trap_cause = {27'b0, CAUSE_STORE_ACCESS_FAULT};       // 7
    end else if (pmp_data_fault & id_ex_q.dec.is_amo) begin
      // AMO permission violation: report as STORE access fault (priv-spec).
      trap_cause = {27'b0, CAUSE_STORE_ACCESS_FAULT};
    end else if (irq_pending) begin
      trap_cause = {1'b1, 26'b0, irq_cause};                // mcause[63]=1 (IRQ)
    end else if (id_ex_q.dec.illegal | csr_illegal |
                 mret_priv_fail | sret_priv_fail | satp_tvm_fail |
                 wfi_priv_fail_q) begin
      trap_cause = 32'd2;                                   // ILLEGAL
    end else if (id_ex_q.dec.is_ecall) begin
      unique case (priv_q)
        PRIV_U:  trap_cause = {27'b0, CAUSE_ECALL_U};       // 8
        PRIV_S:  trap_cause = {27'b0, CAUSE_ECALL_S};       // 9
        PRIV_M:  trap_cause = {27'b0, CAUSE_ECALL_M};       // 11
        default: trap_cause = {27'b0, CAUSE_ECALL_M};
      endcase
    end else begin
      trap_cause = 32'd3;                                   // ebreak (default)
    end
  end

  // Stage 6a/6b: trap_tval — set to the offending PC for fetch faults, the
  // offending data address for data PMP / page faults, the original
  // instruction word for illegal-instruction (priv-spec § 3.1.16), and 0
  // otherwise.  Page-fault tval matches the spec: the faulting VA.
  always_comb begin
    if      (instr_page_fault) trap_tval = pc_q;
    else if (pmp_fetch_fault)  trap_tval = pmp_fetch_fault_addr[31:0];
    else if (load_page_fault | store_page_fault)
                               trap_tval = alu_result[31:0];
    else if (pmp_data_fault)   trap_tval = pmp_data_fault_addr[31:0];
    else if (id_ex_q.dec.illegal | csr_illegal |
             mret_priv_fail | sret_priv_fail | satp_tvm_fail |
             wfi_priv_fail_q)
                               trap_tval = id_ex_q.instr;
    else                       trap_tval = 32'd0;
  end

  // JALR target: 64-bit add, truncate to 32-bit PC (physical PC is 32-bit).
  assign jalr_target_64 = (fwd_rs1_data + {{32{id_ex_q.dec.imm[31]}}, id_ex_q.dec.imm})
                           & ~64'd1;

  always_comb begin
    if      ((id_ex_q.valid & (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
                               id_ex_q.dec.illegal  | csr_illegal |
                               mret_priv_fail | sret_priv_fail | satp_tvm_fail |
                               wfi_priv_fail_q |
                               irq_pending)) | trig_hit |
              pmp_fetch_fault | pmp_data_fault |
              instr_page_fault | load_page_fault | store_page_fault)
      ex_pc_next = trap_vector[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_mret & ~mret_priv_fail)
      ex_pc_next = mepc[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_sret & ~sret_priv_fail)
      ex_pc_next = sepc[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_jalr)
      ex_pc_next = jalr_target_64[31:0];
    else if (id_ex_q.valid & id_ex_q.dec.is_jal)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else if (branch_taken)
      ex_pc_next = id_ex_q.pc + id_ex_q.dec.imm;
    else
      ex_pc_next = id_ex_q.is_16b ? id_ex_q.pc + 32'd2 : id_ex_q.pc + 32'd4;
  end

  // STAGE3: branch predictor — misprediction detection and update
  assign is_branch_or_jump = id_ex_q.dec.is_branch | id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr;
  assign actual_taken      = branch_taken | id_ex_q.dec.is_jal | id_ex_q.dec.is_jalr;

  // Direction-only misprediction: taken/not-taken disagrees with prediction.
  // Target misprediction (both predicted and actually taken, but wrong target)
  // is deferred to the MEM stage (bpred_mispredict_target) so that the JALR
  // target adder and the 32-bit comparator are removed from the ex_redirect
  // combinational path.
  assign bpred_mispredict = id_ex_q.valid & (
    (id_ex_q.pred_taken & ~actual_taken) |
    (~id_ex_q.pred_taken & actual_taken)
  );

  // Suppress BTB update from the speculative instruction in EX when mem_redirect fires.
  assign bpred_update_en = id_ex_q.valid & ex_mem_en & is_branch_or_jump & ~mem_redirect;

  // FENCE.I trap suppression: when FENCE.I sits in EX and the D-cache still
  // holds dirty data, suppress the illegal-instruction redirect until the
  // flush completes.  Once dcache_flush_done pulses (or there were no dirty
  // lines), the redirect resumes and the trap handler advances MEPC past
  // the FENCE.I — by which time AXI memory has the up-to-date bytes.
  logic fence_i_dirty_block;
  assign fence_i_dirty_block = id_ex_q.valid &
                                (id_ex_q.instr[6:0]   == 7'b0001111) &
                                (id_ex_q.instr[14:12] == 3'b001) &
                                dcache_dirty_pending & ~dcache_flush_done;

  assign ex_redirect = bpred_mispredict |
    (id_ex_q.valid &
     (id_ex_q.dec.is_ecall | id_ex_q.dec.is_ebreak |
      (id_ex_q.dec.illegal & ~fence_i_dirty_block) |
      csr_illegal |
      mret_priv_fail | sret_priv_fail | satp_tvm_fail |
      wfi_priv_fail_q |
      irq_pending |
      id_ex_q.dec.is_mret | id_ex_q.dec.is_sret)) |
    trig_hit |
    pmp_fetch_fault | pmp_data_fault |
    instr_page_fault | load_page_fault | store_page_fault;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ex_mem_csr_q <= 1'b0;
    else if (ex_mem_en) ex_mem_csr_q <= (id_ex_q.dec.wb_sel == WB_CSR);
  end

  // Stage 6c: capture u_csr.csr_new_val_o at the EX→MEM boundary.  The CSR's
  // own write commits on the same posedge (req_i is gated by ~combined_stall),
  // so this snapshot is the post-write value for the EX-stage instruction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        ex_mem_csr_new_val_q <= 64'b0;
    else if (ex_mem_en) ex_mem_csr_new_val_q <= csr_new_val_post;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '0;
    end else if (ex_mem_en) begin
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.dec        <= id_ex_q.dec;
      ex_mem_q.alu_result <= ex_result;
      ex_mem_q.rs2_data   <= fwd_rs2_data;
      ex_mem_q.pc_next    <= ex_pc_next;
      ex_mem_q.csr_rdata  <= csr_rdata;
      ex_mem_q.redirect    <= ex_redirect;
      ex_mem_q.valid       <= (id_ex_q.valid & ~irq_pending) & ~mem_redirect;
      ex_mem_q.is_16b      <= id_ex_q.is_16b;
      ex_mem_q.pred_taken  <= id_ex_q.pred_taken;
      ex_mem_q.pred_target <= id_ex_q.pred_target;
      ex_mem_q.instr       <= id_ex_q.instr;
      ex_mem_q.csr_wdata   <= fwd_rs1_data;
      // Stage 7a: capture CSR new val at EX→MEM boundary
      ex_mem_csr_new_val_q <= csr_new_val_post;
      // Stage 7a: carry rob_idx through to MEM stage
      ex_mem_rob_idx_q     <= id_ex_rob_idx_q;
    end
  end

  // Stage 6b: register the translated data-port PA at the EX→MEM boundary so
  // the LSU (which sits in MEM) consumes the PA produced by the dTLB lookup
  // in EX.  When translation is off (Bare or M-mode) eff_data_pa == alu_result
  // so this register is a noop relative to the pre-stage-6b behaviour.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex_mem_data_pa_q <= 32'b0;
    else if (ex_mem_en)  ex_mem_data_pa_q <= eff_data_pa;
  end

  // MEM-stage target misprediction: predictor predicted taken with the right
  // direction (so EX did not redirect), but the predicted target was wrong.
  // Both ex_mem_q.pc_next and ex_mem_q.pred_target are registered, so this
  // comparison sits on a short path. Guard with ~ex_mem_q.redirect: if EX
  // already redirected (direction mismatch or trap), no second redirect needed.
  assign bpred_mispredict_target = ex_mem_q.valid & ~ex_mem_q.redirect &
    ex_mem_q.pred_taken & (ex_mem_q.pred_target != ex_mem_q.pc_next);
  assign mem_redirect = bpred_mispredict_target;

  // Any flush that redirects the fetch stream.
  assign fetch_flush = if_id_flush | (pred_taken & pc_en & ~ex_redirect & ~mem_redirect);

  // =========================================================================
  // MEM stage — mem_done_q / lsu_rdata_latch handle pipeline stall bridging
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_done_q      <= 1'b0;
      lsu_rdata_latch <= {64{1'b0}};
      amo_write_latch <= 1'b0;
    end else begin
      if (lsu_valid) begin
        mem_done_q      <= 1'b1;
        lsu_rdata_latch <= lsu_rdata;
        // AMO write: any AMO (not LR) or a successful SC.
        amo_write_latch <= ex_mem_q.dec.is_amo & ~ex_mem_q.dec.is_lr
                         | ex_mem_q.dec.is_sc & dcache_sc_success;
      end
      if (~mem_stall) begin
        mem_done_q <= 1'b0;
      end
    end
  end

  // =========================================================================
  // Stage 7a: In-pipe completion port A — wiring
  // =========================================================================
  // Port A fires the cycle the MEM stage produces a result.
  // For ALU/branch: fires immediately when ex_mem_q.valid & ~mem_stall.
  // For loads: fires when lsu_valid (dcache returns data).
  // For stores/CSR: fires when lsu_valid / CSR completes (at_head gate in LSU/CSR).

  // FP arithmetic instructions (is_fp, not a load or store) complete via
  // compB (FPU out_valid). Exclude them from the in-pipe compA port to prevent
  // the ALU result (e.g. fadd of bit-patterns) from spuriously completing the
  // ROB entry before the FPU has finished.
  // compA must not fire for ops that complete via async port B:
  //   - FP arithmetic (is_fp & !fp_load & !fp_store)  → from u_fpu_top
  //   - muldiv (is_muldiv)                            → from u_muldiv
  // Without this gate, the in-pipe ALU ADD result lands in the ROB entry and
  // marks complete=1 with stale data before the FU has finished — RAW
  // consumers then bypass garbage from the ROB.
  logic in_pipe_result_fire;
  assign in_pipe_result_fire = ex_mem_q.valid & ~mem_stall
    & ~(ex_mem_q.dec.is_fp & ~ex_mem_q.dec.fp_load & ~ex_mem_q.dec.fp_store)
    & ~ex_mem_q.dec.is_muldiv;

  assign compA_fire = in_pipe_result_fire;
  assign compA_idx  = ex_mem_rob_idx_q;

  // Result selection — matches the old WB mux logic but now feeds into the ROB.
  always_comb begin
    logic [63:0] pc4_val;
    pc4_val = {32'b0, ex_mem_q.pc + (ex_mem_q.is_16b ? 32'd2 : 32'd4)};
    unique case (ex_mem_q.dec.wb_sel)
      WB_ALU:  compA_result = ex_mem_q.alu_result;
      WB_MEM:  compA_result = lsu_valid ? lsu_rdata : lsu_rdata_latch;
      WB_PC4:  compA_result = pc4_val;
      WB_CSR:  compA_result = ex_mem_q.csr_rdata;
      default: compA_result = ex_mem_q.alu_result;
    endcase
  end

  assign compA_csr_new_val   = ex_mem_csr_new_val_q;
  // Trap path — re-derive from ex_mem_q (trap already evaluated in EX stage;
  // however in stage7a the ROB stores the trap and commits it at head).
  // Port A fires for ALL in-pipe instructions; trap info from ex_redirect.
  //
  // compA_trap_taken must ONLY be true for actual exceptions/interrupts — NOT
  // for branch mispredictions, JAL, JALR, or mret/sret.  Those instruction
  // types set ex_redirect for correct program flow (not an exception condition),
  // so marking them trap_taken=1 would cause a spurious trap_flush at ROB commit
  // time, flushing the alignment unit with the wrong pc_offset and skipping
  // instructions.
  assign compA_trap_taken    = ex_mem_q.valid & ex_mem_q.redirect
                             & ~bpred_mispredict_target
                             & ~ex_mem_q.dec.is_branch
                             & ~ex_mem_q.dec.is_jal
                             & ~ex_mem_q.dec.is_jalr
                             & ~ex_mem_q.dec.is_mret
                             & ~ex_mem_q.dec.is_sret;
  assign compA_trap_cause    = trap_cause[4:0];
  assign compA_tval          = {32'b0, trap_tval};
  assign compA_actual_taken  = ex_mem_q.dec.is_branch
                               ? (ex_mem_q.pc_next != ex_mem_q.pc +
                                  (ex_mem_q.is_16b ? 32'd2 : 32'd4))
                               : (ex_mem_q.dec.is_jal | ex_mem_q.dec.is_jalr);
  assign compA_actual_target = ex_mem_q.pc_next;
  assign compA_mispredict    = bpred_mispredict_target;
  assign compA_mem_addr      = ex_mem_q.alu_result;
  assign compA_mem_wdata     = ex_mem_q.rs2_data;
  assign compA_mem_funct3    = ex_mem_q.dec.mem_funct3;

  // =========================================================================
  // Stage 7a: Async completion port B — FPU + muldiv arbiter
  // =========================================================================
  always_comb begin
    compB_fire   = fpu_out_valid | muldiv_valid;
    compB_idx    = fpu_out_valid ? fpu_rob_idx_out : muldiv_rob_idx_out;
    compB_result = fpu_out_valid ? fpu_result      : muldiv_result;
    compB_fflags = fpu_out_valid ? fpu_fflags      : 5'b0;
  end
  // FPU wins arbitration: muldiv stalls one cycle when both ready
  assign muldiv_complete_stall = fpu_out_valid;

  // =========================================================================
  // Stage 7a: Branch + trap flush
  // =========================================================================
  assign branch_flush     = ex_mem_q.valid & is_branch_or_jump & bpred_mispredict_target;
  assign branch_flush_idx = ex_mem_rob_idx_q;
  assign trap_flush       = commit_fire & commit_entry.trap_taken;

  // commit_block: block commit when a trap-CSR drain is in progress.
  // In stage7a, we don't track a separate drain condition; CSR writes
  // are serialised via drain_mode. Commit block is 0 for now.
  assign commit_block = 1'b0;

  // =========================================================================
  // Stage 7a: Performance counter event bus
  // =========================================================================
  assign bpred_mispredict_pulse =
      (bpred_mispredict | bpred_mispredict_target) & ~combined_stall;
  assign fpu_busy_any = fpu_busy;
  assign trap_taken_pulse = trap_flush;

  // Trace-compat: sim_main.cpp reads u_top.fp_inflight_q via --public-flat-rw
  // for stall classification (event 0x18 "fp_inflight_stall"). Stage 7a no
  // longer flops a dedicated FPU-inflight bit (the ROB tracks completion via
  // valid/complete bits per entry), so register fpu_busy as a 1-cycle delayed
  // alias to preserve the existing sim_main.cpp telemetry contract.
  logic fp_inflight_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) fp_inflight_q <= 1'b0;
    else         fp_inflight_q <= fpu_busy;
  end

  assign event_bus[ 0]    = 1'b0;
  assign event_bus[ 1]    = commit_fire & commit_entry.dec.is_branch;
  assign event_bus[ 2]    = bpred_mispredict_pulse;
  assign event_bus[ 3]    = commit_fire & commit_entry.dec.is_load;
  assign event_bus[ 4]    = commit_fire & commit_entry.dec.is_store;
  assign event_bus[ 5]    = mem_stall;
  assign event_bus[ 6]    = 1'b0;  // muldiv OoO in stage7a
  assign event_bus[ 7]    = fpu_busy_any;
  assign event_bus[ 8]    = trap_taken_pulse;
  assign event_bus[15:9]  = '0;
  assign event_bus[16]    = icache_miss_pulse;
  assign event_bus[17]    = dcache_miss_pulse;
  assign event_bus[18]    = 1'b0;
  assign event_bus[19]    = 1'b0;
  assign event_bus[EVT_LOAD_USE_STALL]      = load_use_event;
  assign event_bus[EVT_JALR_FWD_STALL]      = jalr_fwd_event;
  assign event_bus[EVT_FP_RAW_STALL]        = fp_load_use_event;
  assign event_bus[EVT_FRM_HAZARD_STALL]    = id_ex_is_frm_write & if_id_fp_dyn_rm;
  assign event_bus[EVT_FP_INFLIGHT_STALL]   = 1'b0;  // no FP inflight stall in stage7a
  assign event_bus[EVT_FENCE_I_DRAIN_STALL] = fence_i_active_q;
  assign event_bus[EVT_MEM_BUSY_STALL]      = lsu_mem_stall | dcache_stall;
  assign event_bus[EVT_MULDIV_STALL]        = 1'b0;
  assign event_bus[EVT_FPU_STALL]           = fpu_busy_any;
  assign event_bus[EVT_INSTR_FETCH_STALL]   = instr_fetch_stall;
  assign event_bus[EVT_BRANCH_MISPREDICT]   = bpred_mispredict_pulse;
  assign event_bus[EVT_EX_REDIRECT]         = ex_redirect;

  // =========================================================================
  // Stage 7a: Retire trace — driven from commit_entry / commit_fire
  // =========================================================================
  assign retire_valid_o      = commit_fire;
  assign retire_pc_o         = {32'b0, commit_entry.pc};
  assign retire_instr_o      = commit_entry.instr;
  assign retire_rd_wen_o     = commit_entry.dec.rd_wen & ~commit_entry.dec.rd_fp
                               & ~commit_entry.trap_taken;
  assign retire_rd_o         = commit_entry.dec.rd;
  assign retire_rd_wdata_o   = commit_entry.result;
  assign retire_fp_wen_o     = commit_entry.dec.rd_wen & commit_entry.dec.rd_fp
                               & ~commit_entry.trap_taken;
  assign retire_fp_rd_o      = commit_entry.dec.rd;
  assign retire_fp_wdata_o   = commit_entry.result;
  assign retire_mem_wen_o    = commit_entry.dec.is_store;
  assign retire_mem_addr_o   = commit_entry.mem_addr;
  assign retire_mem_wdata_o  = commit_entry.mem_wdata;
  assign retire_mem_funct3_o = commit_entry.mem_funct3;
  assign retire_csr_wen_o    = commit_entry.dec.is_csr;
  assign retire_csr_addr_o   = commit_entry.dec.csr_addr;
  assign retire_csr_wdata_o  = commit_entry.csr_new_val;
  assign retire_trap_taken_o = commit_entry.trap_taken & commit_fire;
  assign retire_trap_cause_o = {27'b0, commit_entry.trap_cause};

endmodule
