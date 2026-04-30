// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_align.sv — Fetch alignment buffer for RV32C variable-width instructions.
//
// Three primary states (encoded in buf_valid_q and need_upper_q):
//   NORMAL     : buf_valid_q=0, need_upper_q=0
//   BUFFERED   : buf_valid_q=1, need_upper_q=0  (upper half of prev word in buf)
//   NEED_UPPER : buf_valid_q=1, need_upper_q=1  (lower half of 32-bit spanning insn in buf)
//
// Additional state:
//   skip_lower_q: set on flush when pc_offset_i=1 (flush to halfword-aligned address).
//     On the next r_valid, skip the lower 16 bits and buffer the upper 16 bits instead.
//
// align_stall_o / align_need_upper_o: registered, avoid comb loop with hazard.
// align_needs_fetch_o: combinational — deasserted only in BUFFERED state.
//   Used to gate ar_valid in kronos_top so we don't re-fetch words already buffered.
module kronos_align
  import kronos_pkg::*;
(
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic [31:0]       pc_i,           // current fetch PC (used for cross-page detection)
  input  logic [INST_W-1:0] rdata_i,
  input  logic              rvalid_i,
  input  logic              stall_i,        // hold state when pipeline can't accept output
  input  logic              flush_i,
  input  logic              pc_offset_i,    // ex_pc_d[1]: skip lower half of next fetch
  input  logic              pmp_fault_i,    // suppress instr_valid_o while PMP fault is held
  // when translation is OFF (Bare or M-mode without MPRV-data), a
  // 32-bit instruction whose halves straddle a 4 KB boundary is perfectly
  // legal (no per-page permissions exist).  align must NOT raise a cross-page
  // fault in that case — otherwise M-mode RV64C tests that happen to land a
  // 32-bit instruction at pc[11:0]==0xFFE would spuriously trap on every such
  // fetch.  When translate_fetch_i=1 the cross-page fetch is conservatively
  // converted to an instruction-page fault.
  input  logic              translate_fetch_i,
  output logic [INST_W-1:0] instr_o,
  output logic              instr_valid_o,
  output logic              is_16b_o,
  output logic              align_stall_o,
  output logic              align_need_upper_o,
  output logic              align_needs_fetch_o,
  // cross-page 32-bit fetch fault.  Asserted only when translation
  // is active and the alignment unit is about to emit (or buffer the lo half
  // of) a 32-bit instruction whose PC straddles a 4 KB page boundary
  // (pc[11:1]==11'h7FF, so lo half at offset 0xFFE and hi half at offset
  // 0x1000 of the next page).  Conservative first cut: any such fetch under
  // translation is treated as an instruction-page fault.  A future refinement
  // can issue an independent translation for the hi half instead of faulting.
  output logic              cross_page_fault_o
);
  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  // RV opcode marker: instr[1:0]==2'b11 indicates a 32-bit instruction; any
  // other encoding indicates a 16-bit (RV-C) compressed instruction.
  localparam logic [1:0] OP_32B = 2'b11;

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  logic        buf_valid_q;
  logic [15:0] buf_data_q;
  logic        need_upper_q;
  logic        skip_lower_q;  // skip lower half of next fetched word (halfword-aligned flush)
  // span_valid_q / span_instr_q: latch a spanning 32-bit instruction when the
  // NEED_UPPER state update fires while the pipeline is stalled (stall_i=1).
  // Prevents a permanent deadlock where need_upper_q gets stuck at 1 when a
  // muldiv (or other multi-cycle) stall coincides with the r_valid pulse.
  logic              span_valid_q;
  logic [INST_W-1:0] span_instr_q;

  // Combinational from decompress instances
  logic [INST_W-1:0] decomp_lower, decomp_upper, decomp_buf;
  logic              decomp_lower_ill, decomp_upper_ill, decomp_buf_ill;

  // cross-page 32-bit fetch detection
  logic [15:0] lo_half;
  logic        cross_page_32b;

  kronos_decompress u_decomp_lower (
    .instr16_i (rdata_i[15:0]),
    .instr32_o (decomp_lower),
    .illegal_o (decomp_lower_ill)
  );
  kronos_decompress u_decomp_upper (
    .instr16_i (rdata_i[31:16]),
    .instr32_o (decomp_upper),
    .illegal_o (decomp_upper_ill)
  );
  kronos_decompress u_decomp_buf (
    .instr16_i (buf_data_q),
    .instr32_o (decomp_buf),
    .illegal_o (decomp_buf_ill)
  );

  // -------------------------------------------------------------------------
  // Output logic (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    instr_o            = {INST_W{1'b0}};
    instr_valid_o      = 1'b0;
    is_16b_o           = 1'b0;
    align_stall_o      = need_upper_q;
    align_need_upper_o = need_upper_q;

    if (span_valid_q) begin
      // Latched spanning instruction: pipeline was stalled when NEED_UPPER
      // received its r_valid. Serve from the latch.
      instr_o       = span_instr_q;
      instr_valid_o = 1'b1;
      is_16b_o      = 1'b0;
    end else if (skip_lower_q) begin
      // Waiting for first post-flush word, will skip lower half
      instr_valid_o = 1'b0;
    end else if (need_upper_q) begin
      // NEED_UPPER: combine buf (lower 16) with rdata[15:0] (upper 16)
      if (rvalid_i) begin
        instr_o       = {rdata_i[15:0], buf_data_q};
        instr_valid_o = 1'b1;
        is_16b_o      = 1'b0;
      end
    end else if (buf_valid_q) begin
      // BUFFERED: emit instruction from buffer
      if (buf_data_q[1:0] != OP_32B) begin
        instr_o       = decomp_buf;
        instr_valid_o = 1'b1;
        is_16b_o      = 1'b1;
      end
      // else: buffer has lower half of 32-bit spanning insn
      // need_upper_q will be set on next clock edge (FF block below)
    end else begin
      // NORMAL: use rdata directly
      if (rvalid_i) begin
        instr_valid_o = 1'b1;
        if (rdata_i[1:0] != OP_32B) begin
          instr_o  = decomp_lower;
          is_16b_o = 1'b1;
        end else begin
          instr_o  = rdata_i;
          is_16b_o = 1'b0;
        end
      end
    end

    // PMP fault on the fetch: do not emit a valid instruction.  The fault is
    // held by kronos_top and feeds the trap chain; align must not advance the
    // pipeline with garbage data while the trap takes the PC.
    if (pmp_fault_i) begin
      instr_valid_o = 1'b0;
    end

    // cross-page 32-bit fetch.  Suppress instr_valid_o so we never
    // emit a half-translated instruction; T13 will route cross_page_fault_o
    // into the trap chain alongside pmp_fetch_fault.
    if (cross_page_fault_o) begin
      instr_valid_o = 1'b0;
    end
  end

  // align_needs_fetch_o: deasserted only in BUFFERED state (buffer has instruction ready)
  assign align_needs_fetch_o = ~buf_valid_q | need_upper_q;

  // -------------------------------------------------------------------------
  // cross-page 32-bit fetch detection
  // -------------------------------------------------------------------------
  // pc[11:1]==11'h7FF marks the last halfword of a 4 KB page (pc[11:0]==0xFFE,
  // so pc[1]==1).  In that case, the halfword at pc lives in the upper 16 bits
  // of the fetched word (rdata_i[31:16]) — and once it has been buffered, in
  // buf_data_q.  A 32-bit instruction lo half has lo[1:0]==2'b11 (RV-C
  // compressed instructions have lo[1:0]!=2'b11, so they can never cross a
  // page in this sense).
  assign lo_half            = buf_valid_q ? buf_data_q : rdata_i[31:16];
  assign cross_page_32b     = (pc_i[11:1] == 11'h7FF) & (lo_half[1:0] == OP_32B);
  assign cross_page_fault_o = translate_fetch_i & cross_page_32b;

  // -------------------------------------------------------------------------
  // State update (sequential)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_valid_q  <= 1'b0;
      buf_data_q   <= {16{1'b0}};
      need_upper_q <= 1'b0;
      skip_lower_q <= 1'b0;
      span_valid_q <= 1'b0;
      span_instr_q <= {INST_W{1'b0}};
    end else if (flush_i) begin
      buf_valid_q  <= 1'b0;
      buf_data_q   <= {16{1'b0}};
      need_upper_q <= 1'b0;
      skip_lower_q <= pc_offset_i;
      span_valid_q <= 1'b0;
    end else begin
      // ---- Handle NEED_UPPER: always on r_valid, outside the stall gate ----
      // If the pipeline is stalled (stall_i=1) when r_valid fires, the AXI
      // beat is consumed by r_ready but the instruction data would otherwise be
      // lost.  Latch the combined 32-bit instruction in span_instr_q so it can
      // be served once the stall clears.  This prevents the need_upper_q ↔
      // muldiv_stall deadlock that occurs when every re-fetch arrives while
      // muldiv is still computing.
      if (need_upper_q && rvalid_i) begin
        buf_valid_q  <= 1'b1;
        buf_data_q   <= rdata_i[31:16];
        need_upper_q <= 1'b0;
        if (stall_i) begin
          span_instr_q <= {rdata_i[15:0], buf_data_q};
          span_valid_q <= 1'b1;
        end
      end else if (!stall_i) begin
        // ---- span latch: clear once the pipeline accepts the instruction ----
        if (span_valid_q) begin
          span_valid_q <= 1'b0;
          // buf already has the next instruction's lower 16 bits (set when
          // need_upper_q was cleared).  Do not advance buf this cycle; let the
          // normal BUFFERED path serve it on the next cycle.
        end else if (skip_lower_q) begin
          // ---- skip_lower: buffer the upper half of first post-flush word ----
          if (rvalid_i) begin
            skip_lower_q <= 1'b0;
            buf_valid_q  <= 1'b1;
            buf_data_q   <= rdata_i[31:16];
          end
        end else if (!align_stall_o) begin
          // ---- NORMAL / BUFFERED: advance state ----
          if (buf_valid_q) begin
            if (buf_data_q[1:0] != OP_32B) begin
              // Consumed 16-bit from buffer; back to NORMAL
              buf_valid_q <= 1'b0;
            end else begin
              // Buffer holds lower 16 of 32-bit spanning insn; go to NEED_UPPER
              need_upper_q <= 1'b1;
            end
          end else if (rvalid_i) begin
            // NORMAL: process incoming word
            if (rdata_i[1:0] != OP_32B) begin
              // 16-bit at lower half; buffer upper half
              buf_valid_q <= 1'b1;
              buf_data_q  <= rdata_i[31:16];
            end
            // else: 32-bit non-spanning, no buffering needed
          end
        end
      end
    end
  end

endmodule
