// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// sim_top.sv — Verilator simulation wrapper for kronos_top (stage3).
// Unpacks kronos_axi_req_t / kronos_axi_resp_t struct ports into flat signals
// so sim_main.cpp can drive/read them without packed-struct bit manipulation.
module sim_top
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        irq_timer_i,
  input  logic [14:0] irq_fast_i,
  input  logic [31:0] boot_addr_i,

  // Instr port — DUT outputs (AR channel)
  output logic        instr_ar_valid_o,
  output logic [63:0] instr_ar_addr_o,
  output logic [ 7:0] instr_ar_len_o,
  output logic [ 1:0] instr_ar_burst_o,
  // Instr port — DUT outputs (R channel)
  output logic        instr_r_ready_o,
  // Instr port — slave inputs (AR channel)
  input  logic        instr_ar_ready_i,
  // Instr port — slave inputs (R channel)
  input  logic        instr_r_valid_i,
  input  logic [63:0] instr_r_data_i,
  input  logic        instr_r_last_i,

  // Data port — DUT outputs (AR channel)
  output logic        data_ar_valid_o,
  output logic [63:0] data_ar_addr_o,
  output logic [ 7:0] data_ar_len_o,
  output logic [ 1:0] data_ar_burst_o,
  // Data port — DUT outputs (R channel)
  output logic        data_r_ready_o,
  // Data port — DUT outputs (AW channel)
  output logic        data_aw_valid_o,
  output logic [63:0] data_aw_addr_o,
  output logic [ 7:0] data_aw_len_o,
  output logic [ 1:0] data_aw_burst_o,
  // Data port — DUT outputs (W channel)
  output logic        data_w_valid_o,
  output logic [63:0] data_w_data_o,
  output logic [ 7:0] data_w_strb_o,
  output logic        data_w_last_o,
  // Data port — DUT outputs (B channel)
  output logic        data_b_ready_o,
  // Data port — slave inputs (AR channel)
  input  logic        data_ar_ready_i,
  // Data port — slave inputs (R channel)
  input  logic        data_r_valid_i,
  input  logic [63:0] data_r_data_i,
  input  logic        data_r_last_i,
  // Data port — slave inputs (AW/W channels)
  input  logic        data_aw_ready_i,
  input  logic        data_w_ready_i,
  // Data port — slave inputs (B channel)
  input  logic        data_b_valid_i,
  input  logic [ 1:0] data_b_resp_i,

  // Retire-trace outputs (simulation observability — stage 5 only; tied
  // to zero by stages 3/4 which do not emit retire traces).
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
  output logic        retire_trap_taken_o,
  output logic [31:0] retire_trap_cause_o
);

  kronos_axi_req_t  instr_req, data_req;
  kronos_axi_resp_t instr_rsp, data_rsp;

  // -------------------------------------------------------------------------
  // Unpack instr DUT outputs
  // -------------------------------------------------------------------------
  assign instr_ar_valid_o = instr_req.ar_valid;
  assign instr_ar_addr_o  = instr_req.ar.addr;
  assign instr_ar_len_o   = instr_req.ar.len;
  assign instr_ar_burst_o = instr_req.ar.burst;
  assign instr_r_ready_o  = instr_req.r_ready;

  // -------------------------------------------------------------------------
  // Pack instr slave inputs
  // -------------------------------------------------------------------------
  always_comb begin
    instr_rsp          = '0;
    instr_rsp.ar_ready = instr_ar_ready_i;
    instr_rsp.r_valid  = instr_r_valid_i;
    instr_rsp.r.data   = instr_r_data_i;
    instr_rsp.r.last   = instr_r_last_i;
  end

  // -------------------------------------------------------------------------
  // Unpack data DUT outputs
  // -------------------------------------------------------------------------
  assign data_ar_valid_o = data_req.ar_valid;
  assign data_ar_addr_o  = data_req.ar.addr;
  assign data_ar_len_o   = data_req.ar.len;
  assign data_ar_burst_o = data_req.ar.burst;
  assign data_r_ready_o  = data_req.r_ready;
  assign data_aw_valid_o = data_req.aw_valid;
  assign data_aw_addr_o  = data_req.aw.addr;
  assign data_aw_len_o   = data_req.aw.len;
  assign data_aw_burst_o = data_req.aw.burst;
  assign data_w_valid_o  = data_req.w_valid;
  assign data_w_data_o   = data_req.w.data;
  assign data_w_strb_o   = data_req.w.strb;
  assign data_w_last_o   = data_req.w.last;
  assign data_b_ready_o  = data_req.b_ready;

  // -------------------------------------------------------------------------
  // Pack data slave inputs
  // -------------------------------------------------------------------------
  always_comb begin
    data_rsp           = '0;
    data_rsp.ar_ready  = data_ar_ready_i;
    data_rsp.r_valid   = data_r_valid_i;
    data_rsp.r.data    = data_r_data_i;
    data_rsp.r.last    = data_r_last_i;
    data_rsp.aw_ready  = data_aw_ready_i;
    data_rsp.w_ready   = data_w_ready_i;
    data_rsp.b_valid   = data_b_valid_i;
    data_rsp.b.resp    = data_b_resp_i;
  end

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  kronos_top u_top (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .instr_axi_req_o    (instr_req),
    .instr_axi_rsp_i    (instr_rsp),
    .data_axi_req_o     (data_req),
    .data_axi_rsp_i     (data_rsp),
    .irq_timer_i        (irq_timer_i),
    .irq_fast_i         (irq_fast_i),
    // Stage 6a: standard RV interrupt sources — tied 0 in sim_top.  ACT4 priv
    // tests exercise these via the platform-IRQ path (irq_fast_i / irq_timer_i)
    // which OR into the same mip bits inside kronos_csr.
    .irq_msi_i          (1'b0),
    .irq_mei_i          (1'b0),
    .irq_ssi_i          (1'b0),
    .irq_sti_i          (1'b0),
    .irq_sei_i          (1'b0),
    .boot_addr_i        (boot_addr_i),
    .retire_valid_o     (retire_valid_o),
    .retire_pc_o        (retire_pc_o),
    .retire_instr_o     (retire_instr_o),
    .retire_rd_wen_o    (retire_rd_wen_o),
    .retire_rd_o        (retire_rd_o),
    .retire_rd_wdata_o  (retire_rd_wdata_o),
    .retire_fp_wen_o    (retire_fp_wen_o),
    .retire_fp_rd_o     (retire_fp_rd_o),
    .retire_fp_wdata_o  (retire_fp_wdata_o),
    .retire_mem_wen_o     (retire_mem_wen_o),
    .retire_mem_addr_o    (retire_mem_addr_o),
    .retire_mem_wdata_o   (retire_mem_wdata_o),
    .retire_mem_funct3_o  (retire_mem_funct3_o),
    .retire_csr_wen_o     (retire_csr_wen_o),
    .retire_csr_addr_o    (retire_csr_addr_o),
    .retire_csr_wdata_o   (retire_csr_wdata_o),
    .retire_trap_taken_o  (retire_trap_taken_o),
    .retire_trap_cause_o  (retire_trap_cause_o)
  );

endmodule
