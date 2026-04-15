// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPU dispatch wrapper: routes in_valid_i to one of the five execution units,
// embeds the scoreboard for write-back hazard detection, and mux-reduces the
// five out_valid/result/fflags/tag buses onto a single shared output bus.
//
// Latency table (clock cycles from dispatch to out_valid):
//   FMISC  1  (FSGNJ*, FMIN, FMAX, FCLASS, FEQ, FLT, FLE, FMV.*)
//   FCVT   2  (FCVT.*.* integer↔FP conversions)
//   FADD   4  (FADD, FSUB)
//   FMUL   4  (FMUL)
//   FMA    5  (FMADD, FMSUB, FNMADD, FNMSUB)
//
// busy_o is asserted when in_valid_i is high and the scoreboard detects a
// write-back collision for the incoming operation.  The upstream stage must
// hold all inputs stable and re-present the same instruction every cycle
// while busy_o is high.

module kronos_fpu_top
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        in_valid_i,
  input  fp_op_e      op_i,
  input  logic        fmt_d_i,
  input  logic [2:0]  rm_i,
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [63:0] c_i,
  input  fpu_tag_t    tag_i,
  output logic        busy_o,
  output logic        out_valid_o,
  output logic [63:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // ---------------------------------------------------------------------------
  // Dispatch routing: determine unit and latency from op_i
  // ---------------------------------------------------------------------------
  logic [2:0] dispatch_latency;
  logic       sel_fmisc, sel_fcvt, sel_fadd, sel_fmul, sel_fma;

  always_comb begin
    sel_fmisc        = 1'b0;
    sel_fcvt         = 1'b0;
    sel_fadd         = 1'b0;
    sel_fmul         = 1'b0;
    sel_fma          = 1'b0;
    dispatch_latency = 3'd0;

    unique case (op_i)
      FP_FSGNJ, FP_FSGNJN, FP_FSGNJX,
      FP_FMIN,  FP_FMAX,
      FP_FCLASS,
      FP_FEQ,   FP_FLT,   FP_FLE,
      FP_FMV_X_W, FP_FMV_W_X, FP_FMV_X_D, FP_FMV_D_X: begin
        sel_fmisc        = 1'b1;
        dispatch_latency = 3'd1;
      end
      FP_FCVT_W_F, FP_FCVT_WU_F, FP_FCVT_L_F, FP_FCVT_LU_F,
      FP_FCVT_F_W, FP_FCVT_F_WU, FP_FCVT_F_L, FP_FCVT_F_LU,
      FP_FCVT_S_D, FP_FCVT_D_S: begin
        sel_fcvt         = 1'b1;
        dispatch_latency = 3'd2;
      end
      FP_FADD, FP_FSUB: begin
        sel_fadd         = 1'b1;
        dispatch_latency = 3'd4;
      end
      FP_FMUL: begin
        sel_fmul         = 1'b1;
        dispatch_latency = 3'd4;
      end
      FP_FMADD, FP_FMSUB, FP_FNMADD, FP_FNMSUB: begin
        sel_fma          = 1'b1;
        dispatch_latency = 3'd5;
      end
      default: begin
        // Unknown op: route nowhere, scoreboard will ignore (latency=0)
        sel_fmisc        = 1'b0;
        dispatch_latency = 3'd0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Scoreboard: hazard detection
  // ---------------------------------------------------------------------------
  logic grant_comb, grant;

  kronos_fpu_scoreboard #(.DEPTH(5)) u_scoreboard (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .flush_i      (flush_i),
    .req_i        (in_valid_i),
    .fp_dest_i    (tag_i.fp_dest),
    .int_dest_i   (~tag_i.fp_dest),
    .latency_i    (dispatch_latency),
    .grant_comb_o (grant_comb),
    .grant_o      (grant)
  );

  assign busy_o = in_valid_i & ~grant_comb;

  // Gate in_valid to each unit: only the selected unit receives it, and only
  // when the scoreboard grants the dispatch.
  logic dispatch_ok;
  assign dispatch_ok = in_valid_i & grant_comb;

  // ---------------------------------------------------------------------------
  // Execution unit instantiations
  // ---------------------------------------------------------------------------

  // Shared input bundle (all units see the same inputs; only one fires per cycle)
  logic        fmisc_out_valid, fcvt_out_valid, fadd_out_valid;
  logic        fmul_out_valid,  fma_out_valid;
  logic [63:0] fmisc_result, fcvt_result, fadd_result, fmul_result, fma_result;
  logic [4:0]  fmisc_fflags, fcvt_fflags, fadd_fflags, fmul_fflags, fma_fflags;
  fpu_tag_t    fmisc_tag,   fcvt_tag,   fadd_tag,   fmul_tag,   fma_tag;

  kronos_fpu_fmisc u_fmisc (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .in_valid_i (dispatch_ok & sel_fmisc),
    .op_i       (op_i),
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
    .c_i        (c_i),
    .tag_i      (tag_i),
    .out_valid_o(fmisc_out_valid),
    .result_o   (fmisc_result),
    .fflags_o   (fmisc_fflags),
    .tag_o      (fmisc_tag)
  );

  kronos_fpu_fcvt u_fcvt (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .in_valid_i (dispatch_ok & sel_fcvt),
    .op_i       (op_i),
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
    .c_i        (c_i),
    .tag_i      (tag_i),
    .out_valid_o(fcvt_out_valid),
    .result_o   (fcvt_result),
    .fflags_o   (fcvt_fflags),
    .tag_o      (fcvt_tag)
  );

  kronos_fpu_fadd u_fadd (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .in_valid_i (dispatch_ok & sel_fadd),
    .op_i       (op_i),
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
    .c_i        (c_i),
    .tag_i      (tag_i),
    .out_valid_o(fadd_out_valid),
    .result_o   (fadd_result),
    .fflags_o   (fadd_fflags),
    .tag_o      (fadd_tag)
  );

  kronos_fpu_fmul u_fmul (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .in_valid_i (dispatch_ok & sel_fmul),
    .op_i       (op_i),
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
    .c_i        (c_i),
    .tag_i      (tag_i),
    .out_valid_o(fmul_out_valid),
    .result_o   (fmul_result),
    .fflags_o   (fmul_fflags),
    .tag_o      (fmul_tag)
  );

  kronos_fpu_fma u_fma (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .in_valid_i (dispatch_ok & sel_fma),
    .op_i       (op_i),
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
    .c_i        (c_i),
    .tag_i      (tag_i),
    .out_valid_o(fma_out_valid),
    .result_o   (fma_result),
    .fflags_o   (fma_fflags),
    .tag_o      (fma_tag)
  );

  // ---------------------------------------------------------------------------
  // Output mux: at most one unit produces out_valid per cycle (scoreboard
  // invariant). Priority encode to form a single output bus.
  // ---------------------------------------------------------------------------
  always_comb begin
    out_valid_o = fmisc_out_valid | fcvt_out_valid | fadd_out_valid
                | fmul_out_valid  | fma_out_valid;
    if (fmisc_out_valid) begin
      result_o = fmisc_result;
      fflags_o = fmisc_fflags;
      tag_o    = fmisc_tag;
    end else if (fcvt_out_valid) begin
      result_o = fcvt_result;
      fflags_o = fcvt_fflags;
      tag_o    = fcvt_tag;
    end else if (fadd_out_valid) begin
      result_o = fadd_result;
      fflags_o = fadd_fflags;
      tag_o    = fadd_tag;
    end else if (fmul_out_valid) begin
      result_o = fmul_result;
      fflags_o = fmul_fflags;
      tag_o    = fmul_tag;
    end else begin
      result_o = fma_result;
      fflags_o = fma_fflags;
      tag_o    = fma_tag;
    end
  end

endmodule
