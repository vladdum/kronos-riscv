// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FPU dispatch wrapper: routes in_valid_i to one of the six execution units,
// embeds the scoreboard for write-back hazard detection, and mux-reduces the
// six out_valid/result/fflags/tag buses onto a single shared output bus.
//
// Latency table (clock cycles from dispatch to out_valid):
//   FMISC  1  (FSGNJ*, FMIN, FMAX, FCLASS, FEQ, FLT, FLE, FMV.*)
//   FCVT   3  (FCVT.*.* integer↔FP conversions)
//   FADD   7  (FADD, FSUB — s2b add/sub stage separates the 56-bit adder
//              from the S3 CLZ + normalize + sticky cone)
//   FMUL   9  (FMUL — s1b+s1c re-latch + s2a partial-product pipelining stage)
//   FMA    9  (FMADD, FMSUB, FNMADD, FNMSUB — s2b re-latch + s3b barrel-shift stage)
//   ITER   variable (FDIV, FSQRT) — late-reservation via scoreboard
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
  input  logic [FLEN-1:0] a_i,
  input  logic [FLEN-1:0] b_i,
  input  logic [FLEN-1:0] c_i,
  input  fpu_tag_t    tag_i,
  output logic        busy_o,
  output logic        out_valid_o,
  output logic [FLEN-1:0] result_o,
  output logic [4:0]  fflags_o,
  output fpu_tag_t    tag_o
);

  // ---------------------------------------------------------------------------
  // Combinational signals
  // ---------------------------------------------------------------------------
  // Dispatch routing
  logic [3:0] dispatch_latency;
  logic       sel_fmisc;
  logic       sel_fcvt;
  logic       sel_fadd;
  logic       sel_fmul;
  logic       sel_fma;
  logic       sel_iter;
  logic       dispatch_ok;

  // Scoreboard
  logic       grant_comb;
  logic       grant;
  logic       iter_late_req;
  logic       iter_late_fp_dest;
  logic       iter_late_grant;
  logic       iter_busy;

  // Per-unit output buses
  logic        fmisc_out_valid;
  logic        fcvt_out_valid;
  logic        fadd_out_valid;
  logic        fmul_out_valid;
  logic        fma_out_valid;
  logic        iter_out_valid;
  logic [FLEN-1:0] fmisc_result;
  logic [FLEN-1:0] fcvt_result;
  logic [FLEN-1:0] fadd_result;
  logic [FLEN-1:0] fmul_result;
  logic [FLEN-1:0] fma_result;
  logic [FLEN-1:0] iter_result;
  logic [4:0]  fmisc_fflags;
  logic [4:0]  fcvt_fflags;
  logic [4:0]  fadd_fflags;
  logic [4:0]  fmul_fflags;
  logic [4:0]  fma_fflags;
  logic [4:0]  iter_fflags;
  fpu_tag_t    fmisc_tag;
  fpu_tag_t    fcvt_tag;
  fpu_tag_t    fadd_tag;
  fpu_tag_t    fmul_tag;
  fpu_tag_t    fma_tag;
  fpu_tag_t    iter_tag;

`ifndef SYNTHESIS
  // Assertion helper: count of units asserting out_valid this cycle.
  logic [2:0] valid_count;
`endif

  // ---------------------------------------------------------------------------
  // Dispatch routing: determine unit and latency from op_i
  // ---------------------------------------------------------------------------
  always_comb begin
    sel_fmisc        = 1'b0;
    sel_fcvt         = 1'b0;
    sel_fadd         = 1'b0;
    sel_fmul         = 1'b0;
    sel_fma          = 1'b0;
    sel_iter         = 1'b0;
    dispatch_latency = 4'd0;

    unique case (op_i)
      FP_FSGNJ, FP_FSGNJN, FP_FSGNJX,
      FP_FMIN,  FP_FMAX,
      FP_FCLASS,
      FP_FEQ,   FP_FLT,   FP_FLE,
      FP_FMV_X_W, FP_FMV_W_X, FP_FMV_X_D, FP_FMV_D_X: begin
        sel_fmisc        = 1'b1;
        dispatch_latency = 4'd1;
      end
      FP_FCVT_W_F, FP_FCVT_WU_F, FP_FCVT_L_F, FP_FCVT_LU_F,
      FP_FCVT_F_W, FP_FCVT_F_WU, FP_FCVT_F_L, FP_FCVT_F_LU,
      FP_FCVT_S_D, FP_FCVT_D_S: begin
        sel_fcvt         = 1'b1;
        dispatch_latency = 4'd3;
      end
      FP_FADD, FP_FSUB: begin
        sel_fadd         = 1'b1;
        dispatch_latency = 4'd7;
      end
      FP_FMUL: begin
        sel_fmul         = 1'b1;
        dispatch_latency = 4'd9;
      end
      FP_FMADD, FP_FMSUB, FP_FNMADD, FP_FNMSUB: begin
        sel_fma          = 1'b1;
        dispatch_latency = 4'd9;
      end
      FP_FDIV, FP_FSQRT: begin
        sel_iter         = 1'b1;
        dispatch_latency = 4'd0;  // not registered at dispatch (late-reservation)
      end
      default: begin
        // Unknown op: route nowhere, scoreboard will ignore (latency=0)
        sel_fmisc        = 1'b0;
        dispatch_latency = 4'd0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Scoreboard: hazard detection
  // ---------------------------------------------------------------------------
  kronos_fpu_scoreboard #(.DEPTH(9)) u_scoreboard (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .flush_i           (flush_i),
    .req_i             (in_valid_i),
    .fp_dest_i         (tag_i.fp_dest),
    .int_dest_i        (~tag_i.fp_dest),
    .latency_i         (dispatch_latency),
    .grant_comb_o      (grant_comb),
    .grant_o           (grant),
    .late_req_i        (iter_late_req),
    .late_fp_dest_i    (iter_late_fp_dest),
    .late_latency_i    (4'd1),
    .late_grant_comb_o (iter_late_grant)
  );

  // busy_o: scoreboard collision OR iterative unit busy (can't accept new op)
  assign busy_o = (in_valid_i & ~grant_comb) | (sel_iter & in_valid_i & iter_busy);

  // Gate in_valid to each unit: only the selected unit receives it, and only
  // when the scoreboard grants the dispatch.
  assign dispatch_ok = in_valid_i & grant_comb;

  // ---------------------------------------------------------------------------
  // Execution unit instantiations
  // ---------------------------------------------------------------------------
  // Shared input bundle (all units see the same inputs; only one fires per cycle)

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
    .tag_i      (tag_i),
    .out_valid_o(fcvt_out_valid),
    .result_o   (fcvt_result),
    .fflags_o   (fcvt_fflags),
    .tag_o      (fcvt_tag)
  );

  // fadd/fmul don't take a third operand — c_i is FMA-only.
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
    .fmt_d_i    (fmt_d_i),
    .rm_i       (rm_i),
    .a_i        (a_i),
    .b_i        (b_i),
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

  // Iterative unit (FDIV, FSQRT) — variable latency, late-reservation
  kronos_fpu_iter u_iter (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .flush_i         (flush_i),
    .in_valid_i      (dispatch_ok & sel_iter & ~iter_busy),
    .op_i            (op_i),
    .fmt_d_i         (fmt_d_i),
    .rm_i            (rm_i),
    .a_i             (a_i),
    .b_i             (b_i),
    .tag_i           (tag_i),
    .busy_o          (iter_busy),
    .out_valid_o     (iter_out_valid),
    .result_o        (iter_result),
    .fflags_o        (iter_fflags),
    .tag_o           (iter_tag),
    .sb_late_req_o   (iter_late_req),
    .sb_late_fp_dest_o(iter_late_fp_dest),
    .sb_late_grant_i (iter_late_grant)
  );

  // ---------------------------------------------------------------------------
  // Output mux: at most one unit produces out_valid per cycle (scoreboard
  // invariant). Priority encode to form a single output bus.
  // ---------------------------------------------------------------------------
  always_comb begin
    out_valid_o = fmisc_out_valid | fcvt_out_valid | fadd_out_valid
                | fmul_out_valid  | fma_out_valid  | iter_out_valid;
    result_o = {FLEN{1'b0}};
    fflags_o = 5'h0;
    tag_o    = fpu_tag_t'(0);
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
    end else if (fma_out_valid) begin
      result_o = fma_result;
      fflags_o = fma_fflags;
      tag_o    = fma_tag;
    end else if (iter_out_valid) begin
      result_o = iter_result;
      fflags_o = iter_fflags;
      tag_o    = iter_tag;
    end
  end

`ifndef SYNTHESIS
  // Scoreboard invariant: at most one FPU unit may assert out_valid per cycle.
  // If this fires, the silent-drop bug from C-3 (kronos_fpu_iter late-grant
  // interlock) has reappeared.
  always_comb begin
    valid_count = 3'(fmisc_out_valid) + 3'(fcvt_out_valid)
                + 3'(fadd_out_valid)  + 3'(fmul_out_valid)
                + 3'(fma_out_valid)   + 3'(iter_out_valid);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (rst_ni) begin
      assert (valid_count <= 3'd1)
        else $error("kronos_fpu_top: %0d units asserted out_valid simultaneously",
                    valid_count);
    end
  end
`endif

endmodule
