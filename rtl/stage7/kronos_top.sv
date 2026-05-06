// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_top.sv (stage5) — 5-stage in-order pipeline with RV64IMAFD support.
// Extends stage4 (RV64IMAC) with:
//   * kronos_regfile_fp  — 3R1W 32×64-bit FP register file
//   * kronos_fpu_top     — FPU dispatch wrapper (FMISC/FCVT/FADD/FMUL/FMA)
//   * FP load/store wiring through kronos_lsu
//   * fflags/frm wiring through kronos_csr
//   * FP stall: entire pipeline stalls while FPU computes
module kronos_top
  import kronos_pkg::*;
#(
  // PMA non-cacheable region list — exposed for SoC integrators.
  parameter int unsigned     NUM_NC_REGIONS = 1,
  parameter logic [kronos_pkg::XLEN-1:0] NC_REGION_BASE  [NUM_NC_REGIONS] = '{kronos_pkg::MMIO_BASE},
  parameter logic [kronos_pkg::XLEN-1:0] NC_REGION_LIMIT [NUM_NC_REGIONS] = '{64'h0000_0000_4FFF_FFFF}
) (
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
  // standard RISC-V interrupt inputs (priv-spec § 3.1.9).
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
  output logic            retire_valid_o,
  output logic [kronos_pkg::XLEN-1:0] retire_pc_o,
  output logic [kronos_pkg::INST_W-1:0] retire_instr_o,
  output logic            retire_rd_wen_o,
  output logic [4:0]      retire_rd_o,
  output logic [kronos_pkg::XLEN-1:0] retire_rd_wdata_o,
  output logic            retire_fp_wen_o,
  output logic [4:0]      retire_fp_rd_o,
  output logic [kronos_pkg::FLEN-1:0] retire_fp_wdata_o,
  output logic            retire_mem_wen_o,
  output logic [kronos_pkg::XLEN-1:0] retire_mem_addr_o,
  output logic [kronos_pkg::XLEN-1:0] retire_mem_wdata_o,
  output logic [2:0]      retire_mem_funct3_o,
  output logic            retire_csr_wen_o,
  output logic [11:0]     retire_csr_addr_o,
  output logic [kronos_pkg::XLEN-1:0] retire_csr_wdata_o,
  // Trap-taken pulse: high for one cycle on trap entry (debug/coverage only).
  output logic        retire_trap_taken_o,
  output logic [31:0] retire_trap_cause_o
);

  // -------------------------------------------------------------------------
  // Pipeline registers
  // -------------------------------------------------------------------------
  if_id_reg_t   if_id_q;
  // ID/RR pipeline register (Stage 7b).  Carries the decode result + ID-owned
  // fault bits across the new RR (register-read) stage so EX1 starts from
  // pre-flopped operands and the regfile / bypass / CSR read no longer share
  // a cycle with decode.
  id_rr_reg_t   id_rr_q;
  id_rr_reg_t   id_rr_d;
  rr_ex1_reg_t  rr_ex1_q;
  // Stage 7a — EX1→EX2 pipeline register.  Carries registered ALU result,
  // effective VA, branch direction, and the running fault aggregate so EX2
  // can form ex_redirect_d from registered bits only.
  ex1_ex2_reg_t  ex1_ex2_q;
  ex1_ex2_reg_t  ex1_ex2_d;
  logic          ex1_ex2_en;
  logic          ex1_ex2_flush;
  ex_mem_reg_t  ex2_mem1_q;
  mem1_mem2_reg_t mem1_mem2_q;
  mem_wb_reg_t    mem_wb_q;
  logic [31:0] pc_q                              /* verilator public_flat_rd */;
  // Boot loader: synchronous one-shot to load boot_addr_i into pc_q after reset.
  // Avoids the "Set+Reset same priority" GLS issue (#57) caused by using
  // boot_addr_i as an async reset value.
  logic        boot_loaded_q;

  // -------------------------------------------------------------------------
  // Hazard / forwarding control
  // -------------------------------------------------------------------------
  logic      pc_en, if_id_en, id_rr_en, rr_ex1_en;
  logic      ex2_mem1_en, mem1_mem2_en, mem_wb_en;
  logic      if_id_flush, id_rr_flush, rr_ex1_flush;
  logic      ex2_mem1_flush, mem1_mem2_flush;
  fwd_sel_e  fwd_rs1_sel, fwd_rs2_sel;

  // -------------------------------------------------------------------------
  // ID-stage wires
  // -------------------------------------------------------------------------
  decoded_instr_t  id_dec;
  logic [kronos_pkg::XLEN-1:0] rs1_rdata_64, rs2_rdata_64;
  // RR-stage operand-data wires (regfile reads + bypass-source select feed
  // these; the bypass mux at the RR/EX1 boundary captures into rr_ex1_q).
  logic [kronos_pkg::XLEN-1:0] rs1_data_rr, rs2_data_rr, rs3_data_rr;
  logic            wb_writing;

  // FP regfile read ports
  logic [kronos_pkg::FLEN-1:0] fp_rd1, fp_rd2, fp_rd3;

  // CSR frm output
  logic [2:0]     frm;

  // RR-stage source-select helper signals.
  // FP paths: 2-bit one-hot selector + data mux (4-way, replaces 4-level chain).
  // Integer path: plain WB-bypass-or-regfile (EX-class bypassing handled by the
  // RR/EX1 forwarding mux below via fwd_rs1_sel/fwd_rs2_sel).
  logic [1:0]      fp_rs1_sel, fp_rs2_sel, fp_rs3_sel;
  logic [kronos_pkg::FLEN-1:0] fp_rs1_data_rr, fp_rs2_data_rr, fp_rs3_data_rr;
  logic [kronos_pkg::XLEN-1:0] int_rs1_data_rr, int_rs2_data_rr;
  // RR-stage CSR read (speculative).  u_csr drives a second combinational read
  // port keyed on id_rr_q.dec.csr_addr; the result is captured into
  // rr_ex1_q.csr_rdata at the RR/EX1 boundary so EX1 consumes a flopped value.
  logic [kronos_pkg::XLEN-1:0] rr_csr_rdata_combinational;
  // Bypassed RS1/RS2 captured into rr_ex1_q at the RR/EX1 flop boundary.
  logic [kronos_pkg::XLEN-1:0] rs1_bypassed, rs2_bypassed;

  // -------------------------------------------------------------------------
  // EX-stage wires (64-bit datapath)
  // -------------------------------------------------------------------------
  logic [kronos_pkg::XLEN-1:0] fwd_rs1_data, fwd_rs2_data;
  logic [kronos_pkg::XLEN-1:0] alu_a, alu_b, alu_result;
  logic [kronos_pkg::XLEN-1:0] alu_adder_out;
  logic                        alu_cmp_lt;
  logic                        alu_eq;
  logic [kronos_pkg::XLEN-1:0] ex_result;
  logic [31:0]     ex_pc_d                        /* verilator public_flat_rd */;
  // Stage 7a — registered redirects.  ex_redirect_d formed at EX2 (direction
  // mispredict only), registered into ex_redirect_q.  mem_redirect_d formed
  // at MEM (everything else), registered into mem_redirect_q.  redirect_load
  // consumes only the registered _q variants.
  //
  // Each redirect carries its own registered target (`ex_redirect_target_q`,
  // `mem_redirect_target_q`) captured at the same edge that asserts the
  // redirect.  Without these snapshots the IFU would read `ex1_ex2_q.ex_pc_d`
  // / `ex2_mem1_q.pc_d` one cycle later — by which time the pipeline has
  // advanced and those fields hold the *next* instruction's target, not the
  // mispredicting branch's.
  logic ex_redirect_d;
  logic ex_redirect_q                  /* verilator public_flat_rd */;
  logic [31:0] ex_redirect_target_q  /* verilator public_flat_rd */;
  logic [31:0] mem_redirect_target_q /* verilator public_flat_rd */;
  // Stage 7a — registered FENCE.I redirect.  In stage 6 the FENCE.I trap
  // (decode-illegal) and the icache flush both fired the same cycle through
  // the combinational `ex_redirect`.  Here, the illegal-trap rides the fault-
  // bit pipeline through ex1_ex2_q -> ex2_mem1_q -> mem_redirect_q, arriving
  // two cycles after `fence_i_pulse` flushes the icache.  During that gap
  // the IFU keeps fetching from FENCE.I+4 -- now that the icache valid bits
  // have just dropped, those fetches see post-flush misses and stage them
  // into the FB / predecode, where the trap eventually arrives but lands on
  // a pipeline that has already absorbed wrong-path bytes.
  //
  // `fence_i_redirect_q` registers `fence_i_pulse` so the cycle AFTER the
  // pulse the IFU is steered to FENCE.I+4 (`fence_i_redirect_target_q`).
  // This rebases the next fetch on the just-flushed icache so the freshly-
  // stored bytes win, killing in-flight wrong-path entries via the standard
  // `redirect_load` machinery.  The eventual mem_redirect_q-to-mtvec lands
  // one cycle after fence_i_redirect_q drops; the trap handler advances
  // mepc past FENCE.I and execution resumes at FENCE.I+4 (now correct).
  logic        fence_i_redirect_q          /* verilator public_flat_rd */;
  logic [31:0] fence_i_redirect_target_q   /* verilator public_flat_rd */;
  // Trace alias: sim_main.cpp probes `ex_redirect` for cycle-level trace.  In
  // Stage 7a the IFU consumes ex_redirect_q (registered) only; this comb alias
  // is observation-only and keeps the C++ trace harness binary-compatible
  // across stage6 and stage7a builds.
  logic ex_redirect                    /* verilator public_flat_rd */;
  logic            branch_taken;
  logic            irq_pending;
  logic [4:0]      irq_cause;
  logic [kronos_pkg::XLEN-1:0] csr_rdata;
  logic [kronos_pkg::XLEN-1:0] trap_vector, mepc, sepc;
  logic [31:0]     trap_cause                        /* verilator public_flat_rd */;
  // Stage 7a — EX1-cycle live trap_cause / trap_class predictor.  Feeds
  // u_csr.trap_cause_ex_i / trap_class_ex_i so trap_vector_o sees the
  // delegated stvec at the cycle ex_pc_d is computed; the registered
  // mem_wb_trap_cause_q commits at retire one stage later and would always
  // read mtvec for delegated traps.
  logic [31:0]     ex1_trap_cause;
  logic            ex1_trap_class;
  logic [kronos_pkg::XLEN-1:0] jalr_target_64;

  // privilege state + protection wires.
  priv_e             priv_q;
  logic [kronos_pkg::XLEN-1:0]   mstatus;
  logic              pmp_fetch_fault;
  logic [55:0]       pmp_fetch_fault_addr;
  logic              pmp_data_fault;
  logic [55:0]       pmp_data_fault_addr;
  // Registered fetch-fault s1 stage.  pmp_fetch_fault_raw and itlb_perm_fail
  // both fan into ex_redirect → redirect_load → align_needs_fetch, which
  // gates the very fault inputs that produced them.  Flopping the gated
  // outputs (with a redirect_load sync-clear) breaks both back-edges; the
  // address snapshot keeps trap_tval pointing at the offending fetch VA.
  logic              pmp_s1_fetch_fault_q;
  logic [55:0]       pmp_s1_fetch_fault_addr_q;
  logic              itlb_s1_perm_fail_q;
  // pc_q snapshot taken alongside itlb_s1_perm_fail_q so trap_tval for the
  // registered iTLB perm-fail arm reads the same pc_q value the pre-flop
  // (combinational) trap would have seen.  Without this, pc_q can advance
  // during the new 1-cycle fault window if predecode emits at cycle N.
  logic [31:0]       itlb_s1_pc_q;
  logic [15:0][7:0]  pmpcfg;
  logic [15:0][53:0] pmpaddr;
  logic [31:0]       trap_tval;
  logic              csr_illegal;
  // Raw csr_illegal_o from u_csr (computed unconditionally on addr/priv);
  // csr_illegal below is the externally gated form on registered rr_ex1_q
  // fields, kept off the comb cone driven by combined_stall (closes #89).
  logic              csr_illegal_raw;
  // priv-checked control transfers (mret/sret) and TVM/TW gates.
  logic              mret_priv_fail;
  logic              sret_priv_fail;
  logic              satp_tvm_fail;
  // PMP data-port size_i (3-bit log2 width: 0=1B,1=2B,2=4B,3=8B).
  logic [2:0]        pmp_data_size;
  // PMP enforcement gate + raw PMP outputs (gated by pmp_any_active).
  logic              pmp_any_active;
  logic              pmp_fetch_fault_raw;
  logic [55:0]       pmp_fetch_fault_addr_raw;
  logic              pmp_data_fault_raw;
  logic [55:0]       pmp_data_fault_addr_raw;
  // PMA AMO-on-NC trap detection at MEM1 stage (post-dTLB-translation).
  logic              mem1_amo_nc_fault;
  logic              mem1_addr_uncacheable;
  // MEM1-cycle page-fault producers for load / store / AMO accesses.  Land in
  // mem1_mem2_q.fault.{load,store}_page_fault at the MEM1->MEM2 edge.
  logic              mem1_load_page_fault;
  logic              mem1_store_page_fault;
  // MEM1->MEM2 fault next-state (registered into mem1_mem2_q.fault).  Folds
  // every EX2-stage fault bit with the MEM1-cycle producers.
  fault_t            mem1_fault_d;
  // MEM1-class trap predicate — overrides mem1_mem2_q.pc_d to trap_vector at
  // the MEM1->MEM2 edge so mem_redirect_target_q latches the correct vector.
  logic              mem1_trap_redirect;

  // -------------------------------------------------------------------------
  // TLB / PTW / translation-control wires.
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
  logic [4:0]      ptw_pf_cause;
  logic [kronos_pkg::XLEN-1:0] ptw_pf_tval;
  tlb_op_e         ptw_pf_which;
  logic            ptw_dc_req_valid, ptw_dc_req_we, ptw_dc_req_lr, ptw_dc_req_sc;
  logic [55:0]     ptw_dc_req_addr;
  logic [kronos_pkg::XLEN-1:0] ptw_dc_req_wdata;
  logic [2:0]      ptw_dc_req_size;
  logic            ptw_itlb_rfv, ptw_dtlb_rfv;
  logic [1:0]      ptw_rf_size;
  logic [35:0]     ptw_rf_vpn;
  logic [43:0]     ptw_rf_ppn;
  logic [15:0]     ptw_rf_asid;
  logic            ptw_rf_global;
  logic [3:0]      ptw_rf_perm;
  logic            ptw_rf_a, ptw_rf_d;
  logic            ptw_dc_rsp_valid, ptw_dc_rsp_sc_ok;
  logic [kronos_pkg::XLEN-1:0] ptw_dc_rsp_rdata;
  logic [3:0]      satp_mode;
  logic [15:0]     satp_asid;
  logic [43:0]     satp_ppn;
  priv_e           eff_priv_data;
  logic            translate_data, translate_fetch;
  logic            sfence_vma, sfence_va_valid, sfence_asid_valid;
  logic [kronos_pkg::XLEN-1:0] sfence_va;
  logic [15:0]     sfence_asid;
  logic        wfi_priv_fail;
  logic        cross_page_fault;
  logic [31:0] eff_fetch_pa, eff_data_pa;
  // aggregate page-fault routing.
  logic        instr_page_fault, load_page_fault, store_page_fault;
  // PA pipeline: dTLB lookup runs at MEM1 (consuming ex2_mem1_q.alu_result as
  // VA), the translated PA is registered into mem1_mem2_q.dtlb_pa at the
  // MEM1->MEM2 edge, and the LSU at MEM2 consumes mem1_mem2_q.dtlb_pa.

  // STAGE2: muldiv signals (64-bit)
  logic [kronos_pkg::XLEN-1:0] muldiv_result;
  logic        muldiv_valid, muldiv_idle;
  logic        muldiv_stall;

  // pre-registered CSR-select flag for EX forwarding mux.
  // CSR-typed-result tags chained through the EX1→EX2→MEM1→MEM2 boundaries.
  // Each register samples (wb_sel == WB_CSR) at the upstream stage; the
  // bypass mux reads the corresponding tag at FWD_EX1 / FWD_EXMEM     / FWD_MEM2
  // to select between alu_result and csr_rdata. Eliminates a 3-bit wb_sel
  // compare from each forward arm at the consumer.
  logic        ex1_ex2_csr_q;
  logic        ex2_mem_csr_q;
  logic        mem1_mem2_csr_q;
  // Stage 7a — csr_new_val pipeline.  u_csr.csr_new_val_o is computed
  // combinationally from rr_ex1_q at the EX1 cycle.  The architectural CSR
  // commit happens at retire_i (mem_wb_q), so the value must be carried
  // through ex1_ex2 -> ex2_mem -> mem_wb in lockstep with the instruction.
  logic [kronos_pkg::XLEN-1:0] ex1_ex2_csr_new_val_q;
  // Stage 7a — fflags pipeline.  fpu_fflags is valid when fpu_out_valid pulses
  // at the EX1 stage of the FP arith instruction.  The architectural fflags
  // accumulate moves to retire so an in-flight CSR write to fflags / fcsr
  // ahead of the FP arith cannot overwrite the per-op flags after the FPU
  // completed but before that earlier writer reached WB (visible on every
  // ACT4-s5 F-/D- test as bad fflags=0 vs expected NX/NV/etc.).
  logic [4:0]                  ex1_ex2_fflags_q;
  logic [4:0]                  ex2_mem_fflags_q;
  logic [4:0]                  mem1_mem2_fflags_q;
  logic [4:0]                  mem_wb_fflags_q;
  // Stage 7a — FP-arith retire flag pipe so the CSR's fflags-accumulate gate
  // can fire only when the retiring instruction is an FP arithmetic op.
  logic                        ex1_ex2_is_fp_arith_q;
  logic                        ex2_mem_is_fp_arith_q;
  logic                        mem1_mem2_is_fp_arith_q;
  logic                        mem_wb_is_fp_arith_q;

  // STAGE3: fetch control (icache replaces old FSM)
  logic         instr_fetch_stall               /* verilator public_flat_rd */;
  logic         combined_stall                  /* verilator public_flat_rd */;
  logic         combined_stall_no_muldiv;

  // I-cache interface signals — BOOM-style v3 IFU.  The icache no longer
  // exposes data_valid_o / data_o / stall_o; it pushes (pc,data) tuples into
  // kronos_fetch_buffer via the s2_enq_* handshake.
  logic        icache_miss_pulse                 /* verilator public_flat_rd */;
  logic        fence_i_pulse;
  logic        fence_i_pulse_raw;
  logic        fence_i_active_q                 /* verilator public_flat_rd */;
  logic        dcache_flush_done;
  logic        dcache_dirty_pending;
  // FENCE.I trap suppression while D-cache holds dirty lines.
  logic        fence_i_dirty_block;
  // I-cache fetch address — now equal to s0_pc_q (next-fetch PC).  Kept under
  // the same name so PMP / iTLB / PTW lookups don't have to be retargeted.
  logic [31:0] icache_fetch_addr;

  // IFU control (BOOM-style)
  logic [31:0] s0_pc_q;                  // IFU's next-fetch PC
  logic        s0_valid_to_icache;
  logic        s0_ready_from_icache;
  logic        s0_accept;
  logic        s1_kill, s2_kill;
  logic        redirect_load;
  logic [31:0] redirect_target;
  // icache miss-event resync (drives s0_pc_q rewind after a real S2 miss).
  logic        icache_miss_event;
  logic [31:0] icache_miss_resync_pc;

  // icache <-> FB
  logic        ic_to_fb_valid;
  logic [31:0] ic_to_fb_pc;
  logic [31:0] ic_to_fb_data;
  logic        fb_enq_ready;

  // FB <-> predecode
  logic        fb_to_pd_valid;
  logic [31:0] fb_to_pd_pc;
  logic [31:0] fb_to_pd_data;
  logic        fb_to_pd_ready;

  // Predecode-emitted PC (architectural).  Drives if_id_q.pc, the bpred
  // lookup, and pc_q.  In the BOOM-style model, the architectural PC at
  // decode is whatever the FB head says (carried with the data), not a
  // separately tracked sequential counter.
  logic [31:0] predecode_instr_pc;

  // Predecode -> IF/ID consumer-facing aliases (replace align_*).  Wired below.
  logic [kronos_pkg::INST_W-1:0] align_instr                       /* verilator public_flat_rd */;
  logic              align_instr_valid                 /* verilator public_flat_rd */;
  logic              align_is_16b;
  logic              align_stall;
  logic              align_need_upper;
  logic              align_needs_fetch;

  // STAGE3: branch predictor
  logic        pred_taken;
  logic [31:0] pred_target;
  // Registered prediction signals.  pred_taken is sampled at the cycle the
  // branch is captured into IF/ID and replayed one cycle later to drive the
  // IFU redirect.  Decoupling pred_taken from the combinational redirect_load
  // breaks the long predecode_instr_pc → bpred → pred_taken → s2_kill →
  // fb_flush → predecode_flush path and removes one full IFU+FB+predecode
  // flush per predicted-taken branch from the critical loop.
  logic        pred_taken_q;
  logic [31:0] pred_target_q;
  logic        bpred_update_en;
  logic        actual_taken;
  logic        bpred_mispredict;
  logic        bpred_mispredict_target; // MEM-stage: predicted target ≠ actual target
  logic mem_redirect_d;
  logic mem_redirect_q;
  logic        is_branch_or_jump;

  // STAGE5a: FRM/FCSR RAW hazard detection signals for u_hazard
  logic        id_ex_is_frm_write;
  logic        if_id_fp_dyn_rm;

  // -------------------------------------------------------------------------
  // MEM-stage wires (64-bit lsu data)
  // -------------------------------------------------------------------------
  logic [kronos_pkg::XLEN-1:0]  lsu_rdata;
  logic             lsu_valid;
  logic             mem_stall                    /* verilator public_flat_rd */;
  logic             lsu_mem_stall;
  // mem_done_q: set when LSU signals valid_o; cleared when MEM/WB register
  // advances.  Gates req_i so LSU does not re-issue while the pipeline is
  // frozen by instr_fetch_stall.
  logic             mem_done_q;
  logic [kronos_pkg::XLEN-1:0]  lsu_rdata_latch;  // holds rdata across the stall gap
  logic             amo_write_latch;  // holds is_amo_write across the stall gap

  // D-cache interface (LSU ↔ dcache)
  logic            dcache_req;
  logic [kronos_pkg::XLEN-1:0] dcache_addr;
  logic [2:0]      dcache_size;
  logic            dcache_we;
  logic [kronos_pkg::XLEN-1:0] dcache_wdata;
  logic            dcache_amo_req;
  logic [4:0]      dcache_amo_op;
  logic            dcache_data_valid;
  logic [kronos_pkg::XLEN-1:0] dcache_rdata;
  logic            dcache_sc_success;
  logic            dcache_stall                      /* verilator public_flat_rd */;
  logic            dcache_miss_pulse                 /* verilator public_flat_rd */;
  // PMA fault wires from dcache (routed to trap path).
  // dcache_amo_nc_fault is retained for the LSU mem_stall exemption only;
  // the trap-path uses the EX-stage ex_amo_nc_fault below for correct
  // trap_cause/mepc sourcing while rr_ex1_q still holds the offending op.
  logic        dcache_amo_nc_fault;
  logic        dcache_bus_err_fault;
  // EX-stage pre-launch wires for the dcache BRAM read.  The dTLB
  // produces the translated PA combinationally in EX; the dcache uses
  // these to fire the BRAM read one cycle ahead of the MEM-stage req_i.
  logic [63:0] dcache_early_addr;
  logic        dcache_early_req_valid;

  // LSU FP response
  logic             lsu_fp_dest;
  logic [kronos_pkg::FLEN-1:0]  lsu_fp_rdata;

  // -------------------------------------------------------------------------
  // WB-stage wires (64-bit)
  // -------------------------------------------------------------------------
  logic [kronos_pkg::XLEN-1:0] wb_result_64;

  // -------------------------------------------------------------------------
  // FPU wires
  // -------------------------------------------------------------------------
  // Dispatch control: one-shot dispatch guard
  logic            fp_inflight_q;       // FPU is computing
  logic            fpu_dispatched_q;    // dispatch has fired for current EX instr
  logic            fpu_out_valid;
  logic [kronos_pkg::FLEN-1:0] fpu_result;
  logic [4:0]      fpu_fflags;
  fpu_tag_t        fpu_tag_out;
  logic            fpu_busy;
  fpu_tag_t        fpu_tag_in;

  // FP stall
  logic        fpu_stall;
  logic        fpu_dispatching;  // combinational: dispatch will fire this cycle

  // Stage 5h event taxonomy: replicated copies of the load-use / FP load-use
  // / JALR-forward / FRM-hazard expressions that already live inside
  // rtl/stage1/kronos_hazard.sv.  Re-derived here so we can publish them on
  // event_bus without adding output ports to the shared hazard module
  // (which would force every stage's top.sv to be updated).
  logic load_use_event;
  logic fp_load_use_event;
  logic jalr_fwd_event;

  // Sdtrig (trigger module) interface
  logic            trig_hit;
  logic [31:0]     trig_hit_pc;
  logic [kronos_pkg::XLEN-1:0] trig_csr_rdata;
  logic            trig_csr_match;
  logic            trig_csr_we;
  logic [kronos_pkg::XLEN-1:0] trig_csr_wdata;

  // post-write CSR value piped from u_csr → ex1_ex2 → ex2_mem → mem_wb pipe
  // → retire trace / retire_csr_new_val_i.  csr_new_val_post is the
  // combinational output of u_csr at the EX1 stage; the pipe (ex1_ex2_csr_new_val_q
  // declared above, then ex2_mem_csr_new_val_q, then mem_wb_csr_new_val_q)
  // carries it forward in lockstep with the instruction so retire commits the
  // correct post-write value.
  logic [kronos_pkg::XLEN-1:0] csr_new_val_post;
  logic [kronos_pkg::XLEN-1:0] ex2_mem_csr_new_val_q;
  logic [kronos_pkg::XLEN-1:0] mem1_mem2_csr_new_val_q;
  logic [kronos_pkg::XLEN-1:0] mem_wb_csr_new_val_q;

  // Stage 7a — registered trap_cause / trap_tval / irq_cause / priv at the
  // EX2→MEM boundary.  Captured alongside mem_wb_q.fault so trap_i fires from
  // mem_wb_q-cycle (retire) state, in lockstep with mem_redirect_q.
  // Without these snapshots, trap_cause would read live combinational sources
  // (rr_ex1_q.dec.illegal, irq_cause, …) that have advanced to the next
  // instruction by the time the trap fires.
  logic [31:0] mem_wb_trap_cause_q;
  logic [31:0] mem_wb_trap_tval_q;
  // pmp fetch / data fault address snapshots, captured at EX2→MEM so the
  // trap_tval at retire matches the offending PA / VA.
  logic [55:0] mem_wb_pmp_fetch_addr_q;
  logic [55:0] mem_wb_pmp_data_addr_q;
  // mem-cycle trap_cause / trap_tval combinational form (read at EX2→MEM
  // boundary by the snapshot flop).  Computed from ex2_mem1_q registered fields
  // + MEM-cycle producers — none of which read rr_ex1_q, so the trap context
  // tracks the trapping instruction even after the pipeline advances.
  logic [31:0] mem_trap_cause_d;
  logic [31:0] mem_trap_tval_d;
  // OR-reduction over every trap-class fault bit in mem_wb_q.fault (excludes
  // is_mret/is_sret because they are commit signals, and bpred_*_mispredict
  // because they are pure redirects).  Used to compute retire_i and trap_i.
  logic        mem_wb_fault_any_trap;

  // ---- Stage 5c/e performance-counter event bus ----
  logic        bpred_mispredict_pulse;
  logic        fpu_busy_any;
  logic        trap_taken_pulse                  /* verilator public_flat_rd */;
  logic [31:0] event_bus                        /* verilator public_flat_rd */;
  // Retire driver pulse (combinational): mem_wb_q advances past WB this cycle.
  logic        retire_advance;

  // FPU result latch: captures fpu_result when fpu_out_valid fires so the
  // result survives instr_fetch_stall cycles that may hold combined_stall=1
  // even after fpu_stall drops to 0.
  logic            fp_result_valid_q;
  logic [kronos_pkg::FLEN-1:0] fp_result_q;
  fpu_tag_t        fp_tag_q;
  // Stage 7a — fflags companion latch.  Captures fpu_fflags at fpu_out_valid
  // so the EX1→EX2 boundary can copy them alongside the FP result and the
  // pipeline can defer the architectural fflags accumulate to retire.  Without
  // this latch the per-FP-op fflags would commit at fpu_out_valid (one cycle)
  // and a still-in-flight CSR write to fflags / fcsr (e.g. an `fsflagsi 0`
  // ahead of the same FP arith) overwrites the accumulation when the writer
  // finally retires.  Pipelining fflags to retire keeps both writers in
  // program order.
  logic [4:0]      fp_fflags_q;
  // Combinatorial: current FPU fflags (just-fired or latched)
  logic [4:0]      fp_fflags_cur;

  // Combinatorial: current FPU result (just-fired or latched)
  logic            fp_result_avail;
  logic [kronos_pkg::FLEN-1:0] fp_result_cur;
  fpu_tag_t        fp_tag_cur;

  // FPU operand muxes: EX forwarding for integer-source FP instructions.
  // FMV.W.X / FMV.D.X read integer rs1/rs2; use fwd_rs1/2_data so that
  // MEM-WB bypassing applies (rr_ex1_q.rs1_data may be stale when the
  // producer was still in MEM when the FP instruction was in ID).
  logic [kronos_pkg::FLEN-1:0] fpu_a_i, fpu_b_i;

  // FP regfile write port signals
  logic            fp_we;
  logic [4:0]      fp_wa;
  logic [kronos_pkg::FLEN-1:0] fp_wd;

  // -------------------------------------------------------------------------
  // PC next (combinational)
  // -------------------------------------------------------------------------
  logic [31:0] pc_d                              /* verilator public_flat_rd */;

  // -------------------------------------------------------------------------
  // Submodule output sinks — ports we don't observe at this top.
  // Named sinks (vs `()` empty connections) keep Verilator's PINCONNECTEMPTY
  // happy; the OR-reduction at the bottom of the module hands them to a
  // single _unused_pinconnect signal so UNUSEDSIGNAL stays clean too.
  // -------------------------------------------------------------------------
  logic        decode_illegal_unused;     // u_decode.illegal_insn_o (mirrored in id_dec.illegal)
  logic        muldiv_busy_unused;        // u_muldiv.busy_o (top observes valid/idle)
  logic        csr_valid_unused;          // u_csr.valid_o   (1-cycle internal ack)
  // CSR sfence_*_o pins are pure passthroughs of the matching sfence_*_i
  // inputs. The top wires the local sfence_* signals straight to both TLBs,
  // so the CSR-side mirrors are unobserved.
  logic                          sfence_vma_csr_unused;
  logic [kronos_pkg::XLEN-1:0]   sfence_va_csr_unused;
  logic [15:0]                   sfence_asid_csr_unused;
  logic                          sfence_va_valid_csr_unused;
  logic                          sfence_asid_valid_csr_unused;
  logic        lsu_sc_success_unused;     // u_lsu.sc_success_o (also packed into rdata_o)

  // -------------------------------------------------------------------------
  // Aggregated UNUSED sinks.
  // Submodule outputs that are "computed but not observed at this top"
  // (legacy pre-stage-6 hooks, integrator-visible signals not yet wired)
  // funnel through these OR-reductions.  Keeps every signal driven and
  // consumed without forcing the integrator to disable UNUSEDSIGNAL.
  // -------------------------------------------------------------------------
  logic _unused_top_signals;
  logic _unused_top_pinconnect;

  // =========================================================================
  // Submodule instantiations
  // =========================================================================

  kronos_decode u_decode (
    .instr_i        (if_id_q.instr),
    .frm_i          (frm),
    .decoded_o      (id_dec),
    // illegal_insn_o is mirrored into id_dec.illegal; tied to a named sink.
    .illegal_insn_o (decode_illegal_unused)
  );

  kronos_regfile u_regfile (
    .clk_i       (clk_i),
    .rs1_addr_i  (id_rr_q.dec.rs1),
    .rs2_addr_i  (id_rr_q.dec.rs2),
    .rs1_rdata_o (rs1_rdata_64),
    .rs2_rdata_o (rs2_rdata_64),
    .rd_addr_i   (mem_wb_q.dec.rd),
    .rd_wen_i    (mem_wb_q.valid & mem_wb_q.dec.rd_wen & ~mem_wb_q.dec.rd_fp),
    .rd_wdata_i  (wb_result_64)
  );

  // FP register file
  kronos_regfile_fp u_regfile_fp (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .ra1_i   (id_rr_q.dec.rs1),
    .rd1_o   (fp_rd1),
    .ra2_i   (id_rr_q.dec.rs2),
    .rd2_o   (fp_rd2),
    .ra3_i   (id_rr_q.dec.rs3),
    .rd3_o   (fp_rd3),
    .wa_i    (fp_wa),
    .wd_i    (fp_wd),
    .we_i    (fp_we)
  );

  kronos_forward u_forward (
    .if_id_rs1_i        (id_dec.rs1),
    .if_id_rs1_used_i   (id_dec.rs1_used),
    .if_id_rs2_i        (id_dec.rs2),
    .if_id_rs2_used_i   (id_dec.rs2_used),
    // RR producer (id_rr_q) — freshest source.  is_load suppression mirrors
    // the EX1/EX2 producer slots: the load result lands via wb_result_64 once
    // mem_wb_q catches it; bypassing it earlier would forward stale alu_result.
    .id_rr_rd_i         (id_rr_q.dec.rd),
    .id_rr_rd_wen_i     (id_rr_q.dec.rd_wen),
    .id_rr_rd_fp_i      (id_rr_q.dec.rd_fp),
    .id_rr_is_load_i    (id_rr_q.dec.wb_sel == WB_MEM),
    .id_rr_valid_i      (id_rr_q.valid),
    // EX1 producer (rr_ex1_q).  is_load suppresses bypass because load data
    // has not yet reached ex1_ex2_q.alu_result at consumer-EX1.
    .rr_ex1_rd_i        (rr_ex1_q.dec.rd),
    .rr_ex1_rd_wen_i    (rr_ex1_q.dec.rd_wen),
    .rr_ex1_rd_fp_i     (rr_ex1_q.dec.rd_fp),
    .rr_ex1_is_load_i   (rr_ex1_q.dec.wb_sel == WB_MEM),
    .rr_ex1_valid_i     (rr_ex1_q.valid),
    // EX2 producer (ex1_ex2_q).  Loads suppress for the same reason.
    .ex1_ex2_rd_i       (ex1_ex2_q.dec.rd),
    .ex1_ex2_rd_wen_i   (ex1_ex2_q.dec.rd_wen),
    .ex1_ex2_rd_fp_i    (ex1_ex2_q.dec.rd_fp),
    .ex1_ex2_is_load_i  (ex1_ex2_q.dec.wb_sel == WB_MEM),
    .ex1_ex2_valid_i    (ex1_ex2_q.valid),
    // MEM1 producer (ex2_mem1_q).  No load-suppression here: a load producer
    // in MEM1 at ID-time T becomes the MEM2 producer at consumer-RR-time T+1,
    // and FWD_MEM2 picks lsu_rdata combinationally for that case.
    .ex2_mem1_rd_i      (ex2_mem1_q.dec.rd),
    .ex2_mem1_rd_wen_i  (ex2_mem1_q.dec.rd_wen),
    .ex2_mem1_rd_fp_i   (ex2_mem1_q.dec.rd_fp),
    .ex2_mem1_valid_i   (ex2_mem1_q.valid),
    // MEM2 producer (mem1_mem2_q) — load value combinational via lsu_rdata.
    .mem1_mem2_rd_i     (mem1_mem2_q.dec.rd),
    .mem1_mem2_rd_wen_i (mem1_mem2_q.dec.rd_wen & mem1_mem2_q.valid),
    .mem1_mem2_rd_fp_i  (mem1_mem2_q.dec.rd_fp),
    .fwd_rs1_sel_o      (fwd_rs1_sel),
    .fwd_rs2_sel_o      (fwd_rs2_sel)
  );

  // STAGE3: combined_stall — mem_stall | muldiv_stall | instr_fetch_stall | fpu_stall
  // muldiv_stall is exposed raw (no redirect gating) — kronos_hazard resolves
  // the priority so a redirect flushes the wrong-path MUL without needing
  // muldiv_stall to fan in from ex_redirect/mem_redirect.
  assign muldiv_stall      = rr_ex1_q.valid & rr_ex1_q.dec.is_muldiv & ~muldiv_valid;
  // when a PMP fetch fault is active, the alignment unit suppresses
  // its instr_valid_o (see kronos_align.sv).  We must NOT treat this as a
  // pipeline stall, because the same fault asserts trap_i and ex_redirect to
  // the trap vector — gating pc_en off via instr_fetch_stall would prevent the
  // PC from reaching mtvec, and the pipeline would resume executing at the
  // faulting PC in M-mode instead of taking the trap.
  // Per Stage 6f v3 spec: the icache no longer emits a stall wire; FB-not-empty
  // visible as align_instr_valid is the only fetch-side stall signal.  PMP
  // fetch fault is excluded so trap delivery is not gated by it.  Also
  // suppress under an active redirect — during a redirect cycle the IF/ID
  // register is being flushed (rr_ex1_flush from hazard), so holding the
  // pipeline on "no fresh fetch" would freeze the stage that needs to drain
  // the wrong-path JAL/branch out of EX.
  assign instr_fetch_stall = ~align_instr_valid & ~pmp_fetch_fault &
                             ~redirect_load;

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
  // Stage 7a — detect FENCE.I from ex1_ex2_q (EX2) rather than rr_ex1_q (EX1).
  // The EX1/EX2 split moves the SW one cycle further from dcache_req issue
  // (which fires from MEM = ex2_mem1_q).  If we triggered from EX1, FENCE.I
  // would be one cycle ahead of the dirtying SW's dcache_req cycle and
  // dcache_dirty_pending would still be 0 — so fence_i_pulse would fire
  // immediately and the SW's bytes would not yet be in AXI memory by the
  // time the icache reloads.  Detecting at EX2 keeps the original stage-6
  // ordering: the in-flight SW is now in MEM, has already committed to
  // dcache, and dcache_dirty_pending=1 so the FENCE.I drain triggers.
  assign fence_i_pulse_raw = ex1_ex2_q.valid &
                             ~lsu_mem_stall & ~instr_fetch_stall &
                             ~fpu_stall & ~muldiv_stall &
                             (ex1_ex2_q.instr[6:0]   == 7'b0001111) &
                             (ex1_ex2_q.instr[14:12] == 3'b001);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fence_i_active_q <= 1'b0;
    end else if (fence_i_pulse_raw & dcache_dirty_pending & ~fence_i_active_q) begin
      fence_i_active_q <= 1'b1;
    end else if (dcache_flush_done) begin
      fence_i_active_q <= 1'b0;
    end
  end

  assign fence_i_pulse = fence_i_pulse_raw &
                         (~dcache_dirty_pending | dcache_flush_done);
  // fpu_dispatching: the FPU dispatch will fire this cycle.  Stall immediately
  // so the following instruction stays in IF/ID and can receive the FP result
  // via the ID forwarding mux when the stall releases.
  assign fpu_dispatching   = rr_ex1_q.valid & rr_ex1_q.dec.is_fp &
                             ~rr_ex1_q.dec.fp_load & ~rr_ex1_q.dec.fp_store &
                             ~fpu_dispatched_q;
  // fp_result_avail: FPU result is available (just fired this cycle or latched
  // from a previous cycle where fpu_out_valid fired but the pipeline was still
  // stalled by instr_fetch_stall or mem_stall).
  assign fp_result_avail   = fpu_out_valid | fp_result_valid_q;
  assign fp_result_cur     = fpu_out_valid ? fpu_result  : fp_result_q;
  assign fp_tag_cur        = fpu_out_valid ? fpu_tag_out : fp_tag_q;
  // Stage 7a — match the result mux: live fflags when FPU just fired,
  // otherwise the latched copy from the cycle the FPU completed during
  // a combined_stall window.
  assign fp_fflags_cur     = fpu_out_valid ? fpu_fflags  : fp_fflags_q;
  // Release stall once the result is available; keep stalled until then.
  assign fpu_stall         = (fp_inflight_q | fpu_dispatching) & ~fp_result_avail;

  assign load_use_event = rr_ex1_q.valid & rr_ex1_q.dec.is_load & (rr_ex1_q.dec.rd != 5'd0)
                         & ((id_dec.rs1_used & (id_dec.rs1 == rr_ex1_q.dec.rd)) |
                            (id_dec.rs2_used & (id_dec.rs2 == rr_ex1_q.dec.rd)));

  assign fp_load_use_event = rr_ex1_q.valid & rr_ex1_q.dec.fp_load & (rr_ex1_q.dec.rd != 5'd0)
                            & ((id_dec.rs1_fp & (id_dec.rs1 == rr_ex1_q.dec.rd)) |
                               (id_dec.rs2_fp & (id_dec.rs2 == rr_ex1_q.dec.rd)) |
                               (id_dec.rs3_fp & (id_dec.rs3 == rr_ex1_q.dec.rd)));

  assign jalr_fwd_event = id_dec.is_jalr & ex2_mem1_q.valid & ex2_mem1_q.dec.rd_wen
                         & (ex2_mem1_q.dec.rd != 5'd0) & (id_dec.rs1 == ex2_mem1_q.dec.rd);

  // Non-muldiv stall sources that hazard must observe with absolute priority
  // (bus/FPU/fetch can't be abandoned mid-flight by a redirect).  muldiv_stall
  // is fed to hazard separately so redirect flush can out-rank it.
  //
  // a dTLB miss for an EX-stage load/store/AMO must freeze the
  // pipeline.  The dTLB lookup happens in EX (against rr_ex1_q) but the LSU
  // fires in MEM (against ex2_mem1_q).  Without this stall, the missing access
  // would advance to MEM with a stale ex2_mem_data_pa_q (captured before the
  // PTW completed) and complete via the dcache before ptw_pf could fire.
  //
  // Qualifications:
  //   - rr_ex1_q.valid          -> ignore phantom misses on bubbles
  //   - ~load/store_page_fault -> let the PTW's page-fault pulse take the
  //     trap on the same cycle (otherwise dtlb_miss stays high through the
  //     fault cycle and combined_stall blocks the redirect).
  //
  // itlb_miss is already covered by instr_fetch_stall (the icache refuses
  // to issue the AR while tlb_miss_i is high, so align_instr_valid stays
  // low until the PTW refills).
  assign combined_stall_no_muldiv = mem_stall | instr_fetch_stall | fpu_stall
                                  | (ex2_mem1_q.valid & dtlb_miss &
                                     ~mem1_load_page_fault & ~mem1_store_page_fault);
  assign combined_stall    = combined_stall_no_muldiv | muldiv_stall;

  // FRM/FCSR RAW hazard: a CSR write to FRM/FCSR in EX will update fcsr_q at
  // the posedge, but decode reads frm combinatorially from fcsr_q. Stall 1
  // cycle so the FP instruction in ID re-decodes after the new FRM is visible.
  assign id_ex_is_frm_write = rr_ex1_q.valid & rr_ex1_q.dec.is_csr &
                               (rr_ex1_q.dec.csr_addr == 12'h002 |  // FRM
                                rr_ex1_q.dec.csr_addr == 12'h003);  // FCSR
  // Detect FP instruction in ID that uses dynamic rounding mode (rm=3'b111).
  // Covers OP-FP (0x53) and FMA variants (0x43/0x47/0x4B/0x4F).
  assign if_id_fp_dyn_rm    = if_id_q.valid &
                               (if_id_q.instr[14:12] == 3'b111) &
                               (if_id_q.instr[6:0] == 7'b1010011 |  // OP-FP
                                if_id_q.instr[6:0] == 7'b1000011 |  // FMADD
                                if_id_q.instr[6:0] == 7'b1000111 |  // FMSUB
                                if_id_q.instr[6:0] == 7'b1001011 |  // FNMSUB
                                if_id_q.instr[6:0] == 7'b1001111);  // FNMADD

  kronos_hazard u_hazard (
    // RR producer (id_rr_q) — load-use, csr-raw, and uses_csr arms.
    .id_rr_is_load_i       (id_rr_q.dec.is_load),
    .id_rr_is_fp_load_i    (id_rr_q.dec.fp_load),
    .id_rr_is_csr_i        (id_rr_q.dec.is_csr),
    .id_rr_rd_i            (id_rr_q.dec.rd),
    .id_rr_valid_i         (id_rr_q.valid),
    // uses_csr already AND-folds id_rr_q.valid; do not double-gate downstream.
    .id_rr_uses_csr_i      (id_rr_q.valid & (id_rr_q.dec.is_csr | id_rr_q.dec.is_mret |
                                              id_rr_q.dec.is_sret | id_rr_q.dec.is_wfi |
                                              id_rr_q.dec.is_ecall | id_rr_q.dec.is_ebreak)),
    // EX1 producer (rr_ex1_q).
    .rr_ex1_is_load_i      (rr_ex1_q.dec.is_load),
    .rr_ex1_is_fp_load_i   (rr_ex1_q.dec.fp_load),
    .rr_ex1_is_csr_i       (rr_ex1_q.dec.is_csr),
    .rr_ex1_is_frm_write_i (id_ex_is_frm_write),
    .rr_ex1_rd_i           (rr_ex1_q.dec.rd),
    .rr_ex1_valid_i        (rr_ex1_q.valid),
    // EX2 producer (ex1_ex2_q).
    .ex1_ex2_is_load_i     (ex1_ex2_q.dec.is_load),
    .ex1_ex2_is_fp_load_i  (ex1_ex2_q.dec.fp_load),
    .ex1_ex2_is_csr_i      (ex1_ex2_q.dec.is_csr),
    .ex1_ex2_rd_i          (ex1_ex2_q.dec.rd),
    .ex1_ex2_rd_wen_i      (ex1_ex2_q.dec.rd_wen),
    .ex1_ex2_valid_i       (ex1_ex2_q.valid),
    // MEM1 producer (ex2_mem1_q).
    .ex2_mem1_is_load_i    (ex2_mem1_q.dec.is_load),
    .ex2_mem1_is_fp_load_i (ex2_mem1_q.dec.fp_load),
    .ex2_mem1_is_csr_i     (ex2_mem1_q.dec.is_csr),
    .ex2_mem1_rd_i         (ex2_mem1_q.dec.rd),
    .ex2_mem1_rd_wen_i     (ex2_mem1_q.dec.rd_wen & ex2_mem1_q.valid),
    .ex2_mem1_valid_i      (ex2_mem1_q.valid),
    // MEM2 producer (mem1_mem2_q).
    .mem1_mem2_is_csr_i    (mem1_mem2_q.dec.is_csr),
    .mem1_mem2_rd_i        (mem1_mem2_q.dec.rd),
    .mem1_mem2_valid_i     (mem1_mem2_q.valid),
    // ID-stage register addresses.
    .if_id_rs1_used_i      (id_dec.rs1_used),
    .if_id_rs1_i           (id_dec.rs1),
    .if_id_rs2_used_i      (id_dec.rs2_used),
    .if_id_rs2_i           (id_dec.rs2),
    .if_id_rs1_fp_i        (id_dec.rs1_fp),
    .if_id_rs2_fp_i        (id_dec.rs2_fp),
    .if_id_rs3_fp_i        (id_dec.rs3_fp),
    .if_id_rs3_i           (id_dec.rs3),
    .if_id_is_jalr_i       (id_dec.is_jalr),
    .if_id_fp_dyn_rm_i     (if_id_fp_dyn_rm),
    .if_id_uses_csr_i      (if_id_q.valid & (id_dec.is_csr | id_dec.is_mret |
                                              id_dec.is_sret | id_dec.is_wfi |
                                              id_dec.is_ecall | id_dec.is_ebreak)),
    // OR fence_i_redirect_q into the EX-redirect input so the cycle the
    // FENCE.I redirect fires also flushes the wrong-path follower in
    // if_id_q / rr_ex1_q.  Without this, the post-FENCE.I bytes the IFU
    // streams in during the 2-cycle gap before mem_redirect_q to mtvec
    // would propagate through the fault-bit pipeline and trigger
    // spurious bpred_dir_mispredict / bpred_mispredict_target events.
    .ex_redirect_i         (ex_redirect_q | fence_i_redirect_q),
    .mem_redirect_i        (mem_redirect_q),
    .mem_stall_i           (combined_stall_no_muldiv),
    .muldiv_stall_i        (muldiv_stall),
    .pc_en_o               (pc_en),
    .if_id_en_o            (if_id_en),
    .id_rr_en_o            (id_rr_en),
    .rr_ex1_en_o           (rr_ex1_en),
    .ex2_mem1_en_o         (ex2_mem1_en),
    .mem1_mem2_en_o        (mem1_mem2_en),
    .mem_wb_en_o           (mem_wb_en),
    .if_id_flush_o         (if_id_flush),
    .id_rr_flush_o         (id_rr_flush),
    .rr_ex1_flush_o        (rr_ex1_flush),
    // ex2_mem1_flush / mem1_mem2_flush are driven by kronos_top assigns from
    // mem_redirect_q | mem_redirect_d (see lines below).  hazard's flush
    // outputs for these stages are always 0 and intentionally unconnected.
    .ex2_mem1_flush_o      (),
    .mem1_mem2_flush_o     ()
  );

  kronos_alu u_alu (
    .op_i        (rr_ex1_q.dec.alu_op),
    .a_i         (alu_a),
    .b_i         (alu_b),
    .word_op_i   (rr_ex1_q.dec.is_word_op),
    .result_o    (alu_result),
    .adder_out_o (alu_adder_out),
    .cmp_lt_o    (alu_cmp_lt),
    .eq_o        (alu_eq)
  );

  kronos_muldiv u_muldiv (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .req_i     (rr_ex1_q.valid & rr_ex1_q.dec.is_muldiv & muldiv_idle & ~mem_stall
               & ~ex_redirect_q & ~mem_redirect_q),
    .op_i      (rr_ex1_q.dec.muldiv_op),
    .a_i       (fwd_rs1_data),
    .b_i       (fwd_rs2_data),
    .word_op_i (rr_ex1_q.dec.is_word_op),
    .result_o  (muldiv_result),
    // busy_o is internal hand-off only; the top observes muldiv_valid/idle.
    .busy_o    (muldiv_busy_unused),
    .valid_o   (muldiv_valid),
    .idle_o    (muldiv_idle)
  );

  assign ex_result = rr_ex1_q.dec.is_muldiv ? muldiv_result : alu_result;

  // MISA_EXT = I + M + A + C + F + D extension bits (bits 8,12,0,2,5,3) = 26'h112D
  kronos_csr #(.MISA_EXT(26'h112D)) u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    // EX1-cycle access — drives the combinational read path and trig_csr_we_o.
    // No longer ANDed with ~combined_stall: req_i has no architectural-state
    // side effects in Stage 7a (state writes commit on retire_i below), so
    // dropping the gate breaks the combined_stall→csr.req_i→csr_illegal→
    // ex_redirect→combined_stall loop noted in stage6 kronos_top.sv:807.
    .req_i         (rr_ex1_q.valid & rr_ex1_q.dec.is_csr),
    .addr_i        (rr_ex1_q.dec.csr_addr),
    .funct3_i      (rr_ex1_q.dec.csr_funct3),
    .use_imm_i     (rr_ex1_q.dec.csr_use_imm),
    .rs1_data_i    (fwd_rs1_data),
    .rs1_addr_i    (rr_ex1_q.dec.rs1),
    .rdata_o       (csr_rdata),
    // RR-stage second read port — combinational read on id_rr_q.dec.csr_addr.
    // Captured into rr_ex1_q.csr_rdata at the RR/EX1 boundary so the EX1 cycle
    // does not see a combinational CSR-file read in front of the bypass mux.
    .rr_csr_addr_i    (id_rr_q.dec.csr_addr),
    .rr_csr_read_en_i (id_rr_q.valid & id_rr_q.dec.is_csr),
    .rr_csr_rdata_o   (rr_csr_rdata_combinational),
    // valid_o is the CSR's own one-cycle ack; the top tracks it via rr_ex1_q.
    .valid_o       (csr_valid_unused),
    // Stage 7a — retire-cycle CSR write commit.  Pulses for one cycle when a
    // non-trapping CSR instruction reaches MEM/WB.  Wrong-path instructions
    // killed by an earlier mem_redirect_q have mem_wb_q.valid=0 (the EX2→MEM
    // boundary clears valid when mem_redirect_q fires), so retire_i cannot
    // mutate CSR state from the redirect-shadow window.
    .retire_i              (mem_wb_q.valid & mem_wb_q.dec.is_csr &
                            ~mem_wb_fault_any_trap & ~combined_stall),
    .retire_addr_i         (mem_wb_q.dec.csr_addr),
    .retire_csr_new_val_i  (mem_wb_csr_new_val_q),
    // Stage 7a — trap_i / mret_i / sret_i fire from registered mem_wb_q.fault
    // bits, in lockstep with mem_redirect_q.  ~combined_stall keeps each pulse
    // to a single cycle while the trapping instruction sits at WB.
    .trap_i        (mem_wb_q.valid & mem_wb_fault_any_trap & ~combined_stall),
    .trap_pc_i     (mem_wb_q.pc),
    .trap_cause_i  (mem_wb_trap_cause_q),
    .trap_tval_i   (mem_wb_trap_tval_q),
    // EX1-cycle predictive trap_cause/class.  Drives trap_vector_o so the
    // redirect target captured at EX1→EX2 reflects medeleg/mideleg
    // delegation; the registered trap_cause_i above only commits at retire.
    .trap_cause_ex_i  (ex1_trap_cause),
    .trap_class_ex_i  (ex1_trap_class),
    .mret_i        (mem_wb_q.valid & mem_wb_q.fault.is_mret &
                    ~mem_wb_q.fault.mret_priv_fail & ~combined_stall),
    .sret_i        (mem_wb_q.valid & mem_wb_q.fault.is_sret &
                    ~mem_wb_q.fault.sret_priv_fail & ~combined_stall),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .sepc_o        (sepc),
    .priv_o        (priv_q),
    .mstatus_o     (mstatus),
    .csr_illegal_o (csr_illegal_raw),
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
    // FP CSR interface — Stage 7a defers the architectural fflags
    // accumulate to retire so an in-flight CSR write to fflags / fcsr ahead
    // of an FP arith op cannot overwrite the per-op flags after the FPU
    // completed but before the earlier writer reaches WB.  The pipeline
    // (ex1_ex2_fflags_q → ex2_mem_fflags_q → mem_wb_fflags_q) carries the
    // fpu_fflags alongside the FP arith instruction; mem_wb_is_fp_arith_q
    // gates the accumulate so non-FP retires (loads / stores / int ops) do
    // not OR a stale fflags value back into fcsr.  Gated by ~combined_stall
    // so a single retire fires the accumulate once.
    .fflags_delta_i (mem_wb_fflags_q),
    .fflags_we_i    (mem_wb_q.valid & mem_wb_is_fp_arith_q & ~combined_stall),
    .fp_rd_we_i     (fp_we),                // drives mstatus.FS=11 on FP writeback
    .frm_o          (frm),
    // Zicntr: pulse once per retired instruction.  Count at the EX→MEM
    // transition so the count is visible to a csrrc-instret two instructions
    // later (matches the SAIL reference-model semantics used by ACT4).
    .instret_retire_i (ex2_mem1_en & rr_ex1_q.valid & ~combined_stall),
    .event_bus_i      (event_bus),
    // Stage 5h
    .trig_csr_rdata_i (trig_csr_rdata),
    .trig_csr_match_i (trig_csr_match),
    .trig_csr_we_o    (trig_csr_we),
    .trig_csr_wdata_o (trig_csr_wdata),
    .csr_new_val_o    (csr_new_val_post),
    // SFENCE.VMA passthrough (decode → CSR → both TLBs).
    .sfence_vma_i        (sfence_vma),
    .sfence_va_i         (sfence_va),
    .sfence_asid_i       (sfence_asid),
    .sfence_va_valid_i   (sfence_va_valid),
    .sfence_asid_valid_i (sfence_asid_valid),
    // sfence_*_o pins are loop-back of sfence_*_i. The top wires the local
    // signals (sfence_vma, sfence_va, sfence_asid, sfence_va_valid,
    // sfence_asid_valid) directly to both TLBs below, so the CSR-side
    // mirrors are intentionally unused. Sink each into a named wire to
    // satisfy lint without breaking PINMISSING.
    .sfence_vma_o        (sfence_vma_csr_unused),
    .sfence_va_o         (sfence_va_csr_unused),
    .sfence_asid_o       (sfence_asid_csr_unused),
    .sfence_va_valid_o   (sfence_va_valid_csr_unused),
    .sfence_asid_valid_o (sfence_asid_valid_csr_unused),
    // satp fields broken out for the address-translation engine.
    .satp_mode_o         (satp_mode),
    .satp_asid_o         (satp_asid),
    .satp_ppn_o          (satp_ppn)
  );

  // External gate on csr_illegal_raw.  u_csr now computes the priv/counter
  // predicates unconditionally so csr_illegal_o doesn't depend on req_i (and
  // therefore doesn't drag combined_stall into the cone of ex_redirect).
  // The gate uses only registered rr_ex1_q fields, breaking the cycle:
  //   combined_stall -> csr.req_i -> csr_illegal -> ex_redirect ->
  //   redirect_load -> s0_valid_to_icache -> ... -> combined_stall.
  assign csr_illegal = rr_ex1_q.valid & rr_ex1_q.dec.is_csr & csr_illegal_raw;

  // ex_valid_i is intentionally NOT gated by ~combined_stall.  Closing
  // ~combined_stall here would form a comb loop:
  //   combined_stall -> trigger.ex_valid_i -> trigger.match_vec -> trig_hit
  //                  -> ex_redirect -> redirect_load -> s0_valid_to_icache
  //                  -> u_itlb -> ptw -> dcache -> lsu_mem_stall -> mem_stall
  //                  -> combined_stall.
  // The actual breakpoint trap is gated by ~combined_stall in u_csr (trap_i,
  // mret_i, sret_i are all `& ~combined_stall`-qualified), so the trap still
  // fires in the cycle the stall releases.  Widening trig_hit to the full
  // duration of a stall is benign: triggers_q[i].hit is sticky-set, so the
  // redundant assertions are idempotent, and ex_redirect was already free to
  // hold during stalls via other contributors (irq_pending, csr_illegal,
  // pmp/page faults).
  kronos_trigger u_trigger (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .csr_req_i     (rr_ex1_q.valid & rr_ex1_q.dec.is_csr & ~combined_stall),
    .csr_addr_i    (rr_ex1_q.dec.csr_addr),
    .csr_we_i      (trig_csr_we),
    .csr_wdata_i   (trig_csr_wdata),
    .csr_rdata_o   (trig_csr_rdata),
    .csr_match_o   (trig_csr_match),
    .ex_valid_i    (rr_ex1_q.valid),
    .ex_pc_i       (rr_ex1_q.pc),
    .ex_is_load_i  (rr_ex1_q.dec.is_load),
    .ex_is_store_i (rr_ex1_q.dec.is_store),
    .ex_mem_addr_i (alu_result),
    .hit_o         (trig_hit),
    .hit_pc_o      (trig_hit_pc)
  );

  // -------------------------------------------------------------------------
  // PMP — fetch-port and data-port instances.
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
    unique case (ex2_mem1_q.dec.mem_funct3)
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
  always_comb begin
    pmp_any_active = 1'b0;
    for (int i = 0; i < 16; i++) begin
      if (pmpcfg[i][4:3] != 2'b00) pmp_any_active = 1'b1;
    end
  end

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

  // pmp_fetch_fault back-edge cut.  pmp_fetch_fault_raw is gated by
  // u_pmp_fetch.valid_i = align_needs_fetch = s0_valid_to_icache.  Driving
  // ex_redirect / redirect_load directly off it closes a comb loop back to
  // s0_valid_to_icache (synth flagged as the 92-LUT LUTLP-1 cycle).  Flop
  // the gated fault and address; redirect_load sync-clears the flag so a
  // mem_redirect that wins the cycle discards any in-flight fetch fault.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pmp_s1_fetch_fault_q      <= 1'b0;
      pmp_s1_fetch_fault_addr_q <= 56'h0;
    end else if (redirect_load) begin
      pmp_s1_fetch_fault_q      <= 1'b0;
    end else begin
      pmp_s1_fetch_fault_q      <= pmp_fetch_fault_raw & pmp_any_active;
      pmp_s1_fetch_fault_addr_q <= pmp_fetch_fault_addr_raw;
    end
  end

  assign pmp_fetch_fault      = pmp_s1_fetch_fault_q;
  assign pmp_fetch_fault_addr = pmp_s1_fetch_fault_addr_q;

  kronos_pmp #(.N(16)) u_pmp_data (
    .pmpcfg_i     (pmpcfg),
    .pmpaddr_i    (pmpaddr),
    .priv_i       (priv_q),
    // valid_i must NOT depend on combined_stall.  combined_stall includes
    // mem_stall, which depends on lsu_mem_stall, which depends on pmp_fault_i
    // (suppressed by lsu when pmp_fault_i is high) — gating valid_i on
    // ~combined_stall would close a comb loop pmp_fault -> mem_stall ->
    // combined_stall -> valid_i -> pmp_fault.  The fault flag is meaningful
    // whenever a load/store sits in MEM1; the trap path gates trap_i with
    // ~combined_stall so the trap only fires when the pipeline advances.
    .valid_i      (ex2_mem1_q.valid &
                   (ex2_mem1_q.dec.is_load | ex2_mem1_q.dec.is_store |
                    ex2_mem1_q.dec.is_amo)),
    // PMP runs against the dTLB-translated PA at MEM1 (eff_data_pa).  Under
    // Bare/M-mode translation eff_data_pa == ex2_mem1_q.alu_result[31:0].
    .addr_i       ({24'b0, eff_data_pa[31:0]}),
    .size_i       (pmp_data_size),
    .is_fetch_i   (1'b0),
    .is_load_i    (ex2_mem1_q.dec.is_load |
                   (ex2_mem1_q.dec.is_amo & ex2_mem1_q.dec.is_lr)),
    .is_store_i   (ex2_mem1_q.dec.is_store |
                   (ex2_mem1_q.dec.is_amo & ~ex2_mem1_q.dec.is_lr)),
    .fault_o      (pmp_data_fault_raw),
    .fault_addr_o (pmp_data_fault_addr_raw)
  );

  // pmp_data_fault / pmp_data_fault_addr are produced live at MEM1 by
  // u_pmp_data and consumed combinationally at the MEM1->MEM2 register edge,
  // where they are flopped into mem1_mem2_q.fault.pmp_data_fault.  The 7b
  // pmp_s1_data_fault_q snapshot is no longer needed: the MEM1->MEM2 register
  // itself provides the flop barrier that breaks the post-PMP combinational
  // cone into the dcache hit-mux.
  assign pmp_data_fault      = pmp_data_fault_raw & pmp_any_active;
  assign pmp_data_fault_addr = pmp_data_fault_addr_raw;

  // PMA AMO-on-NC trap detection at MEM1 stage.  The check runs against the
  // dTLB-translated PA (eff_data_pa) so PMA decisions follow PMP — both work
  // off the same translated address.  Registered into
  // mem1_mem2_q.fault.ex_amo_nc_fault at the MEM1->MEM2 edge.
  always_comb begin
    mem1_addr_uncacheable = 1'b0;
    for (int r = 0; r < NUM_NC_REGIONS; r++) begin
      if (({32'b0, eff_data_pa[31:0]} >= NC_REGION_BASE[r]) &&
          ({32'b0, eff_data_pa[31:0]} <= NC_REGION_LIMIT[r])) begin
        mem1_addr_uncacheable = 1'b1;
      end
    end
  end
  assign mem1_amo_nc_fault = ex2_mem1_q.valid &
                             (ex2_mem1_q.dec.is_amo |
                              ex2_mem1_q.dec.is_lr |
                              ex2_mem1_q.dec.is_sc) &
                             mem1_addr_uncacheable;


  // -------------------------------------------------------------------------
  // priv-checked control transfers.
  //   - mret legal only from M-mode.
  //   - sret legal from M (any) or S (when mstatus.TSR=0).  U-mode → illegal.
  //   - SATP CSR access from S-mode is gated by mstatus.TVM.
  //   - WFI privilege gating (mstatus.TW) is deferred to Stage 6b alongside
  //     the MMU; no `is_wfi` decode bit exists yet.
  // -------------------------------------------------------------------------
  always_comb begin
    mret_priv_fail = rr_ex1_q.dec.is_mret & (priv_q != PRIV_M);
    sret_priv_fail = rr_ex1_q.dec.is_sret &
                     ( (priv_q == PRIV_U) |
                       ((priv_q == PRIV_S) & mstatus[22]) );  // TSR
    satp_tvm_fail  = rr_ex1_q.dec.is_csr &
                     (rr_ex1_q.dec.csr_addr == kronos_pkg::CSR_SATP) &
                     (priv_q == PRIV_S) & mstatus[20];       // TVM
  end

  // -------------------------------------------------------------------------
  // translation-enable + sfence pulse + wfi priv-fail.
  //
  // Per priv-spec § 4.4 (Sv39 / Sv48 translation):
  //   - Translation is active when satp.MODE != Bare AND effective_priv != M.
  //   - For data accesses, mstatus.MPRV (bit 17) replaces priv_q with
  //     mstatus.MPP (bits 12:11) when in M-mode.
  //   - For fetch, MPRV does not apply — always use priv_q.
  //
  // SFENCE.VMA pulses for one cycle when a SFENCE.VMA retires (rr_ex1_q.valid
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
  assign translate_data   = (satp_mode != kronos_pkg::SATP_MODE_BARE) & (eff_priv_data != PRIV_M);
  assign translate_fetch  = (satp_mode != kronos_pkg::SATP_MODE_BARE) & (priv_q != PRIV_M);

  assign sfence_vma         = rr_ex1_q.valid & rr_ex1_q.dec.is_sfence_vma & ~combined_stall;
  assign sfence_va          = fwd_rs1_data;
  assign sfence_asid        = fwd_rs2_data[15:0];
  assign sfence_va_valid    = (rr_ex1_q.dec.rs1 != 5'd0);
  assign sfence_asid_valid  = (rr_ex1_q.dec.rs2 != 5'd0);

  // wfi_priv_fail is intentionally NOT gated by ~combined_stall (closes #89).
  // The comb cone of ex_redirect must stay free of combined_stall.  The
  // actual trap is gated by ~combined_stall in u_csr.trap_i and the perf
  // counter trap_taken_pulse, so widening the predicate during stalls does
  // not double-fire the trap or skew event counts.
  assign wfi_priv_fail    = rr_ex1_q.valid & rr_ex1_q.dec.is_wfi &
                              (priv_q != PRIV_M) & mstatus[21] /*TW*/;

  // -------------------------------------------------------------------------
  // TLB-miss qualifiers.
  //
  // A miss is reported only when translation is active AND the lookup is being
  // presented to the TLB this cycle AND the TLB neither hit nor reported a
  // permission fault.  When a miss is asserted the LSU / I-cache stall their
  // own AXI activity (tlb_miss_i input), and the PTW kicks off a walk to fill
  // the TLB before the access is replayed.
  // -------------------------------------------------------------------------
  assign itlb_miss = translate_fetch & align_needs_fetch & ~itlb_hit & ~itlb_perm_fail;
  // A/D-bit driven re-walks.  An entry that hits with A=0, or a
  // store whose entry hits with D=0, must trigger the PTW to atomically set
  // the missing bit before the access completes.  Folded into dtlb_miss so
  // the same stall + replay machinery is reused — the PTW re-walks the page
  // table, performs an LR/SC on the leaf PTE to set A (and D for stores),
  // and refills the dTLB with the updated entry.  kronos_tlb invalidates
  // matching entries on refill so the stale A=1/D=0 line cannot keep
  // answering lookups at a lower index.
  // dtlb_miss now forms in MEM1 cycle (the dTLB lookup runs against
  // ex2_mem1_q.alu_result as VA).  PTW kicks off from this MEM1 miss signal.
  assign dtlb_miss = translate_data & ex2_mem1_q.valid &
                     (ex2_mem1_q.dec.is_load | ex2_mem1_q.dec.is_store |
                      ex2_mem1_q.dec.is_amo) &
                     ((~dtlb_hit & ~dtlb_perm_fail) | dtlb_a_zero | dtlb_d_zero);

  // PA muxes — when translation is off (Bare or M-mode), forward the original
  // virtual address as-is (the architectural PA == VA).  Otherwise use the
  // TLB lookup output.  eff_data_pa is a MEM1-cycle wire: it consumes
  // ex2_mem1_q.alu_result (the registered VA) and the live dTLB output.
  assign eff_fetch_pa = translate_fetch ? itlb_pa[31:0] : icache_fetch_addr;
  assign eff_data_pa  = translate_data  ? dtlb_pa[31:0] : ex2_mem1_q.alu_result[31:0];

  // dcache pre-launch fires from MEM1 (VIPT, VA-indexed): set + offset = 12
  // bits <= page-offset width, so the dcache index is alias-free under any
  // translation.  The BRAM ram_rdata is registered at the MEM1->MEM2 boundary
  // so MEM2 consumes a flop output for the way-mux + load_data_full chain.
  assign dcache_early_addr = {{(64-32){1'b0}}, ex2_mem1_q.alu_result[31:0]};
  assign dcache_early_req_valid =
    ex2_mem1_q.valid &
    (ex2_mem1_q.dec.is_load | ex2_mem1_q.dec.is_store | ex2_mem1_q.dec.is_amo);

  // itlb_perm_fail back-edge cut.  itlb_perm_fail is gated inside u_itlb by
  // lookup_valid_i = translate_fetch & align_needs_fetch, and the latter is
  // s0_valid_to_icache — the same node ex_redirect / redirect_load drives.
  // Flopping the perm-fail signal (with redirect_load sync-clear) breaks the
  // loop without shifting the icache datapath, which still consumes itlb_pa
  // combinationally for s0 BRAM indexing.  trap_tval for instr_page_fault
  // continues to use pc_q (predecode-emitted PC) so existing tval semantics
  // are preserved; ACT4-s6-priv is the correctness gate.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)            itlb_s1_perm_fail_q <= 1'b0;
    else if (redirect_load) itlb_s1_perm_fail_q <= 1'b0;
    else                    itlb_s1_perm_fail_q <= itlb_perm_fail;
  end

  // Free-running pc_q snapshot — sampled every cycle so itlb_s1_pc_q at
  // cycle N+1 equals pc_q at cycle N.  trap_tval reads it only when the
  // registered iTLB perm-fail arm of instr_page_fault is the cause; the
  // ptw_pf and cross_page_fault arms continue to use live pc_q (their own
  // semantics are unchanged from the pre-flop design).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) itlb_s1_pc_q <= 32'h0;
    else         itlb_s1_pc_q <= pc_q;
  end

  // Aggregate page-fault flags (TLB perm-fail OR PTW page-fault on the matching
  // tlb_op_e).  cross_page_fault is treated as an instruction page-fault.
  // kronos_align gates cross_page_fault_o on translate_fetch_i, so this signal
  // is automatically zero in M-mode / Bare and only fires under active
  // translation.
  // instr_page_fault stays an iTLB-driven fetch-side signal (no dTLB / MEM1
  // dependency).  load_page_fault and store_page_fault are now MEM1-cycle
  // producers that consume the registered ex2_mem1_q opcode + the live MEM1
  // dTLB perm-fail / PTW page-fault, and land in
  // mem1_mem2_q.fault.{load,store}_page_fault at the MEM1->MEM2 edge.
  assign instr_page_fault     = itlb_s1_perm_fail_q |
                                (ptw_pf & (ptw_pf_which == TLB_FETCH)) |
                                cross_page_fault;
  assign mem1_load_page_fault =
      (dtlb_perm_fail | (ptw_pf & (ptw_pf_which == TLB_LOAD))) &
      ex2_mem1_q.dec.is_load;
  assign mem1_store_page_fault =
      (dtlb_perm_fail | (ptw_pf & (ptw_pf_which == TLB_STORE))) &
      (ex2_mem1_q.dec.is_store | ex2_mem1_q.dec.is_amo);
  // Legacy combinational aliases of the MEM1-produced page-fault bits.  Kept
  // as wires so legacy consumers (mem_trap_cause_d / ex1_trap_cause read
  // sites that are being routed to mem1_mem2_q.fault.*) still resolve until
  // the corresponding sites switch to the registered fault aggregate.
  assign load_page_fault  = mem1_load_page_fault;
  assign store_page_fault = mem1_store_page_fault;

  // STAGE5f: 64-bit LSU — thin adapter to kronos_dcache.  Runs at MEM2: every
  // input comes from the mem1_mem2_q register.  PA is mem1_mem2_q.dtlb_pa
  // (registered at the MEM1->MEM2 edge from the MEM1-stage dTLB output, or
  // from ex2_mem1_q.alu_result[31:0] under translation-off).
  kronos_lsu u_lsu (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_i              (mem1_mem2_q.valid & (mem1_mem2_q.dec.is_load |
                         mem1_mem2_q.dec.is_store | mem1_mem2_q.dec.is_amo)
                         & ~mem_done_q),
    // PMP data-port permission-violation flag.  The MEM1->MEM2 register
    // captures pmp_data_fault into mem1_mem2_q.fault.pmp_data_fault, so the
    // LSU at MEM2 reads a flop output that breaks the dTLB+PMP -> dcache
    // hit-mux + load_data_full cone (master spec §1).
    .pmp_fault_i        (mem1_mem2_q.fault.pmp_data_fault),
    // dcache-raised faults — AMO to non-cacheable region and AXI
    // bus error.  Both suppress the dcache request and unstall the pipeline
    // so the trap can be taken immediately (mirrors the PMP-fault pattern).
    .amo_nc_fault_i     (dcache_amo_nc_fault),
    .bus_err_fault_i    (dcache_bus_err_fault),
    // dTLB miss indicator — LSU stalls and suppresses dcache issue
    // until the PTW refills the dTLB and the access is replayed.
    .tlb_miss_i         (dtlb_miss),
    .we_i               (mem1_mem2_q.dec.is_store | mem1_mem2_q.dec.fp_store),
    // addr_i is the translated PA from the MEM1-stage dTLB lookup,
    // registered into mem1_mem2_q.dtlb_pa at the MEM1->MEM2 edge.
    .addr_i             (mem1_mem2_q.dtlb_pa),
    .wdata_i            (mem1_mem2_q.rs2_data),
    .funct3_i           (mem1_mem2_q.dec.mem_funct3),
    .rdata_o            (lsu_rdata),
    .valid_o            (lsu_valid),
    .mem_stall_o        (lsu_mem_stall),
    // FP load/store ports
    .fp_dest_req_i      (mem1_mem2_q.valid &
                         (mem1_mem2_q.dec.fp_load | mem1_mem2_q.dec.fp_store) & ~mem_done_q),
    .fp_store_data_i    (mem1_mem2_q.rs2_data),
    .fp_dest_rsp_o      (lsu_fp_dest),
    .fp_rdata_o         (lsu_fp_rdata),
    // A-extension
    .is_lr_i            (mem1_mem2_q.dec.is_lr),
    .is_sc_i            (mem1_mem2_q.dec.is_sc),
    .is_amo_i           (mem1_mem2_q.dec.is_amo),
    .amo_funct5_i       (mem1_mem2_q.dec.amo_funct5),
    .amo_src_i           (mem1_mem2_q.rs2_data),
    // sc_success_o is just dcache_sc_success_i echoed back; the LSU also
    // packs it into rdata_o (~success) so the standalone output is unused.
    .sc_success_o       (lsu_sc_success_unused),
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
  // FENCE.I is held in EX (rr_ex1_q.valid stays high) until the cache is
  // drained.  The kick-off term (fence_i_pulse_raw & dirty_pending) is
  // combinational so the pipeline freezes the SAME cycle FENCE.I enters EX,
  // before rr_ex1_q can advance.  fence_i_active_q latches one cycle later
  // and holds the stall across the rest of the flush walk.
  assign mem_stall = lsu_mem_stall | fence_i_active_q |
                     (fence_i_pulse_raw & dcache_dirty_pending);

  // D-cache instance: owns AXI master for the data port.
  kronos_dcache #(
    .NUM_NC_REGIONS  (NUM_NC_REGIONS),
    .NC_REGION_BASE  (NC_REGION_BASE),
    .NC_REGION_LIMIT (NC_REGION_LIMIT)
  ) u_dcache (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .req_i           (dcache_req),
    .addr_i          (dcache_addr),
    .size_i          (dcache_size),
    .we_i            (dcache_we),
    .wdata_i         (dcache_wdata),
    .amo_req_i       (dcache_amo_req),
    .amo_op_i        (dcache_amo_op),
    .rsrv_clear_i    (trap_taken_pulse),
    // EX-stage pre-launch — fires the BRAM read one cycle ahead of the
    // MEM-stage req_i so ram_rdata is registered when MEM consumes it.
    .early_req_valid_i (dcache_early_req_valid),
    .early_addr_i      (dcache_early_addr),
    .data_valid_o    (dcache_data_valid),
    .rdata_o         (dcache_rdata),
    .sc_success_o    (dcache_sc_success),
    .stall_o         (dcache_stall),
    // PTW priority port — page-table walks bypass the LSU pipe.
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
    .amo_nc_fault_o  (dcache_amo_nc_fault),
    .bus_err_fault_o (dcache_bus_err_fault),
    .miss_pulse_o    (dcache_miss_pulse)
  );

  // -------------------------------------------------------------------------
  // Instruction TLB.
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
  // Data TLB.  Symmetric to u_itlb but on the LSU data port.  Runs in MEM1:
  // the VA is ex2_mem1_q.alu_result (rs1 + imm registered into ex2_mem1_q at
  // the EX2->MEM1 edge); the translated PA is registered into
  // mem1_mem2_q.dtlb_pa for the LSU at MEM2.
  // -------------------------------------------------------------------------
  kronos_tlb #(.N(8)) u_dtlb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .lookup_valid_i     (translate_data & ex2_mem1_q.valid &
                         (ex2_mem1_q.dec.is_load | ex2_mem1_q.dec.is_store |
                          ex2_mem1_q.dec.is_amo)),
    .lookup_va_i        (ex2_mem1_q.alu_result),
    .lookup_asid_i      (satp_asid),
    .lookup_priv_i      (eff_priv_data),
    .is_load_i          (ex2_mem1_q.dec.is_load |
                         (ex2_mem1_q.dec.is_amo & ex2_mem1_q.dec.is_lr)),
    .is_store_i         (ex2_mem1_q.dec.is_store |
                         (ex2_mem1_q.dec.is_amo & ~ex2_mem1_q.dec.is_lr)),
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
  // Page-Table Walker.
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
    .dtlb_miss_is_load_i  (rr_ex1_q.dec.is_load |
                           (rr_ex1_q.dec.is_amo & rr_ex1_q.dec.is_lr)),
    .dtlb_miss_is_store_i (rr_ex1_q.dec.is_store |
                           (rr_ex1_q.dec.is_amo & ~rr_ex1_q.dec.is_lr)),
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

  // FPU top
  assign fpu_tag_in = '{rd: rr_ex1_q.dec.rd, fp_dest: rr_ex1_q.dec.rd_fp};

  kronos_fpu_top u_fpu (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (1'b0),
    .in_valid_i (rr_ex1_q.valid & rr_ex1_q.dec.is_fp &
                 ~rr_ex1_q.dec.fp_load & ~rr_ex1_q.dec.fp_store &
                 ~fpu_dispatched_q),
    .op_i       (rr_ex1_q.dec.fp_op),
    .fmt_d_i    (rr_ex1_q.dec.fmt_d),
    .rm_i       (rr_ex1_q.dec.rm_resolved),
    .a_i        (fpu_a_i),
    .b_i        (fpu_b_i),
    .c_i        (rr_ex1_q.rs3_data),
    .tag_i      (fpu_tag_in),
    .busy_o     (fpu_busy),
    .out_valid_o(fpu_out_valid),
    .result_o   (fpu_result),
    .fflags_o   (fpu_fflags),
    .tag_o      (fpu_tag_out)
  );

  // FPU dispatch / inflight tracking
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fp_inflight_q    <= 1'b0;
      fpu_dispatched_q <= 1'b0;
    end else begin
      // Dispatch: fire once per FP arithmetic instruction in EX
      if (rr_ex1_q.valid & rr_ex1_q.dec.is_fp &
          ~rr_ex1_q.dec.fp_load & ~rr_ex1_q.dec.fp_store &
          ~fpu_dispatched_q & ~fpu_busy) begin
        fp_inflight_q    <= 1'b1;
        fpu_dispatched_q <= 1'b1;
      end

      // Clear dispatch guard when EX advances (instruction leaves EX)
      if (ex2_mem1_en & ~combined_stall) begin
        fpu_dispatched_q <= 1'b0;
      end

      // Clear inflight when FPU result arrives; the result is forwarded
      // into mem_wb_q.alu_result at the same posedge (see mem_wb_q block).
      if (fpu_out_valid) begin
        fp_inflight_q <= 1'b0;
      end
    end
  end

  // FPU result latch: captures fpu_result when fpu_out_valid fires.
  // Cleared when the FP instruction actually leaves EX (pipeline advances).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fp_result_valid_q <= 1'b0;
      fp_result_q       <= {kronos_pkg::FLEN{1'b0}};
      fp_tag_q          <= '{default: '0};
      fp_fflags_q       <= 5'b0;
    end else begin
      if (fpu_out_valid & combined_stall) begin
        // Latch only when pipeline is stalled: result would otherwise be lost.
        fp_result_valid_q <= 1'b1;
        fp_result_q       <= fpu_result;
        fp_tag_q          <= fpu_tag_out;
        fp_fflags_q       <= fpu_fflags;
      end else if (fp_result_valid_q & ~combined_stall) begin
        // Pipeline is advancing: FP instruction leaves EX, result consumed.
        fp_result_valid_q <= 1'b0;
      end
    end
  end

  // FP regfile write-port mux
  // Priority: FP load (MEM stage) > FP arithmetic WB
  always_comb begin
    fp_we = 1'b0;
    fp_wa = 5'b0;
    fp_wd = {kronos_pkg::FLEN{1'b0}};

    if (lsu_valid & mem1_mem2_q.valid & mem1_mem2_q.dec.fp_load) begin
      // FP load completes at MEM2 (the LSU runs at MEM2): write NaN-boxed
      // data into the FP regfile from the MEM2-stage instruction.
      fp_we = 1'b1;
      fp_wa = mem1_mem2_q.dec.rd;
      fp_wd = lsu_fp_rdata;
    end else if (mem_wb_q.valid & mem_wb_q.dec.is_fp &
                 mem_wb_q.dec.rd_fp & ~mem_wb_q.dec.fp_load) begin
      // FP arithmetic result: captured in alu_result at the MEM/WB boundary.
      fp_we = 1'b1;
      fp_wa = mem_wb_q.dec.rd;
      fp_wd = mem_wb_q.alu_result;
    end
  end

  // =========================================================================
  // BOOM-style IFU: kronos_icache (s0/s1/s2) -> kronos_fetch_buffer ->
  // kronos_predecode.  Replaces the old icache + kronos_align combo.  See
  // docs/superpowers/specs/2026-05-02-stage6f-icache-boom-frontend-v3-design.md
  // sections 5–7.
  // =========================================================================

  // Combinational redirect detection.  Drives s1_kill, s2_kill, FB flush,
  // predecode flush, and the s0_pc_q reload mux.  Highest priority wins.
  // pred_taken is consumed via pred_taken_q (one-cycle delayed) so the comb
  // path through the predictor does not fan into the icache kill / FB flush
  // signals.  By the time pred_taken_q fires, the branch is already in IF/ID
  // (captured at the same edge that latched pred_taken_q), so this delay
  // costs at most one extra wrong-path bubble per predicted-taken branch.
  // Stage 7a — redirect_load consumes registered redirects only.  The
  // direction-mispredict redirect target is the EX1-stage `ex_pc_d` registered
  // alongside the fault bit into `ex_redirect_target_q`.  The MEM-stage
  // redirect target is captured into `mem_redirect_target_q` at the same
  // edge.  ex1_ex2_q.ex_pc_d / ex2_mem1_q.pc_d are NOT safe to read here:
  // both registers advance on the same edge that asserts the redirect, so
  // their fields hold the next-instruction target by the time _q is high.
  assign redirect_load   = mem_redirect_q | ex_redirect_q |
                           fence_i_redirect_q | pred_taken_q;
  // Priority: mem_redirect (architectural trap to mtvec) outranks
  // fence_i_redirect (post-FENCE.I PC+4) so the eventual illegal-trap
  // delivery wins, but in the gap before mem_redirect_q fires the
  // fence_i_redirect_q rebases the IFU on the freshly-flushed icache.
  assign redirect_target = mem_redirect_q    ? mem_redirect_target_q
                         : ex_redirect_q     ? ex_redirect_target_q
                         : fence_i_redirect_q ? fence_i_redirect_target_q
                         : pred_taken_q      ? pred_target_q
                         :                     32'h0;

  // Stage 7a — fold fence_i_pulse into S1/S2 kill so the OLD-icache lookup
  // in flight at the cycle the icache valid bits drop cannot enqueue into
  // the fetch buffer.  Stage 6 piggybacked on ex_redirect (combinational from
  // fence.i.illegal) for this; here mem_redirect arrives 2 cycles late.
  assign s1_kill = redirect_load | fence_i_pulse;
  assign s2_kill = redirect_load | fence_i_pulse;

  // Register pred_taken / pred_target.  We only latch when the branch was
  // actually captured into IF/ID this cycle: predecode is emitting a valid
  // instruction (align_instr_valid) AND if_id_en is asserted AND no higher-
  // priority redirect is racing the same edge.  Without the align_instr_valid
  // gate, pred_taken_q would fire whenever the held predecode_instr_pc happens
  // to alias a BTB entry — even during refill stalls when no real branch is
  // in-flight — and the resulting wrong-path s2_kill cascade would squash
  // legitimate refill bypass pushes.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pred_taken_q  <= 1'b0;
      pred_target_q <= 32'h0;
    end else begin
      pred_taken_q  <= pred_taken & align_instr_valid & if_id_en &
                       ~ex_redirect_q & ~mem_redirect_q & ~fence_i_redirect_q;
      // Hold pred_target_q during a cycle that is already issuing a redirect
      // (pred_taken_q high, ex/mem_redirect high).  Otherwise: cycle K
      // fires pred_taken_q for branch B (target T1); cycle K's FB and
      // predecode are mid-flush; predecode at K still emits the next
      // wrong-path instruction; the BPU lookup of that wrong-path PC writes
      // pred_target_q with the wrong-path target T_w; if pred_taken_q
      // latches 1 again at K+1 (chained), the redirect uses T_w instead of
      // T1 — a livelock.  Holding pred_target_q across the redirect cycle
      // preserves T1; even if the chain fires, the redirect goes to T1
      // (effectively a no-op redirect since the IF is already loading T1).
      // Less invasive than gating pred_taken_q itself, which broke dhrystone.
      if (~pred_taken_q & ~ex_redirect_q & ~mem_redirect_q & ~fence_i_redirect_q) begin
        pred_target_q <= pred_target;
      end
    end
  end

  // s0_pc_q advance — IFU-internal next-fetch PC.  Reloads on redirect, holds
  // on FB back-pressure (s0_accept low), advances by 4 each accepted s0.
  // On an icache miss-event the icache squashes any in-flight S1/S2 entries
  // (their wrong-path PCs are in the [miss_pc+4 .. miss_pc+8] range) and
  // delivers the missed word back via the refill bypass.  s0_pc_q must rewind
  // to miss_pc+4 (icache_miss_resync_pc) so those squashed words are re-fetched
  // once the refill completes — without this rewind they would be dropped from
  // the FB stream, leaving predecode to combine across a gap.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s0_pc_q <= 32'h0;
    end else if (!boot_loaded_q) begin
      s0_pc_q <= boot_addr_i;
    end else if (redirect_load) begin
      s0_pc_q <= redirect_target;
    end else if (icache_miss_event) begin
      s0_pc_q <= icache_miss_resync_pc;
    end else if (s0_accept) begin
      s0_pc_q <= s0_pc_q + 32'd4;
    end
  end

  // Don't issue s0 during reset/boot or during a redirect (the redirect itself
  // reloads s0_pc_q this cycle).
  assign s0_valid_to_icache = boot_loaded_q & ~redirect_load;
  assign s0_accept          = s0_valid_to_icache & s0_ready_from_icache;

  // The PMP / iTLB / PTW lookup logic uses icache_fetch_addr as the VA being
  // presented to the fetch port.  In the v3 IFU that VA is s0_pc_q.
  assign icache_fetch_addr = s0_pc_q;

  kronos_icache u_icache (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .s0_valid_i     (s0_valid_to_icache),
    // addr_i is the translated PA when satp.MODE != Bare and priv != M;
    // otherwise PA == VA (icache_fetch_addr).
    .s0_addr_i      ({32'b0, eff_fetch_pa}),
    // Word-align the PC handed to the FB.  A half-aligned redirect target
    // (e.g. 0x42, 0x7e, 0x9e) is the half-aligned address of the FIRST
    // 32-bit instruction; the icache always fetches the word containing it,
    // and predecode uses flush_pc_offset_i to discover the half offset.
    // Subsequent FB entries must be labelled with the WORD PC (lowest 2
    // bits clear) so predecode's "word_pc_i | 2 if eff_upper" derivation
    // matches the actual instruction PCs.
    .s0_pc_i        ({s0_pc_q[31:2], 2'b00}),
    .s0_ready_o     (s0_ready_from_icache),
    .s1_kill_i      (s1_kill),
    .s2_kill_i      (s2_kill),
    .confirmed_redirect_i (mem_redirect_q | ex_redirect_q),
    .flush_i        (fence_i_pulse),
    .pmp_fault_i    (pmp_fetch_fault),
    .tlb_miss_i     (itlb_miss),
    .s2_enq_valid_o   (ic_to_fb_valid),
    .s2_enq_pc_o      (ic_to_fb_pc),
    .s2_enq_data_o    (ic_to_fb_data),
    .s2_enq_ready_i   (fb_enq_ready),
    .miss_event_o     (icache_miss_event),
    .miss_resync_pc_o (icache_miss_resync_pc),
    .axi_req_o        (instr_axi_req_o),
    .axi_rsp_i        (instr_axi_rsp_i),
    .miss_pulse_o     (icache_miss_pulse)
  );

  kronos_fetch_buffer #(
    .DEPTH (4)
  ) u_fb (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    // Stage 7a — drain fb on fence_i_pulse so OLD instruction words queued
    // ahead of FENCE.I (fetched from the icache before its valid_q is
    // invalidated by the same fence_i_pulse) cannot be consumed by the
    // pipeline.  In stage 6 this was implicit: fence_i_pulse and ex_redirect
    // fired the same cycle and ex_redirect is what flushed the fb.  Here
    // mem_redirect (the 2-cycle fault-bit form of FENCE.I's illegal trap)
    // arrives two cycles after fence_i_pulse, leaving a window where stale
    // fb entries can sneak through.  visible as ACT4 Zifencei-fence.i-00
    // retiring the pre-store instruction at selfmodify_0.
    .flush_i     (redirect_load | fence_i_pulse),
    .enq_valid_i (ic_to_fb_valid),
    .enq_pc_i    (ic_to_fb_pc),
    .enq_data_i  (ic_to_fb_data),
    .enq_ready_o (fb_enq_ready),
    .deq_valid_o (fb_to_pd_valid),
    .deq_pc_o    (fb_to_pd_pc),
    .deq_data_o  (fb_to_pd_data),
    .deq_ready_i (fb_to_pd_ready)
  );

  kronos_predecode u_predecode (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .flush_i            (redirect_load | fence_i_pulse),
    .flush_pc_offset_i  (redirect_target[1]),
    .word_valid_i       (fb_to_pd_valid),
    .word_data_i        (fb_to_pd_data),
    .word_pc_i          (fb_to_pd_pc),
    .word_consume_o     (fb_to_pd_ready),
    .instr_valid_o      (align_instr_valid),
    .instr_o            (align_instr),
    .instr_pc_o         (predecode_instr_pc),
    .instr_is_16b_o     (align_is_16b),
    .instr_ready_i      (if_id_en),
    .cross_page_fault_o (cross_page_fault),
    .translate_fetch_i  (translate_fetch)
  );

  // Tie-offs for legacy align_* control signals.  Predecode handles spanning
  // internally; FB back-pressure replaces the old align_needs_fetch / stall
  // outputs.  align_needs_fetch is held high so PMP / iTLB / PTW continue to
  // see a fetch lookup every cycle s0_pc_q is presented (matching the
  // semantics of the old align_needs_fetch_o output).
  assign align_need_upper  = 1'b0;
  assign align_needs_fetch = s0_valid_to_icache;
  assign align_stall       = 1'b0;

  kronos_bpred u_bpred (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .pc_i            (predecode_instr_pc),
    .pred_taken_o    (pred_taken),
    .pred_target_o   (pred_target),
    .upd_valid_i     (bpred_update_en),
    .upd_pc_i        (rr_ex1_q.pc),
    .upd_taken_i     (actual_taken),
    .upd_target_i    (ex_pc_d),
    .upd_is_jal_i    (rr_ex1_q.dec.is_jal | rr_ex1_q.dec.is_jalr)
  );

  // =========================================================================
  // PC register
  // =========================================================================
  // pc_q now mirrors predecode's emitted PC.  This is BOOM's "the architectural
  // PC is whatever the FB head says" model — the architectural PC is carried
  // with the data through the FB, not tracked sequentially.  Redirects override
  // predecode (the FB hasn't been flushed yet on the cycle a redirect first
  // fires, so we don't trust predecode's PC that cycle).  pc_d is the next
  // pc_q value if pc_en fires.
  //
  // Priority: mem_redirect before ex_redirect so that when both fire
  // simultaneously, the pipeline returns to the architecturally correct
  // target from the MEM branch.
  assign pc_d = mem_redirect_q         ? mem_redirect_target_q
              : ex_redirect_q          ? ex_redirect_target_q
              : fence_i_redirect_q     ? fence_i_redirect_target_q
              : pred_taken             ? pred_target
              : align_instr_valid      ? predecode_instr_pc
              :                          pc_q;

  // pc_q reset: async to constant 0, then synchronous load of boot_addr_i
  // on the first post-reset cycle. See stage5/kronos_top.sv for the full
  // explanation — using boot_addr_i directly as an async reset value
  // produced "Set+Reset same priority" GLS bugs (issue #57).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q          <= 32'b0;
      boot_loaded_q <= 1'b0;
    end else if (!boot_loaded_q) begin
      pc_q          <= boot_addr_i;
      boot_loaded_q <= 1'b1;
    end else if (pc_en) begin
      pc_q          <= pc_d;
    end
  end

  // =========================================================================
  // IF stage — icache handles all fetch transactions via u_icache above.
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if_id_q <= '{default: '0};
    end else if (if_id_flush) begin
      // ex_redirect / mem_redirect / load-use bubble — the branch (or the
      // load itself in the load-use case) is wrong-path, so always clear.
      if_id_q <= '{default: '0};
    end else if (pred_taken_q) begin
      // pred_taken_q fires the cycle AFTER the branch was captured into
      // if_id_q.  The branch is at if_id_q's output and we want id_ex to
      // latch it; the wrong-path fall-through that predecode would emit
      // this cycle must NOT enter if_id_q.  Two cases:
      //   (a) rr_ex1_en = 1: id_ex latches the branch this cycle, so we
      //       can safely clear if_id_q to bubble the wrong-path fetch.
      //   (b) rr_ex1_en = 0 (muldiv/mem stall): id_ex cannot accept the
      //       branch yet.  Clearing if_id_q here would lose the branch
      //       — closes #86 (mulw → addiw → bne tight-loop wedge).
      //       Hold if_id_q so id_ex picks up the branch when the stall
      //       releases.  The wrong-path predecode emit is naturally
      //       suppressed: `if_id_en` is also 0 under any stall that drops
      //       rr_ex1_en, so we don't fall into the latch branch below.
      if (rr_ex1_en) begin
        if_id_q <= '{default: '0};
      end
    end else if (if_id_en) begin
      if_id_q.pc          <= predecode_instr_pc;
      if_id_q.instr       <= align_instr;
      if_id_q.valid       <= align_instr_valid;
      if_id_q.is_16b      <= align_is_16b;
      if_id_q.pred_taken  <= pred_taken & ~ex_redirect_q;
      if_id_q.pred_target <= pred_target;
    end
  end

  // =========================================================================
  // ID stage — produces id_rr_d combinationally.  Decode + fault-bit gen +
  // forwarding-selector capture; no regfile / bypass / CSR access here.
  // =========================================================================

  // ID/RR next-state.  Decode result, ID-owned fault bits, and the RR/EX1-stage
  // bypass selectors (computed at ID by u_forward) cross the boundary; rs/csr
  // reads and the RR/EX1 bypass mux fire inside the RR cycle.
  always_comb begin
    id_rr_d              = kronos_pkg::ID_RR_REG_ZERO;
    id_rr_d.pc           = if_id_q.pc;
    id_rr_d.instr        = if_id_q.instr;
    id_rr_d.dec          = id_dec;
    id_rr_d.fwd_rs1_sel  = fwd_rs1_sel;
    id_rr_d.fwd_rs2_sel  = fwd_rs2_sel;
    id_rr_d.valid        = if_id_q.valid;
    id_rr_d.is_16b       = if_id_q.is_16b;
    id_rr_d.pred_taken   = if_id_q.pred_taken;
    id_rr_d.pred_target  = if_id_q.pred_target;
    // ID-owned fault producers.  Non-ID bits stay '0 here; EX1/EX2/MEM each
    // OR-fold their own producers at later pipe boundaries.
    id_rr_d.fault            = kronos_pkg::FAULT_ZERO;
    id_rr_d.fault.ecall      = if_id_q.valid & id_dec.is_ecall;
    id_rr_d.fault.ebreak     = if_id_q.valid & id_dec.is_ebreak;
    id_rr_d.fault.illegal    = if_id_q.valid & id_dec.illegal &
                               ~fence_i_dirty_block;
    id_rr_d.fault.is_mret    = if_id_q.valid & id_dec.is_mret;
    id_rr_d.fault.is_sret    = if_id_q.valid & id_dec.is_sret;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        id_rr_q <= kronos_pkg::ID_RR_REG_ZERO;
    else if (id_rr_flush)    id_rr_q <= kronos_pkg::ID_RR_REG_ZERO;
    else if (id_rr_en)       id_rr_q <= id_rr_d;
  end

  // =========================================================================
  // RR stage — regfile reads (int + FP), source-select muxes, RR/EX1 bypass.
  // =========================================================================

  // FP source-select mux.  Selector encoding:
  //   2'd0 = live FPU result, 2'd1 = EX/MEM FP forward, 2'd2 = WB FP forward,
  //   2'd3 = FP regfile read.
  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_rr_q.dec.rs1))
      fp_rs1_sel = 2'd0;
    else if (ex2_mem1_q.valid & ex2_mem1_q.dec.is_fp & ex2_mem1_q.dec.rd_fp &
             ~ex2_mem1_q.dec.fp_load & (ex2_mem1_q.dec.rd == id_rr_q.dec.rs1))
      fp_rs1_sel = 2'd1;
    else if (fp_we & (fp_wa == id_rr_q.dec.rs1))
      fp_rs1_sel = 2'd2;
    else
      fp_rs1_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs1_sel)
      2'd0:    fp_rs1_data_rr = fp_result_cur;
      2'd1:    fp_rs1_data_rr = ex2_mem1_q.alu_result;
      2'd2:    fp_rs1_data_rr = fp_wd;
      default: fp_rs1_data_rr = fp_rd1;
    endcase
  end

  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_rr_q.dec.rs2))
      fp_rs2_sel = 2'd0;
    else if (ex2_mem1_q.valid & ex2_mem1_q.dec.is_fp & ex2_mem1_q.dec.rd_fp &
             ~ex2_mem1_q.dec.fp_load & (ex2_mem1_q.dec.rd == id_rr_q.dec.rs2))
      fp_rs2_sel = 2'd1;
    else if (fp_we & (fp_wa == id_rr_q.dec.rs2))
      fp_rs2_sel = 2'd2;
    else
      fp_rs2_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs2_sel)
      2'd0:    fp_rs2_data_rr = fp_result_cur;
      2'd1:    fp_rs2_data_rr = ex2_mem1_q.alu_result;
      2'd2:    fp_rs2_data_rr = fp_wd;
      default: fp_rs2_data_rr = fp_rd2;
    endcase
  end

  always_comb begin
    if      (fp_result_avail & fp_tag_cur.fp_dest & (fp_tag_cur.rd == id_rr_q.dec.rs3))
      fp_rs3_sel = 2'd0;
    else if (ex2_mem1_q.valid & ex2_mem1_q.dec.is_fp & ex2_mem1_q.dec.rd_fp &
             ~ex2_mem1_q.dec.fp_load & (ex2_mem1_q.dec.rd == id_rr_q.dec.rs3))
      fp_rs3_sel = 2'd1;
    else if (fp_we & (fp_wa == id_rr_q.dec.rs3))
      fp_rs3_sel = 2'd2;
    else
      fp_rs3_sel = 2'd3;
  end
  always_comb begin
    unique case (fp_rs3_sel)
      2'd0:    fp_rs3_data_rr = fp_result_cur;
      2'd1:    fp_rs3_data_rr = ex2_mem1_q.alu_result;
      2'd2:    fp_rs3_data_rr = fp_wd;
      default: fp_rs3_data_rr = fp_rd3;
    endcase
  end

  // Integer path: WB bypass (oldest source, no bypass-mux key for it) or
  // regfile read.  rd_wen guards against B/S-type encodings where instr[11:7]
  // is an immediate, not a real destination register.
  assign int_rs1_data_rr = (wb_writing && mem_wb_q.dec.rd == id_rr_q.dec.rs1)
                           ? wb_result_64 : rs1_rdata_64;
  assign int_rs2_data_rr = (wb_writing && mem_wb_q.dec.rd == id_rr_q.dec.rs2)
                           ? wb_result_64 : rs2_rdata_64;

  // Final RR-stage operand mux: FP or integer.  FP and integer paths are
  // mutually exclusive on rs1_fp / rs2_fp.
  assign rs1_data_rr = id_rr_q.dec.rs1_fp ? fp_rs1_data_rr : int_rs1_data_rr;
  assign rs2_data_rr = id_rr_q.dec.rs2_fp ? fp_rs2_data_rr : int_rs2_data_rr;
  assign rs3_data_rr = fp_rs3_data_rr;

  // RR/EX1 bypass mux — selects the freshest producer slot keyed by
  // id_rr_q.fwd_rs*_sel.  Captured into rr_ex1_q.rs1_data / rs2_data so EX1
  // consumes a flop output (no combinational regfile / bypass cone in front of
  // the ALU / AGU / FPU dispatch / branch-compare).
  //
  // Source map (rs1; rs2 mirrors):
  //   FWD_EX1_NOW : same-cycle live ex_result (consumer was in RR at ID-time
  //                  T, producer in EX1 now at T+1; ex_result has not yet
  //                  flopped into ex1_ex2_q.alu_result).  ex_result picks
  //                  muldiv_result vs alu_result so MUL/DIV producers bypass
  //                  through the same path.
  //   FWD_EX1     : ex1_ex2_q.alu_result (or csr_rdata when CSR-typed).
  //   FWD_EXMEM        : ex2_mem1_q.alu_result (or csr_rdata when CSR-typed).
  //   FWD_MEM2    : mem1_mem2_q.alu_result (CSR-typed → csr_rdata; loads →
  //                 lsu_rdata combinationally from the dcache hit-mux).
  //   FWD_MEMWB   : wb_result_64 (writeback mux output).
  //   default     : RR-cycle source (FP mux or int regfile/WB-bypass mux).
  always_comb begin
    unique case (id_rr_q.fwd_rs1_sel)
      FWD_EX1_NOW: rs1_bypassed = ex_result;
      FWD_EX1:     rs1_bypassed = ex1_ex2_csr_q  ? ex1_ex2_q.csr_rdata  : ex1_ex2_q.alu_result;
      FWD_EXMEM:    rs1_bypassed = ex2_mem_csr_q  ? ex2_mem1_q.csr_rdata : ex2_mem1_q.alu_result;
      FWD_MEM2:    rs1_bypassed = mem1_mem2_q.dec.is_load ? lsu_rdata
                                : (mem1_mem2_csr_q ? mem1_mem2_q.csr_rdata
                                                   : mem1_mem2_q.alu_result);
      FWD_MEMWB:   rs1_bypassed = wb_result_64;
      default:     rs1_bypassed = rs1_data_rr;
    endcase
    unique case (id_rr_q.fwd_rs2_sel)
      FWD_EX1_NOW: rs2_bypassed = ex_result;
      FWD_EX1:     rs2_bypassed = ex1_ex2_csr_q  ? ex1_ex2_q.csr_rdata  : ex1_ex2_q.alu_result;
      FWD_EXMEM:    rs2_bypassed = ex2_mem_csr_q  ? ex2_mem1_q.csr_rdata : ex2_mem1_q.alu_result;
      FWD_MEM2:    rs2_bypassed = mem1_mem2_q.dec.is_load ? lsu_rdata
                                : (mem1_mem2_csr_q ? mem1_mem2_q.csr_rdata
                                                   : mem1_mem2_q.alu_result);
      FWD_MEMWB:   rs2_bypassed = wb_result_64;
      default:     rs2_bypassed = rs2_data_rr;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rr_ex1_q <= kronos_pkg::RR_EX1_REG_ZERO;
    end else if (rr_ex1_flush) begin
      rr_ex1_q <= kronos_pkg::RR_EX1_REG_ZERO;
    end else if (rr_ex1_en) begin
      rr_ex1_q.pc          <= id_rr_q.pc;
      rr_ex1_q.dec         <= id_rr_q.dec;
      rr_ex1_q.rs1_data    <= rs1_bypassed;
      rr_ex1_q.rs2_data    <= rs2_bypassed;
      rr_ex1_q.rs3_data    <= rs3_data_rr;
      rr_ex1_q.valid       <= id_rr_q.valid;
      rr_ex1_q.is_16b      <= id_rr_q.is_16b;
      rr_ex1_q.pred_taken  <= id_rr_q.pred_taken;
      rr_ex1_q.pred_target <= id_rr_q.pred_target;
      rr_ex1_q.fwd_rs1_sel <= id_rr_q.fwd_rs1_sel;
      rr_ex1_q.fwd_rs2_sel <= id_rr_q.fwd_rs2_sel;
      rr_ex1_q.instr       <= id_rr_q.instr;
      // ID-owned fault bits travel with the instruction; EX1/EX2/MEM fold in
      // their own producers at later pipe boundaries.
      rr_ex1_q.fault       <= id_rr_q.fault;
      // Speculative CSR read captured at the RR/EX1 boundary.  Consumed by
      // EX1's writeback-value pipe via the EX1-stage rdata_o path (kept until
      // 7c retiming); already-flopped here so EX1 sees no comb CSR-file read.
      rr_ex1_q.csr_rdata   <= rr_csr_rdata_combinational;
    end
  end

  // =========================================================================
  // EX1 stage — operand consumption from RR/EX1 flop outputs (no comb cone).
  // =========================================================================

  // The bypass mux fires at RR (above) and captures into rr_ex1_q.{rs1,rs2}_data
  // at the RR/EX1 boundary.  EX1 reads pure flop outputs; alias names kept so
  // downstream consumers (alu_a/alu_b, fpu_a_i/fpu_b_i, JALR adder, CSR rs1
  // operand, branch comparator, dcache wdata) don't all need to be retargeted.
  assign fwd_rs1_data = rr_ex1_q.rs1_data;
  assign fwd_rs2_data = rr_ex1_q.rs2_data;

  // ALU operand formation — PC zero-extends to 64, imm sign-extends to 64.
  assign alu_a = rr_ex1_q.dec.use_pc  ? {32'b0, rr_ex1_q.pc}
                                     : fwd_rs1_data;
  assign alu_b = rr_ex1_q.dec.use_imm ? {{32{rr_ex1_q.dec.imm[31]}}, rr_ex1_q.dec.imm}
                                     : fwd_rs2_data;

  // FPU operand forwarding: for FP instructions with integer-source operands
  // (FMV.W.X, FMV.D.X), apply EX integer forwarding so a producer one or two
  // stages ahead is bypassed correctly.  FP-source operands were already
  // forwarded via the fpu_out_valid bypass in the ID-stage rs1/2_data_id mux.
  assign fpu_a_i = rr_ex1_q.dec.rs1_fp ? rr_ex1_q.rs1_data : fwd_rs1_data;
  assign fpu_b_i = rr_ex1_q.dec.rs2_fp ? rr_ex1_q.rs2_data : fwd_rs2_data;

  // Branch condition — consumes the ALU's comparator outputs. Decode sets
  // alu_op = ALU_SLT / ALU_SLTU for branches so cmp_lt_o runs on the right
  // signedness; eq_o is valid for any subtract-style alu_op.
  always_comb begin
    branch_taken = 1'b0;
    if (rr_ex1_q.valid & rr_ex1_q.dec.is_branch) begin
      unique case (rr_ex1_q.dec.branch_funct3)
        3'b000:  branch_taken =  alu_eq;        // BEQ
        3'b001:  branch_taken = ~alu_eq;        // BNE
        3'b100:  branch_taken =  alu_cmp_lt;    // BLT  (signed)
        3'b101:  branch_taken = ~alu_cmp_lt;    // BGE  (signed)
        3'b110:  branch_taken =  alu_cmp_lt;    // BLTU (unsigned)
        3'b111:  branch_taken = ~alu_cmp_lt;    // BGEU (unsigned)
        default: branch_taken = 1'b0;
      endcase
    end
  end

  // Stage 7a — trap_cause / trap_tval are computed from the *trapping
  // instruction's* registered state at the EX2→MEM clock edge (same edge that
  // populates mem_wb_q.fault), then snapshot into mem_wb_trap_cause_q /
  // mem_wb_trap_tval_q.  The CSR's trap_i fires at retire (mem_wb_q.valid &
  // mem_wb_fault_any_trap), so the snapshot is the value mepc/mcause/mtval
  // commit.  This decouples the trap fields from rr_ex1_q (which has advanced
  // to the next instruction by retire-cycle).
  //
  // Sdtrig action fires before the matched instruction commits, so a
  // trigger hit takes priority over the instruction's own illegal/ecall
  // cause (RISC-V Debug Spec §5).
  //
  // Stage 6b ordering: page-fault arms come BEFORE the matching pmp arms
  // because the priv-spec defines the access-vs-translate decision as
  // "translate first, then access-check" — a missing/perm-failed translation
  // produces a page-fault even if the translated PA would also fail PMP.
  always_comb begin
    if (mem1_mem2_q.fault.trig_hit) begin
      mem_trap_cause_d = 32'd3;                                              // BREAKPOINT (Sdtrig)
    end else if (mem1_mem2_q.fault.instr_page_fault) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_INSTR_PAGE_FAULT};         // 12
    end else if (mem1_mem2_q.fault.pmp_fetch_fault) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_INSTR_ACCESS_FAULT};       // 1
    end else if (mem1_mem2_q.fault.load_page_fault) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_LOAD_PAGE_FAULT};          // 13
    end else if (mem1_mem2_q.fault.pmp_data_fault & mem1_mem2_q.dec.is_load) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};        // 5
    end else if (mem1_mem2_q.fault.ex_amo_nc_fault & mem1_mem2_q.dec.is_load) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};        // 5
    end else if (mem1_mem2_q.fault.store_page_fault) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_PAGE_FAULT};         // 15
    end else if (mem1_mem2_q.fault.pmp_data_fault & mem1_mem2_q.dec.is_store) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};       // 7
    end else if (mem1_mem2_q.fault.ex_amo_nc_fault & mem1_mem2_q.dec.is_store) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};       // 7
    end else if (mem1_mem2_q.fault.pmp_data_fault & mem1_mem2_q.dec.is_amo) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (mem1_mem2_q.fault.ex_amo_nc_fault & mem1_mem2_q.dec.is_amo) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (dcache_bus_err_fault & mem1_mem2_q.dec.is_load) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};        // 5
    end else if (dcache_bus_err_fault) begin
      mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};       // 7
    end else if (mem1_mem2_q.fault.irq_pending) begin
      // The interrupt sources (mip / mie / mstatus.MIE / SIE) have not been
      // cleared yet at MEM2 — that happens when trap_i commits at retire.
      // The live irq_cause priority encoder output at this MEM2 cycle still
      // reflects the same pending interrupt as when irq_pending was sampled
      // at EX1.
      mem_trap_cause_d = {1'b1, 26'b0, irq_cause};
    end else if (mem1_mem2_q.fault.illegal | mem1_mem2_q.fault.csr_illegal |
                 mem1_mem2_q.fault.mret_priv_fail | mem1_mem2_q.fault.sret_priv_fail |
                 mem1_mem2_q.fault.satp_tvm_fail | mem1_mem2_q.fault.wfi_priv_fail) begin
      mem_trap_cause_d = 32'd2;                                              // ILLEGAL
    end else if (mem1_mem2_q.fault.ecall) begin
      unique case (priv_q)
        PRIV_U:  mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_ECALL_U};       // 8
        PRIV_S:  mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_ECALL_S};       // 9
        PRIV_M:  mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_ECALL_M};       // 11
        default: mem_trap_cause_d = {27'b0, kronos_pkg::CAUSE_ECALL_M};
      endcase
    end else begin
      mem_trap_cause_d = 32'd3;                                              // ebreak (default)
    end
  end

  // trap_tval: offending PC for fetch faults, offending data address for
  // data PMP / page / dcache-bus faults, original instruction word for
  // illegal-instruction (priv-spec § 3.1.16), 0 otherwise.  Reads mem1_mem2_q
  // registered state and the MEM2-cycle live dcache-bus-err signal.
  always_comb begin
    if      (mem1_mem2_q.fault.pmp_fetch_fault) mem_trap_tval_d = mem_wb_pmp_fetch_addr_q[31:0];
    else if (mem1_mem2_q.fault.instr_page_fault) mem_trap_tval_d = mem1_mem2_q.pc;
    else if (mem1_mem2_q.fault.load_page_fault | mem1_mem2_q.fault.store_page_fault)
                                              mem_trap_tval_d = mem1_mem2_q.alu_result[31:0];
    else if (mem1_mem2_q.fault.pmp_data_fault)  mem_trap_tval_d = mem_wb_pmp_data_addr_q[31:0];
    else if (mem1_mem2_q.fault.ex_amo_nc_fault) mem_trap_tval_d = mem1_mem2_q.alu_result[31:0];
    else if (dcache_bus_err_fault)              mem_trap_tval_d = mem1_mem2_q.dtlb_pa[31:0];
    else if (mem1_mem2_q.fault.illegal | mem1_mem2_q.fault.csr_illegal |
             mem1_mem2_q.fault.mret_priv_fail | mem1_mem2_q.fault.sret_priv_fail |
             mem1_mem2_q.fault.satp_tvm_fail   | mem1_mem2_q.fault.wfi_priv_fail)
                                              mem_trap_tval_d = mem1_mem2_q.instr;
    else                                      mem_trap_tval_d = 32'd0;
  end

  // Snapshot trap_cause / trap_tval at the EX2→MEM boundary.  Aligns with the
  // mem_wb_q.fault snapshot — at retire (mem_wb_q.valid & mem_wb_fault_any_trap)
  // the registered trap fields refer to the same trapping instruction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_trap_cause_q <= 32'h0;
      mem_wb_trap_tval_q  <= 32'h0;
    end else if (mem_wb_en) begin
      mem_wb_trap_cause_q <= mem_trap_cause_d;
      mem_wb_trap_tval_q  <= mem_trap_tval_d;
    end
  end

  // Snapshot the PMP fault addresses at the EX2→MEM boundary so the trap_tval
  // snapshot reads a registered offender PA matching mem_wb_q.fault.pmp_*.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_pmp_fetch_addr_q <= 56'h0;
      mem_wb_pmp_data_addr_q  <= 56'h0;
    end else if (mem_wb_en) begin
      mem_wb_pmp_fetch_addr_q <= pmp_fetch_fault_addr;
      mem_wb_pmp_data_addr_q  <= pmp_data_fault_addr;
    end
  end

  // Aggregate trap-class fault bits at retire.  Excludes is_mret/is_sret
  // (commit signals; not traps) and bpred_*_mispredict (pure redirects;
  // not traps).
  assign mem_wb_fault_any_trap =
      mem_wb_q.fault.ecall            |
      mem_wb_q.fault.ebreak           |
      mem_wb_q.fault.illegal          |
      mem_wb_q.fault.csr_illegal      |
      mem_wb_q.fault.mret_priv_fail   |
      mem_wb_q.fault.sret_priv_fail   |
      mem_wb_q.fault.satp_tvm_fail    |
      mem_wb_q.fault.wfi_priv_fail    |
      mem_wb_q.fault.irq_pending      |
      mem_wb_q.fault.pmp_fetch_fault  |
      mem_wb_q.fault.pmp_data_fault   |
      mem_wb_q.fault.ex_amo_nc_fault  |
      mem_wb_q.fault.trig_hit         |
      mem_wb_q.fault.instr_page_fault |
      mem_wb_q.fault.load_page_fault  |
      mem_wb_q.fault.store_page_fault |
      mem_wb_q.fault.dcache_bus_err_fault;

  // Trace alias — retire_trap_cause_o exports the registered trap_cause
  // (= mcause value being committed this cycle).  Same width as the legacy
  // `trap_cause` wire.
  assign trap_cause = mem_wb_trap_cause_q;
  assign trap_tval  = mem_wb_trap_tval_q;

  // JALR target: 64-bit add, truncate to 32-bit PC (physical PC is 32-bit).
  assign jalr_target_64 = (fwd_rs1_data + {{32{rr_ex1_q.dec.imm[31]}}, rr_ex1_q.dec.imm})
                           & ~64'd1;

  // Predictive trap_cause / trap_class.  Drives u_csr.trap_cause_ex_i /
  // trap_class_ex_i so trap_vector_o reflects the correct medeleg/mideleg
  // slot at the cycle the trap-causing instruction is in EX1 (for EX1-class
  // faults) or in MEM1 (for MEM1-class faults).  MEM1-class faults take
  // priority because the MEM1 instruction is older than the EX1 instruction
  // and a MEM1-trap fires mem_redirect_d / mem_redirect_q which flushes the
  // EX1 instruction anyway.
  always_comb begin
    ex1_trap_class = (rr_ex1_q.valid & (rr_ex1_q.dec.is_ecall |
                       rr_ex1_q.dec.is_ebreak | rr_ex1_q.dec.illegal |
                       csr_illegal | mret_priv_fail | sret_priv_fail |
                       satp_tvm_fail | wfi_priv_fail | irq_pending)) |
                     trig_hit | pmp_fetch_fault | pmp_data_fault |
                     mem1_amo_nc_fault | dcache_bus_err_fault |
                     instr_page_fault | mem1_load_page_fault |
                     mem1_store_page_fault;

    // Priority: MEM1-class faults (older instruction) first, then EX1-class.
    if (mem1_load_page_fault) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_LOAD_PAGE_FAULT};
    end else if (pmp_data_fault & ex2_mem1_q.dec.is_load) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};
    end else if (mem1_amo_nc_fault & ex2_mem1_q.dec.is_load) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};
    end else if (mem1_store_page_fault) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_PAGE_FAULT};
    end else if (pmp_data_fault & ex2_mem1_q.dec.is_store) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (mem1_amo_nc_fault & ex2_mem1_q.dec.is_store) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (pmp_data_fault & ex2_mem1_q.dec.is_amo) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (mem1_amo_nc_fault & ex2_mem1_q.dec.is_amo) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (dcache_bus_err_fault & mem1_mem2_q.dec.is_load) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_LOAD_ACCESS_FAULT};
    end else if (dcache_bus_err_fault) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_STORE_ACCESS_FAULT};
    end else if (trig_hit) begin
      ex1_trap_cause = 32'd3;
    end else if (instr_page_fault) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_INSTR_PAGE_FAULT};
    end else if (pmp_fetch_fault) begin
      ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_INSTR_ACCESS_FAULT};
    end else if (irq_pending) begin
      ex1_trap_cause = {1'b1, 26'b0, irq_cause};
    end else if (rr_ex1_q.dec.illegal | csr_illegal | mret_priv_fail |
                 sret_priv_fail | satp_tvm_fail | wfi_priv_fail) begin
      ex1_trap_cause = 32'd2;
    end else if (rr_ex1_q.dec.is_ecall) begin
      unique case (priv_q)
        PRIV_U:  ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_ECALL_U};
        PRIV_S:  ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_ECALL_S};
        PRIV_M:  ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_ECALL_M};
        default: ex1_trap_cause = {27'b0, kronos_pkg::CAUSE_ECALL_M};
      endcase
    end else begin
      ex1_trap_cause = 32'd3;
    end
  end

  always_comb begin
    if      ((rr_ex1_q.valid & (rr_ex1_q.dec.is_ecall | rr_ex1_q.dec.is_ebreak |
                               rr_ex1_q.dec.illegal  | csr_illegal |
                               mret_priv_fail | sret_priv_fail | satp_tvm_fail |
                               wfi_priv_fail |
                               irq_pending)) | trig_hit |
              pmp_fetch_fault | instr_page_fault) begin
      // EX1-class faults steer ex_pc_d to the trap vector so a direction-
      // mispredict cone (the only consumer of ex1_ex2_q.ex_pc_d) jumps to
      // mtvec/stvec on the trapping edge.  MEM1-class faults (pmp_data_fault,
      // mem1_amo_nc_fault, mem1_load/store_page_fault, dcache_bus_err_fault)
      // override mem1_mem2_q.pc_d at the MEM1->MEM2 edge instead.
      ex_pc_d = trap_vector[31:0];
    end else if (rr_ex1_q.valid & rr_ex1_q.dec.is_mret & ~mret_priv_fail) begin
      ex_pc_d = mepc[31:0];
    end else if (rr_ex1_q.valid & rr_ex1_q.dec.is_sret & ~sret_priv_fail) begin
      ex_pc_d = sepc[31:0];
    end else if (rr_ex1_q.valid & rr_ex1_q.dec.is_jalr) begin
      ex_pc_d = jalr_target_64[31:0];
    end else if (rr_ex1_q.valid & rr_ex1_q.dec.is_jal) begin
      ex_pc_d = rr_ex1_q.pc + rr_ex1_q.dec.imm;
    end else if (branch_taken) begin
      ex_pc_d = rr_ex1_q.pc + rr_ex1_q.dec.imm;
    end else begin
      ex_pc_d = rr_ex1_q.is_16b ? rr_ex1_q.pc + 32'd2 : rr_ex1_q.pc + 32'd4;
    end
  end

  // STAGE3: branch predictor — misprediction detection and update
  assign is_branch_or_jump = rr_ex1_q.dec.is_branch | rr_ex1_q.dec.is_jal | rr_ex1_q.dec.is_jalr;
  assign actual_taken      = branch_taken | rr_ex1_q.dec.is_jal | rr_ex1_q.dec.is_jalr;

  // Direction-only misprediction: taken/not-taken disagrees with prediction.
  // Target misprediction (both predicted and actually taken, but wrong target)
  // is deferred to the MEM stage (bpred_mispredict_target) so that the JALR
  // target adder and the 32-bit comparator are removed from the ex_redirect
  // combinational path.
  assign bpred_mispredict = rr_ex1_q.valid & (
    (rr_ex1_q.pred_taken & ~actual_taken) |
    (~rr_ex1_q.pred_taken & actual_taken)
  );

  // Suppress BTB update from the speculative instruction in EX when mem_redirect fires.
  assign bpred_update_en = rr_ex1_q.valid & ex2_mem1_en & is_branch_or_jump & ~mem_redirect_q;

  // FENCE.I trap suppression: when FENCE.I sits in EX and the D-cache still
  // holds dirty data, suppress the illegal-instruction redirect until the
  // flush completes.  Once dcache_flush_done pulses (or there were no dirty
  // lines), the redirect resumes and the trap handler advances MEPC past
  // the FENCE.I — by which time AXI memory has the up-to-date bytes.
  assign fence_i_dirty_block = rr_ex1_q.valid &
                                (rr_ex1_q.instr[6:0]   == 7'b0001111) &
                                (rr_ex1_q.instr[14:12] == 3'b001) &
                                dcache_dirty_pending & ~dcache_flush_done;

  // Stage 7a — EX1 fault next-state.  Each bit is a single-cycle decision.
  // Carries forward rr_ex1_q.fault and ORs in the EX1-stage producers.
  fault_t ex1_fault_d;
  always_comb begin
    ex1_fault_d                       = rr_ex1_q.fault;
    ex1_fault_d.csr_illegal           = rr_ex1_q.valid & rr_ex1_q.dec.is_csr &
                                        csr_illegal_raw;
    ex1_fault_d.mret_priv_fail        = rr_ex1_q.valid & rr_ex1_q.dec.is_mret &
                                        mret_priv_fail;
    ex1_fault_d.sret_priv_fail        = rr_ex1_q.valid & rr_ex1_q.dec.is_sret &
                                        sret_priv_fail;
    ex1_fault_d.satp_tvm_fail         = rr_ex1_q.valid & satp_tvm_fail;
    ex1_fault_d.wfi_priv_fail         = rr_ex1_q.valid & rr_ex1_q.dec.is_wfi &
                                        wfi_priv_fail;
    ex1_fault_d.irq_pending           = irq_pending;
    ex1_fault_d.bpred_dir_mispredict  = bpred_mispredict;
    // ex_amo_nc_fault has moved to MEM1 (mem1_amo_nc_fault); it is OR'd into
    // mem1_mem2_q.fault.ex_amo_nc_fault at the MEM1->MEM2 edge.  Only EX1-cycle
    // producers stay in ex1_fault_d.
    ex1_fault_d.trig_hit              = trig_hit;
  end

  // Stage 7a — EX1→EX2 register next-state.
  always_comb begin
    ex1_ex2_d              = '{default: '0, dec: kronos_pkg::DECODED_INSTR_ZERO,
                               fault: kronos_pkg::FAULT_ZERO};
    ex1_ex2_d.pc           = rr_ex1_q.pc;
    ex1_ex2_d.dec          = rr_ex1_q.dec;
    ex1_ex2_d.rs2_data     = fwd_rs2_data;
    ex1_ex2_d.alu_result   = (rr_ex1_q.valid & rr_ex1_q.dec.is_fp &
                              ~rr_ex1_q.dec.fp_load & ~rr_ex1_q.dec.fp_store)
                              ? fp_result_cur : ex_result;
    ex1_ex2_d.eff_va       = alu_adder_out[31:0];
    ex1_ex2_d.ex_pc_d      = ex_pc_d;
    ex1_ex2_d.branch_taken = branch_taken;
    ex1_ex2_d.csr_rdata    = csr_rdata;
    ex1_ex2_d.csr_wdata    = fwd_rs1_data;
    ex1_ex2_d.valid        = rr_ex1_q.valid & ~irq_pending;
    ex1_ex2_d.is_16b       = rr_ex1_q.is_16b;
    ex1_ex2_d.pred_taken   = rr_ex1_q.pred_taken;
    ex1_ex2_d.pred_target  = rr_ex1_q.pred_target;
    ex1_ex2_d.instr        = rr_ex1_q.instr;
    ex1_ex2_d.fault        = ex1_fault_d;
  end

  // Stage 7a — EX1→EX2 register.  Flushed by either redirect class.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex1_ex2_q <= '{default: '0, dec: kronos_pkg::DECODED_INSTR_ZERO,
                     fault: kronos_pkg::FAULT_ZERO};
    end else if (ex1_ex2_flush) begin
      ex1_ex2_q <= '{default: '0, dec: kronos_pkg::DECODED_INSTR_ZERO,
                     fault: kronos_pkg::FAULT_ZERO};
    end else if (ex1_ex2_en) begin
      ex1_ex2_q <= ex1_ex2_d;
    end
  end

  assign ex1_ex2_en    = ~combined_stall;
  // Stage 7a — flush ex1_ex2_q on mem_redirect_d (live, same cycle as the
  // trap-causing instruction sits in ex2_mem1_q) as well as the registered _q
  // bits.  Without the _d term, the wrong-path follower in rr_ex1_q latches
  // into ex1_ex2_q at the same edge mem_redirect_q goes high; one cycle later
  // that follower's bpred_dir_mispredict can raise ex_redirect_q and override
  // the IFU's trap_vector / xRET reload — visible as test_csr_priv jumping to
  // the wrong-path j-target 0x5a instead of mtvec=0x88.
  assign ex1_ex2_flush = ex_redirect_q | mem_redirect_q | mem_redirect_d;

  // Stage 7a — EX2 fault next-state.  Carries EX1 bits forward verbatim.
  // EX2 fault next-state.  Carries every EX1-stage fault bit forward verbatim
  // and folds in the registered fetch-side pmp_fetch_fault.  The data-side
  // MEM1-stage faults (pmp_data_fault, ex_amo_nc_fault, load_page_fault,
  // store_page_fault, instr_page_fault) are NOT folded here — they fire one
  // stage later and are OR'd into mem1_mem2_q.fault at the MEM1->MEM2 edge.
  fault_t ex2_fault_d;
  always_comb begin
    ex2_fault_d                  = ex1_ex2_q.fault;
    ex2_fault_d.pmp_fetch_fault  = pmp_fetch_fault;
  end

  // Stage 7a — direction-mispredict-only redirect, formed from registered bits.
  // All other fault classes are deferred to MEM (mem_redirect_d).
  assign ex_redirect_d = ex1_ex2_q.fault.bpred_dir_mispredict;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        ex_redirect_q <= 1'b0;
    else if (combined_stall) ex_redirect_q <= ex_redirect_q;
    else                     ex_redirect_q <= ex_redirect_d;
  end

  // Capture the EX2 redirect target alongside ex_redirect_q.  Sampled from
  // `ex1_ex2_q.ex_pc_d` at the edge that registers the fault, so the IFU sees
  // the mispredicting branch's target on the cycle the redirect fires (the
  // ex1_ex2_q register itself is overwritten by the next instruction at the
  // same edge — its `ex_pc_d` field is no longer trustworthy after that).
  //
  // The capture is gated on `~ex_redirect_q` so a wrong-path follower that
  // sneaks into ex1_ex2_q one cycle behind the mispredicting branch (e.g. a
  // long mem_stall holds the BEQ in EX1 while a JAL is in if_id_q; when the
  // stall lifts, both BEQ and JAL advance one stage at the same edge, so the
  // JAL sits in ex1_ex2_q the cycle after BEQ) cannot overwrite the captured
  // target with its own ex_pc_d.  The first capture wins; the wrong-path
  // follower's bpred_dir_mispredict bit is harmless because ex_redirect_q
  // drives the IFU redirect on the very next cycle and the follower is
  // killed by the if_id / id_ex flush from the hazard module.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        ex_redirect_target_q <= 32'h0;
    else if (combined_stall) ex_redirect_target_q <= ex_redirect_target_q;
    else if (ex_redirect_d & ~ex_redirect_q) begin
      ex_redirect_target_q <= ex1_ex2_q.ex_pc_d;
    end
  end

  // Trace alias for sim_main.cpp (legacy probe name).  Observation-only.
  assign ex_redirect = ex_redirect_q;

  // Stage 7a — registered FENCE.I redirect.  See declaration block for the
  // motivation; this is a 1-cycle pulse that fires the cycle after
  // `fence_i_pulse`, steering the IFU to FENCE.I+4 with the just-flushed
  // icache.  The illegal-trap to mtvec rides the fault-bit pipeline and
  // arrives one cycle later via mem_redirect_q (which has higher priority
  // in the redirect mux).  Held across combined_stall so the redirect
  // survives an instr_fetch_stall window without re-firing.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        fence_i_redirect_q <= 1'b0;
    else if (combined_stall) fence_i_redirect_q <= fence_i_redirect_q;
    else                     fence_i_redirect_q <= fence_i_pulse;
  end

  // Capture FENCE.I+4 alongside the redirect bit.  FENCE.I is in ex1_ex2_q
  // (EX2 stage) when fence_i_pulse fires, so its PC is ex1_ex2_q.pc.
  // FENCE.I is always 32-bit, but the is_16b path is preserved for
  // symmetry with ex_pc_d construction elsewhere.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        fence_i_redirect_target_q <= 32'h0;
    else if (combined_stall) fence_i_redirect_target_q <= fence_i_redirect_target_q;
    else if (fence_i_pulse) begin
      fence_i_redirect_target_q <= ex1_ex2_q.pc +
                                   (ex1_ex2_q.is_16b ? 32'd2 : 32'd4);
    end
  end


  // Stage 7a — wb_sel pipeline tracking the producer one stage ahead at the
  // forwarding-mux read site.  ex1_ex2_csr_q tags the instruction landing in
  // ex1_ex2_q (read by FWD_EX1), ex2_mem_csr_q tags the one landing in
  // ex2_mem1_q (read by FWD_EXMEM).  Sources are rr_ex1_q at the EX1→EX2 edge
  // and ex1_ex2_q at the EX2→MEM edge — i.e. each register samples its own
  // upstream stage, NOT rr_ex1_q both times.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex1_ex2_csr_q <= 1'b0;
    else if (ex1_ex2_en) ex1_ex2_csr_q <= (rr_ex1_q.dec.wb_sel == WB_CSR);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex2_mem_csr_q <= 1'b0;
    else if (ex2_mem1_en) ex2_mem_csr_q <= (ex1_ex2_q.dec.wb_sel == WB_CSR);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          mem1_mem2_csr_q <= 1'b0;
    else if (mem1_mem2_en) mem1_mem2_csr_q <= ex2_mem_csr_q;
  end

  // Stage 7a — csr_new_val pipeline.  u_csr.csr_new_val_o (= csr_new_val_post)
  // is combinational from rr_ex1_q at the EX1 stage, so capture it at the
  // EX1→EX2 edge and propagate forward.  Without this stage, the EX2→MEM
  // snapshot would read the next-EX1 instruction's value instead of the EX2
  // instruction's, and retire would commit the wrong CSR write.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex1_ex2_csr_new_val_q <= {kronos_pkg::XLEN{1'b0}};
    else if (ex1_ex2_en) ex1_ex2_csr_new_val_q <= csr_new_val_post;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex2_mem_csr_new_val_q <= {kronos_pkg::XLEN{1'b0}};
    else if (ex2_mem1_en) ex2_mem_csr_new_val_q <= ex1_ex2_csr_new_val_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          mem1_mem2_csr_new_val_q <= {kronos_pkg::XLEN{1'b0}};
    else if (mem1_mem2_en) mem1_mem2_csr_new_val_q <= ex2_mem_csr_new_val_q;
  end

  // propagate the post-write CSR value MEM2→WB, mirroring the
  // mem_wb_q.csr_wdata pipe.  Drives retire_csr_wdata_o and the CSR
  // module's retire_csr_new_val_i (architectural commit at retire).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        mem_wb_csr_new_val_q <= {kronos_pkg::XLEN{1'b0}};
    else if (mem_wb_en) mem_wb_csr_new_val_q <= mem1_mem2_csr_new_val_q;
  end

  // Stage 7a — fflags pipeline.  Captures fp_fflags_cur at the EX1→EX2 edge
  // alongside the FP result.  The FP-arith retire flag rides the same edges
  // so the CSR's fflags accumulate at retire is gated by `is_fp_arith` (FP
  // load / store / fmv int<->fp do not produce fflags from the FPU result
  // path; the FP load/store path doesn't dispatch the FPU at all).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex1_ex2_fflags_q <= 5'b0;
    else if (ex1_ex2_en) ex1_ex2_fflags_q <= fp_fflags_cur;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex1_ex2_is_fp_arith_q <= 1'b0;
    else if (ex1_ex2_en) ex1_ex2_is_fp_arith_q <= rr_ex1_q.valid &
                                                  rr_ex1_q.dec.is_fp &
                                                  ~rr_ex1_q.dec.fp_load &
                                                  ~rr_ex1_q.dec.fp_store;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex2_mem_fflags_q      <= 5'b0;
    else if (ex2_mem1_en) ex2_mem_fflags_q      <= ex1_ex2_fflags_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         ex2_mem_is_fp_arith_q <= 1'b0;
    else if (ex2_mem1_en) ex2_mem_is_fp_arith_q <= ex1_ex2_is_fp_arith_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          mem1_mem2_fflags_q       <= 5'b0;
    else if (mem1_mem2_en) mem1_mem2_fflags_q       <= ex2_mem_fflags_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          mem1_mem2_is_fp_arith_q  <= 1'b0;
    else if (mem1_mem2_en) mem1_mem2_is_fp_arith_q  <= ex2_mem_is_fp_arith_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        mem_wb_fflags_q       <= 5'b0;
    else if (mem_wb_en) mem_wb_fflags_q       <= mem1_mem2_fflags_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        mem_wb_is_fp_arith_q  <= 1'b0;
    else if (mem_wb_en) mem_wb_is_fp_arith_q  <= mem1_mem2_is_fp_arith_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex2_mem1_q <= EX_MEM_REG_ZERO;
    end else if (ex2_mem1_flush) begin
      ex2_mem1_q <= EX_MEM_REG_ZERO;
    end else if (ex2_mem1_en) begin
      // Sources flow through ex1_ex2_q (registered EX2 output).  pc_d carries
      // the EX1-cycle ex_pc_d (already overridden to trap_vector for EX1-class
      // faults) into MEM1; MEM1-class faults override at the MEM1->MEM2 edge.
      ex2_mem1_q.pc         <= ex1_ex2_q.pc;
      ex2_mem1_q.dec        <= ex1_ex2_q.dec;
      ex2_mem1_q.alu_result <= ex1_ex2_q.alu_result;
      ex2_mem1_q.rs2_data   <= ex1_ex2_q.rs2_data;
      ex2_mem1_q.pc_d       <= ex1_ex2_q.ex_pc_d;
      ex2_mem1_q.csr_rdata  <= ex1_ex2_q.csr_rdata;
      ex2_mem1_q.fault      <= ex2_fault_d;
      // The Stage 6 `redirect` field is dead in Stage 7+; the fault-bit
      // contract carries trap context via mem_wb_q.fault.
      ex2_mem1_q.redirect   <= 1'b0;
      // Wrong-path kill at the EX2->MEM1 boundary.  Three terms:
      //   ~mem_redirect_d : kills the wrong-path follower entering MEM1 at
      //     the same posedge a MEM2 trap asserts.  The instruction CAUSING
      //     the MEM2 trap is in mem1_mem2_q (current state, valid=1 and
      //     unaffected — only the next-cycle load is gated).
      //   ~mem_redirect_q : keeps subsequent loads killed while the
      //     registered redirect is held high.
      // Note: ex_redirect_q is NOT in this gate — the EX2 redirect
      // (direction mispredict) flushes ID/RR/EX1 wrong-path followers, but
      // the EX2 instruction ITSELF (the JAL/branch that detected the
      // mispredict) must still commit its rd write at WB. Killing it here
      // would suppress JAL's link write to ra and break ret semantics.
      // ex1_ex2_flush already drains any wrong-path instruction from EX1
      // before it reaches EX2.
      ex2_mem1_q.valid       <= ex1_ex2_q.valid &
                                ~mem_redirect_d & ~mem_redirect_q;
      ex2_mem1_q.is_16b      <= ex1_ex2_q.is_16b;
      ex2_mem1_q.pred_taken  <= ex1_ex2_q.pred_taken;
      ex2_mem1_q.pred_target <= ex1_ex2_q.pred_target;
      ex2_mem1_q.instr       <= ex1_ex2_q.instr;
      ex2_mem1_q.csr_wdata   <= ex1_ex2_q.csr_wdata;
    end
  end

  assign ex2_mem1_flush = mem_redirect_q | mem_redirect_d;

  // MEM1->MEM2 fault next-state.  Carries every EX2-stage fault bit forward
  // and OR-folds in the MEM1-cycle producers (pmp_data_fault, mem1_amo_nc_fault,
  // mem1_load/store_page_fault, instr_page_fault) so the registered aggregate
  // is the source of truth for mem_redirect_d at MEM2.
  always_comb begin
    mem1_fault_d                    = ex2_mem1_q.fault;
    mem1_fault_d.pmp_data_fault     = ex2_mem1_q.fault.pmp_data_fault |
                                      (pmp_data_fault_raw & pmp_any_active);
    mem1_fault_d.ex_amo_nc_fault    = ex2_mem1_q.fault.ex_amo_nc_fault |
                                      mem1_amo_nc_fault;
    mem1_fault_d.load_page_fault    = ex2_mem1_q.fault.load_page_fault  |
                                      mem1_load_page_fault;
    mem1_fault_d.store_page_fault   = ex2_mem1_q.fault.store_page_fault |
                                      mem1_store_page_fault;
    mem1_fault_d.instr_page_fault   = ex2_mem1_q.fault.instr_page_fault |
                                      instr_page_fault;
  end

  // MEM1-class faults that cause a trap-vector redirect (vs a direction
  // mispredict).  These override mem1_mem2_q.pc_d to trap_vector at the
  // MEM1->MEM2 edge so mem_redirect_target_q latches the right vector.
  assign mem1_trap_redirect =
      (pmp_data_fault_raw & pmp_any_active) |
      mem1_amo_nc_fault   |
      mem1_load_page_fault |
      mem1_store_page_fault;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem1_mem2_q <= MEM1_MEM2_REG_ZERO;
    end else if (mem1_mem2_flush) begin
      mem1_mem2_q <= MEM1_MEM2_REG_ZERO;
    end else if (mem1_mem2_en) begin
      mem1_mem2_q.pc          <= ex2_mem1_q.pc;
      mem1_mem2_q.dec         <= ex2_mem1_q.dec;
      mem1_mem2_q.alu_result  <= ex2_mem1_q.alu_result;
      mem1_mem2_q.rs2_data    <= ex2_mem1_q.rs2_data;
      // pc_d carries either the EX1-cycle ex_pc_d (for non-trap or EX1-class
      // trap), or trap_vector when a MEM1-class fault overrides.
      mem1_mem2_q.pc_d        <= mem1_trap_redirect
                                 ? trap_vector[31:0]
                                 : ex2_mem1_q.pc_d;
      mem1_mem2_q.csr_rdata   <= ex2_mem1_q.csr_rdata;
      mem1_mem2_q.csr_wdata   <= ex2_mem1_q.csr_wdata;
      mem1_mem2_q.is_16b      <= ex2_mem1_q.is_16b;
      mem1_mem2_q.pred_taken  <= ex2_mem1_q.pred_taken;
      mem1_mem2_q.pred_target <= ex2_mem1_q.pred_target;
      mem1_mem2_q.instr       <= ex2_mem1_q.instr;
      mem1_mem2_q.redirect    <= 1'b0;
      // Wrong-path kill at MEM1->MEM2 boundary: only MEM2-class redirects
      // kill an instruction that's already past EX2.  ex_redirect_q (EX2
      // direction-mispredict) does NOT kill MEM1: by the time the EX2
      // redirect fires, the MEM1 occupant is the JAL/branch itself, which
      // must commit its writeback (e.g. JAL's link write to ra).  The
      // ex_redirect cone targets ID/RR/EX1 wrong-path followers, not MEM1.
      mem1_mem2_q.valid       <= ex2_mem1_q.valid &
                                  ~mem_redirect_d & ~mem_redirect_q;
      mem1_mem2_q.fault       <= mem1_fault_d;
      mem1_mem2_q.dtlb_pa     <= eff_data_pa[31:0];
      mem1_mem2_q.dtlb_was_hit <= ~dtlb_miss;
      mem1_mem2_q.dcache_pre_launched <= dcache_early_req_valid;
    end
  end

  assign mem1_mem2_flush = mem_redirect_q | mem_redirect_d;

  // PA pipeline: dTLB lookup runs at MEM1 (consuming ex2_mem1_q.alu_result as
  // VA), the translated PA flops into mem1_mem2_q.dtlb_pa at the MEM1->MEM2
  // edge, and the LSU at MEM2 consumes mem1_mem2_q.dtlb_pa.  No discrete
  // ex1_ex2_data_pa_q / ex2_mem_data_pa_q flops are needed any more.

  // MEM2-stage target misprediction: predictor predicted taken with the right
  // direction (so EX2 did not redirect), but the predicted target was wrong.
  // Both mem1_mem2_q.pc_d and mem1_mem2_q.pred_target are registered, so this
  // comparison sits on a short path.  Guard with ~mem1_mem2_q.fault.bpred_dir_mispredict:
  // if EX2 already redirected on a direction mismatch, no second redirect needed.
  assign bpred_mispredict_target = mem1_mem2_q.valid &
    ~mem1_mem2_q.fault.bpred_dir_mispredict &
    mem1_mem2_q.pred_taken & (mem1_mem2_q.pred_target != mem1_mem2_q.pc_d);

  // MEM2-stage redirect formation.  Single OR over registered MEM1 fault bits
  // (now in mem1_mem2_q.fault) + live MEM2-cycle producers (target mispredict,
  // dcache bus error).  All sources are either registered (mem1_mem2_q.fault.*)
  // or stay within the narrow MEM2 cone, so this aggregator never crosses a
  // module boundary and is one stage further from the dTLB / PMP comparators
  // than 7b's MEM aggregator.
  //
  // Gating the entire fault sum on mem1_mem2_q.valid prevents spurious traps
  // from wrong-path followers; MEM2 live producers (bpred_mispredict_target,
  // dcache_bus_err_fault) are already either gated on mem1_mem2_q.valid or
  // sourced from MEM2 requests the LSU/dTLB only fire when mem1_mem2_q.valid=1.
  assign mem_redirect_d = mem1_mem2_q.valid & (
      mem1_mem2_q.fault.ecall            |
      mem1_mem2_q.fault.ebreak           |
      mem1_mem2_q.fault.illegal          |
      mem1_mem2_q.fault.csr_illegal      |
      mem1_mem2_q.fault.mret_priv_fail   |
      mem1_mem2_q.fault.sret_priv_fail   |
      mem1_mem2_q.fault.satp_tvm_fail    |
      mem1_mem2_q.fault.wfi_priv_fail    |
      mem1_mem2_q.fault.irq_pending      |
      mem1_mem2_q.fault.is_mret          |
      mem1_mem2_q.fault.is_sret          |
      mem1_mem2_q.fault.pmp_fetch_fault  |
      mem1_mem2_q.fault.pmp_data_fault   |
      mem1_mem2_q.fault.ex_amo_nc_fault  |
      mem1_mem2_q.fault.trig_hit         |
      mem1_mem2_q.fault.instr_page_fault |
      mem1_mem2_q.fault.load_page_fault  |
      mem1_mem2_q.fault.store_page_fault |
      bpred_mispredict_target          |
      dcache_bus_err_fault);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        mem_redirect_q <= 1'b0;
    else if (combined_stall) mem_redirect_q <= mem_redirect_q;
    else                     mem_redirect_q <= mem_redirect_d;
  end

  // Capture the MEM2 redirect target alongside mem_redirect_q.  Sampled from
  // `mem1_mem2_q.pc_d` at the edge that registers the fault, since the
  // mem1_mem2_q register is overwritten by the next instruction at the same
  // edge and its `pc_d` field becomes stale.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if      (!rst_ni)        mem_redirect_target_q <= 32'h0;
    else if (combined_stall) mem_redirect_target_q <= mem_redirect_target_q;
    else if (mem_redirect_d) mem_redirect_target_q <= mem1_mem2_q.pc_d;
  end

  // =========================================================================
  // MEM stage — mem_done_q / lsu_rdata_latch handle pipeline stall bridging
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_done_q      <= 1'b0;
      lsu_rdata_latch <= {kronos_pkg::XLEN{1'b0}};
      amo_write_latch <= 1'b0;
    end else begin
      if (lsu_valid) begin
        mem_done_q      <= 1'b1;
        lsu_rdata_latch <= lsu_rdata;
        // AMO write: any AMO (not LR) or a successful SC.  At MEM2 the
        // operand source is mem1_mem2_q (LSU runs at MEM2 in 7c).
        amo_write_latch <= mem1_mem2_q.dec.is_amo & ~mem1_mem2_q.dec.is_lr
                         | mem1_mem2_q.dec.is_sc & dcache_sc_success;
      end
      if (mem_wb_en) begin
        mem_done_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '{default: '0, dec: kronos_pkg::DECODED_INSTR_ZERO,
                    fault: kronos_pkg::FAULT_ZERO};
    end else if (mem_wb_en) begin
      // Sources flow through mem1_mem2_q (registered MEM1 output).  Live MEM2
      // producers (bpred_mispredict_target, dcache_bus_err_fault) OR into the
      // fault aggregate alongside the registered MEM1-stage fault bits.
      mem_wb_q.dec        <= mem1_mem2_q.dec;
      mem_wb_q.alu_result <= mem1_mem2_q.alu_result;
      mem_wb_q.lsu_rdata  <= lsu_valid ? lsu_rdata : lsu_rdata_latch;
      mem_wb_q.csr_rdata  <= mem1_mem2_q.csr_rdata;
      mem_wb_q.pc4        <= mem1_mem2_q.pc + (mem1_mem2_q.is_16b ? 32'd2 : 32'd4);
      mem_wb_q.valid        <= mem1_mem2_q.valid;
      mem_wb_q.is_amo_write <= lsu_valid
                             ? (mem1_mem2_q.dec.is_amo & ~mem1_mem2_q.dec.is_lr
                              | mem1_mem2_q.dec.is_sc & dcache_sc_success)
                             : amo_write_latch;
      // Retire-trace field snapshots.
      mem_wb_q.pc         <= mem1_mem2_q.pc;
      mem_wb_q.instr      <= mem1_mem2_q.instr;
      mem_wb_q.mem_addr   <= mem1_mem2_q.alu_result;
      mem_wb_q.mem_wdata  <= mem1_mem2_q.rs2_data;
      mem_wb_q.csr_wdata  <= mem1_mem2_q.csr_wdata;
      // Full fault aggregate at retire.  Every MEM1-class bit is already in
      // mem1_mem2_q.fault.*; add live MEM2 producers (target mispredict,
      // dcache bus error).
      mem_wb_q.fault <= '{
        ecall:                   mem1_mem2_q.fault.ecall,
        ebreak:                  mem1_mem2_q.fault.ebreak,
        illegal:                 mem1_mem2_q.fault.illegal,
        is_mret:                 mem1_mem2_q.fault.is_mret,
        is_sret:                 mem1_mem2_q.fault.is_sret,
        csr_illegal:             mem1_mem2_q.fault.csr_illegal,
        mret_priv_fail:          mem1_mem2_q.fault.mret_priv_fail,
        sret_priv_fail:          mem1_mem2_q.fault.sret_priv_fail,
        satp_tvm_fail:           mem1_mem2_q.fault.satp_tvm_fail,
        wfi_priv_fail:           mem1_mem2_q.fault.wfi_priv_fail,
        irq_pending:             mem1_mem2_q.fault.irq_pending,
        bpred_dir_mispredict:    mem1_mem2_q.fault.bpred_dir_mispredict,
        pmp_fetch_fault:         mem1_mem2_q.fault.pmp_fetch_fault,
        pmp_data_fault:          mem1_mem2_q.fault.pmp_data_fault,
        ex_amo_nc_fault:         mem1_mem2_q.fault.ex_amo_nc_fault,
        trig_hit:                mem1_mem2_q.fault.trig_hit,
        instr_page_fault:        mem1_mem2_q.fault.instr_page_fault,
        load_page_fault:         mem1_mem2_q.fault.load_page_fault,
        store_page_fault:        mem1_mem2_q.fault.store_page_fault,
        bpred_target_mispredict: bpred_mispredict_target,
        dcache_bus_err_fault:    dcache_bus_err_fault
      };
    end
  end

  // =========================================================================
  // WB→ID bypass (64-bit, integer only)
  // =========================================================================
  assign wb_writing = mem_wb_q.valid & mem_wb_q.dec.rd_wen
                      & (mem_wb_q.dec.rd != 5'd0) & ~mem_wb_q.dec.rd_fp;

  // =========================================================================
  // WB stage (64-bit)
  // =========================================================================
  always_comb begin
    unique case (mem_wb_q.dec.wb_sel)
      WB_ALU:  wb_result_64 = mem_wb_q.alu_result;
      WB_MEM:  wb_result_64 = mem_wb_q.lsu_rdata;
      WB_PC4:  wb_result_64 = {32'b0, mem_wb_q.pc4};
      WB_CSR:  wb_result_64 = mem_wb_q.csr_rdata;
      default: wb_result_64 = mem_wb_q.alu_result;
    endcase

    // FP→int instructions (FCVT.W.S, FMV.X.W, FCLASS, FEQ, FLT, FLE) set
    // wb_sel = WB_ALU and mem_wb_q.alu_result holds fpu_result (captured at
    // the MEM/WB boundary above), so wb_result_64 is correct without an
    // explicit override here.
  end

  // =========================================================================
  // Retire-trace driver (simulation-only observability).
  //
  // Fires in the cycle that mem_wb_q advances past WB — i.e. when the
  // committed state of the instruction is visible on the WB mux and the
  // pipeline is not stalled.  The cycle aligns with the existing
  // instret_retire_i pulse (EX→MEM), but observed one stage later so that
  // the post-MEM results (LSU data, FP result) are present.
  //
  // Note on CSR write-enable: decoded_instr_t has no separate is_csr_write
  // bit — retire_csr_wen_o is asserted for any committed CSR instruction
  // (is_csr), matching what the CSR unit actually executes.  Trace consumers
  // should filter by csr_funct3 if they need to distinguish read-only CSR
  // accesses from read-modify-write ones.
  // =========================================================================
  assign retire_advance = mem_wb_q.valid & ~combined_stall;

  // ---- Performance-counter event bus ----------------------------------------
  // Single-cycle pulses for retire-tagged events; level signals for stall events.
  // Bus indices match mhpmeventX[7:0] event IDs:
  //   0x00 reserved-zero, 0x01 branch retired, 0x02 branch mispredict,
  //   0x03 load retired,  0x04 store retired, 0x05 mem stall,
  //   0x06 muldiv busy,    0x07 fpu busy,      0x08 trap taken.
  // 0x09..0x0F currently tied to 0; 0x10..0x1F reserved for future caches/OOO.

  // Mispredict pulse: combine the EX-stage branch mispredict and the MEM-stage
  // JALR target-mispredict, gated by ~combined_stall so a stalled cycle is not
  // counted twice.
  assign bpred_mispredict_pulse =
      (bpred_mispredict | bpred_mispredict_target) & ~combined_stall;

  // FPU busy: the FPU top exposes its own OR-reduced busy line via fpu_busy.
  assign fpu_busy_any = fpu_busy;

  // Stage 7a — trap-taken pulse fires at retire, in lockstep with u_csr.trap_i
  // and mem_redirect_q.  Same condition as u_csr.trap_i: any trap-class fault
  // bit in mem_wb_q.fault.  Drives the AMO reservation clear (rsrv_clear_i).
  assign trap_taken_pulse = mem_wb_q.valid & mem_wb_fault_any_trap & ~combined_stall;

  assign event_bus[ 0]    = 1'b0;
  assign event_bus[kronos_pkg::EVT_BRANCH_RETIRE]       =
      retire_advance & mem_wb_q.dec.is_branch;
  assign event_bus[kronos_pkg::EVT_BRANCH_MISPREDICT_P] = bpred_mispredict_pulse;
  assign event_bus[kronos_pkg::EVT_LOAD_RETIRE]         =
      retire_advance & mem_wb_q.dec.is_load;
  assign event_bus[kronos_pkg::EVT_STORE_RETIRE]        =
      retire_advance & mem_wb_q.dec.is_store;
  assign event_bus[kronos_pkg::EVT_MEM_STALL]           = mem_stall;
  assign event_bus[ 6]    = muldiv_stall;
  assign event_bus[ 7]    = fpu_busy_any;
  assign event_bus[kronos_pkg::EVT_TRAP_TAKEN]          = trap_taken_pulse;
  assign event_bus[15:9]  = 7'b0;
  assign event_bus[kronos_pkg::EVT_ICACHE_MISS]         = icache_miss_pulse;
  assign event_bus[kronos_pkg::EVT_DCACHE_MISS]         = dcache_miss_pulse;
  // Stage 5h taxonomy — fine-grained stall causes (IDs 0x14..0x1F).
  // Some IDs alias pre-existing low bits (muldiv=0x1B↔0x06, fpu=0x1C↔0x07,
  // mispredict=0x1E↔0x02) so the consolidated taxonomy table is contiguous.
  assign event_bus[18]    = 1'b0;
  assign event_bus[19]    = 1'b0;
  assign event_bus[kronos_pkg::EVT_LOAD_USE_STALL]      = load_use_event;
  assign event_bus[kronos_pkg::EVT_JALR_FWD_STALL]      = jalr_fwd_event;
  assign event_bus[kronos_pkg::EVT_FP_RAW_STALL]        = fp_load_use_event;
  assign event_bus[kronos_pkg::EVT_FRM_HAZARD_STALL]    = id_ex_is_frm_write & if_id_fp_dyn_rm;
  assign event_bus[kronos_pkg::EVT_FP_INFLIGHT_STALL]   = fpu_stall;
  assign event_bus[kronos_pkg::EVT_FENCE_I_DRAIN_STALL] = fence_i_active_q;
  assign event_bus[kronos_pkg::EVT_MEM_BUSY_STALL]      = lsu_mem_stall | dcache_stall;
  assign event_bus[kronos_pkg::EVT_MULDIV_STALL]        = muldiv_stall;
  assign event_bus[kronos_pkg::EVT_FPU_STALL]           = fpu_busy_any;
  assign event_bus[kronos_pkg::EVT_INSTR_FETCH_STALL]   = instr_fetch_stall;
  assign event_bus[kronos_pkg::EVT_BRANCH_MISPREDICT]   = bpred_mispredict_pulse;
  assign event_bus[kronos_pkg::EVT_EX_REDIRECT]         = ex_redirect_q;

  assign retire_valid_o      = retire_advance;
  assign retire_pc_o         = {32'b0, mem_wb_q.pc};
  assign retire_instr_o      = mem_wb_q.instr;
  assign retire_rd_wen_o     = retire_advance & mem_wb_q.dec.rd_wen & ~mem_wb_q.dec.rd_fp;
  assign retire_rd_o         = mem_wb_q.dec.rd;
  assign retire_rd_wdata_o   = wb_result_64;
  // FP writes: FP arithmetic (is_fp & rd_fp & ~fp_load) or FP load (fp_load)
  assign retire_fp_wen_o     = retire_advance &
                               ((mem_wb_q.dec.is_fp & mem_wb_q.dec.rd_fp & ~mem_wb_q.dec.fp_load) |
                                mem_wb_q.dec.fp_load);
  assign retire_fp_rd_o      = mem_wb_q.dec.rd;
  // FP arithmetic result is in alu_result; FP load NaN-boxes lower 32b (FLW) or uses full 64b (FLD)
  assign retire_fp_wdata_o   = mem_wb_q.dec.fp_load
                               ? (mem_wb_q.dec.mem_funct3[0]  // funct3[0]=1 → FLD (011), =0 → FLW (010)
                                  ? mem_wb_q.lsu_rdata
                                  : {kronos_pkg::FP_NANBOX_UPPER, mem_wb_q.lsu_rdata[31:0]})
                               : mem_wb_q.alu_result;

  assign retire_mem_wen_o    = retire_advance & (mem_wb_q.dec.is_store | mem_wb_q.is_amo_write);
  assign retire_mem_addr_o   = mem_wb_q.mem_addr;
  assign retire_mem_funct3_o = mem_wb_q.dec.mem_funct3;
  // Mask store data to the bytes actually written (matching Sail's trace format)
  assign retire_mem_wdata_o  = mem_wb_q.mem_wdata &
                               (mem_wb_q.dec.mem_funct3[1:0] == 2'b11 ? 64'hFFFF_FFFF_FFFF_FFFF :
                                mem_wb_q.dec.mem_funct3[1:0] == 2'b10 ? 64'h0000_0000_FFFF_FFFF :
                                mem_wb_q.dec.mem_funct3[1:0] == 2'b01 ? 64'h0000_0000_0000_FFFF :
                                                                         64'h0000_0000_0000_00FF);
  assign retire_csr_wen_o    = retire_advance & mem_wb_q.dec.is_csr;
  assign retire_csr_addr_o   = mem_wb_q.dec.csr_addr;
  assign retire_csr_wdata_o  = mem_wb_csr_new_val_q;
  assign retire_trap_taken_o = trap_taken_pulse;
  assign retire_trap_cause_o = trap_cause;

  // -------------------------------------------------------------------------
  // UNUSED sinks.
  //
  // 1) Submodule-output signals that are computed but never consumed at this
  //    top.  Most are upper-half slices of 64-bit signals that the stage-6
  //    32-bit-PC datapath only reads as [31:0]; a few are integrator-visible
  //    PTW / trigger / LSU outputs that are not yet wired to a top-level
  //    port (see issue #81).
  //
  // 2) PINCONNECTEMPTY sinks: submodule outputs we deliberately drop.
  //    The CSR sfence_*_o pins are pure passthroughs of the matching _i
  //    inputs (the top wires the local sfence_* signals straight to both
  //    TLBs), so we sink them here.
  //
  // OR-reduction over `^{...}` keeps the sinks free of synthesis side
  // effects while satisfying lint.
  // -------------------------------------------------------------------------
  assign _unused_top_signals = ^{
    alu_adder_out,
    trap_vector[63:32], mepc[63:32], sepc[63:32],
    jalr_target_64[63:32],
    mstatus[63:23], mstatus[16:13], mstatus[10:0],
    pmp_fetch_fault_addr[55:32],
    pmp_data_fault_addr[55:32],
    itlb_a_zero, itlb_d_zero,
    itlb_pa[55:32],
    dtlb_pa[55:32],
    ptw_busy,
    ptw_pf_cause,
    ptw_pf_tval,
    ptw_dc_req_size,
    align_stall, align_need_upper,
    lsu_fp_dest,
    trig_hit_pc,
    mem_wb_q.csr_wdata
  };

  assign _unused_top_pinconnect = ^{
    decode_illegal_unused,
    muldiv_busy_unused,
    csr_valid_unused,
    sfence_vma_csr_unused,
    sfence_va_csr_unused,
    sfence_asid_csr_unused,
    sfence_va_valid_csr_unused,
    sfence_asid_valid_csr_unused,
    lsu_sc_success_unused
  };

endmodule
