// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_predecode.sv — Replaces kronos_align.  Operates on one 4-byte-aligned
// word at a time taken from the head of the fetch buffer (FB) and emits one
// 32-bit (or RVC-expanded) instruction per cycle to decode.
//
// The block tracks two pieces of state:
//   - prev_half_q   : the lower 16 bits of a 32-bit instruction whose halves
//                     span two consecutive FB entries (i.e. lo half at pc[1]=1
//                     of word N, hi half at pc[1]=0 of word N+1).
//   - word_lower_consumed_q : set when the lower 16 bits of the FB head have
//                     already been emitted (RVC at lower) but the upper 16
//                     bits are still pending in the same word.
//
// "Effective PC" = word_pc_i | (word_lower_consumed_q ? 32'h2 : 32'h0).
// A fresh post-redirect flush with flush_pc_offset_i=1 primes
// word_lower_consumed_q so the first FB entry is read from its upper half.
//
// Backpressure: while instr_valid_o & ~instr_ready_i no state advances and
// word_consume_o stays low.  Predecode never holds in-flight state across a
// redirect — flush_i clears prev_half_q and word_lower_consumed_q in one
// cycle.
module kronos_predecode
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        flush_pc_offset_i,

  // Input: word from FB head
  input  logic        word_valid_i,
  input  logic [31:0] word_data_i,
  input  logic [31:0] word_pc_i,
  output logic        word_consume_o,

  // Output: decoded instruction to decode
  output logic        instr_valid_o,
  output logic [31:0] instr_o,
  output logic [31:0] instr_pc_o,
  output logic        instr_is_16b_o,
  input  logic        instr_ready_i,

  // Faults
  output logic        cross_page_fault_o,
  input  logic        translate_fetch_i
);

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  localparam logic [1:0] OP_32B = 2'b11;

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  logic        prev_half_valid_q;
  logic [15:0] prev_half_data_q;
  logic [31:0] prev_half_pc_q;
  logic        word_lower_consumed_q;

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  logic        eff_upper;            // effective pc[1]
  logic [31:0] hi_combined;          // {word_data_i[15:0], prev_half_data_q}
  logic [15:0] lower_half;
  logic [15:0] upper_half;
  logic        is_rvc_lower;
  logic        is_rvc_upper;

  // Decompressor outputs
  logic [31:0] decomp_lower_d;
  logic        decomp_lower_ill_d;
  logic [31:0] decomp_upper_d;
  logic        decomp_upper_ill_d;

  // Internal classifier flags (one-hot)
  logic case_combine_span;            // prev_half_valid_q : combine + emit 32b
  logic case_rvc_lower;               // emit RVC at lower half
  logic case_32b_nonspan;             // 32b non-spanning emit
  logic case_rvc_upper;               // emit RVC at upper half
  logic case_span_lower;              // buffer lower-of-span into prev_half

  // Cross-page fault gating
  logic span_page_cross;              // a span attempt at page-end
  logic combine_page_cross;           // combining halves where lo is page-end
  logic raw_cross_page;
  logic fault_active;

  // Internal "would emit / advance" tags
  logic emit_request;                 // would emit this cycle ignoring ready
  logic state_advance;                // would advance state ignoring ready
  logic do_advance;                   // gated on instr_ready_i / fault

  // -------------------------------------------------------------------------
  // Decompressor instances (combinational)
  // -------------------------------------------------------------------------
  kronos_decompress u_decomp_lower (
    .instr16_i (lower_half),
    .instr32_o (decomp_lower_d),
    .illegal_o (decomp_lower_ill_d)
  );
  kronos_decompress u_decomp_upper (
    .instr16_i (upper_half),
    .instr32_o (decomp_upper_d),
    .illegal_o (decomp_upper_ill_d)
  );

  // -------------------------------------------------------------------------
  // Classifier
  // -------------------------------------------------------------------------
  always_comb begin
    eff_upper          = word_lower_consumed_q;
    lower_half         = word_data_i[15:0];
    upper_half         = word_data_i[31:16];
    hi_combined        = {word_data_i[15:0], prev_half_data_q};

    is_rvc_lower       = (word_data_i[1:0]   != OP_32B);
    is_rvc_upper       = (word_data_i[17:16] != OP_32B);

    case_combine_span  = prev_half_valid_q & word_valid_i;
    case_rvc_lower     = ~prev_half_valid_q & word_valid_i & ~eff_upper &  is_rvc_lower;
    case_32b_nonspan   = ~prev_half_valid_q & word_valid_i & ~eff_upper & ~is_rvc_lower;
    case_rvc_upper     = ~prev_half_valid_q & word_valid_i &  eff_upper &  is_rvc_upper;
    case_span_lower    = ~prev_half_valid_q & word_valid_i &  eff_upper & ~is_rvc_upper;

    // Span lower lives at half-aligned PC = word_pc_i | 2, so its [11:1] is
    // {word_pc_i[11:2], 1'b1}.  Cross-page fault when that == 11'h7FF, i.e.
    // word_pc_i[11:2] == 10'h3FF.
    span_page_cross    = case_span_lower & (word_pc_i[11:2] == 10'h3FF);
    combine_page_cross = case_combine_span & (prev_half_pc_q[11:1] == 11'h7FF);
    raw_cross_page     = span_page_cross | combine_page_cross;
    fault_active       = translate_fetch_i & raw_cross_page;
  end

  // -------------------------------------------------------------------------
  // Output mux
  // -------------------------------------------------------------------------
  always_comb begin
    instr_o        = 32'h0;
    instr_pc_o     = 32'h0;
    instr_is_16b_o = 1'b0;
    emit_request   = 1'b0;

    if (case_combine_span) begin
      instr_o        = hi_combined;
      instr_pc_o     = prev_half_pc_q;
      instr_is_16b_o = 1'b0;
      emit_request   = 1'b1;
    end else if (case_rvc_lower) begin
      instr_o        = decomp_lower_d;
      instr_pc_o     = word_pc_i;
      instr_is_16b_o = 1'b1;
      emit_request   = 1'b1;
    end else if (case_32b_nonspan) begin
      instr_o        = word_data_i;
      instr_pc_o     = word_pc_i;
      instr_is_16b_o = 1'b0;
      emit_request   = 1'b1;
    end else if (case_rvc_upper) begin
      instr_o        = decomp_upper_d;
      instr_pc_o     = word_pc_i | 32'h2;
      instr_is_16b_o = 1'b1;
      emit_request   = 1'b1;
    end
    // case_span_lower: no emit this cycle.
  end

  // instr_valid_o suppressed under cross-page fault.  Fault output is
  // qualified separately; downstream trap chain drains it without consuming
  // an instruction.
  assign instr_valid_o      = emit_request & ~fault_active;
  assign cross_page_fault_o = fault_active;

  // state_advance: a non-fault transaction that the consumer accepts (or a
  // span-lower buffering, which has no instr_valid_o but does advance state).
  // case_span_lower must also hold under fault — when fault_active fires we
  // hand off to the trap chain and freeze.
  assign state_advance = (emit_request & instr_ready_i) | case_span_lower;
  assign do_advance    = state_advance & ~fault_active;

  // word_consume_o: pop the FB head when this cycle "finishes" the word.
  // - case_combine_span : we used word_data_i[15:0]; upper half still pending.
  //                       Mark word_lower_consumed_q so we re-read it; do NOT pop.
  // - case_rvc_lower    : same — upper half still pending. Do NOT pop.
  // - case_32b_nonspan  : whole word consumed. Pop.
  // - case_rvc_upper    : upper half consumed; word done. Pop.
  // - case_span_lower   : upper half buffered into prev_half. Pop.
  always_comb begin
    word_consume_o = 1'b0;
    if (do_advance) begin
      if (case_32b_nonspan | case_rvc_upper | case_span_lower) begin
        word_consume_o = 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential state
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_half_valid_q     <= 1'b0;
      prev_half_data_q      <= 16'h0;
      prev_half_pc_q        <= 32'h0;
      word_lower_consumed_q <= 1'b0;
    end else if (flush_i) begin
      prev_half_valid_q     <= 1'b0;
      prev_half_data_q      <= 16'h0;
      prev_half_pc_q        <= 32'h0;
      word_lower_consumed_q <= flush_pc_offset_i;
    end else if (do_advance) begin
      // Default — most cases reset both state bits unless overridden.
      prev_half_valid_q     <= 1'b0;
      word_lower_consumed_q <= 1'b0;
      if (case_combine_span) begin
        // Combined halves consumed; upper half of the current word is the
        // next fragment.  Re-read same FB head from its upper half.
        prev_half_valid_q     <= 1'b0;
        word_lower_consumed_q <= 1'b1;
      end else if (case_rvc_lower) begin
        // RVC at lower; upper half still pending in same word.
        prev_half_valid_q     <= 1'b0;
        word_lower_consumed_q <= 1'b1;
      end else if (case_span_lower) begin
        // Upper half of the current word is the lower half of a 32b span.
        // Stash it; prev_half_pc_q is the half-aligned PC of that lower half
        // (= word_pc_i | 2).
        prev_half_valid_q     <= 1'b1;
        prev_half_data_q      <= upper_half;
        prev_half_pc_q        <= word_pc_i | 32'h2;
        word_lower_consumed_q <= 1'b0;
      end
      // case_rvc_upper and case_32b_nonspan: defaults already correct.
    end
  end

endmodule
