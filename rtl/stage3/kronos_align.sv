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
module kronos_align (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [31:0] rdata_i,
  input  logic        rvalid_i,
  input  logic        stall_i,        // hold state when pipeline can't accept output
  input  logic        flush_i,
  input  logic        pc_offset_i,    // ex_pc_next[1]: skip lower half of next fetch
  output logic [31:0] instr_o,
  output logic        instr_valid_o,
  output logic        is_16b_o,
  output logic        align_stall_o,
  output logic        align_need_upper_o,
  output logic        align_needs_fetch_o
);
  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  logic        buf_valid_q;
  logic [15:0] buf_data_q;
  logic        need_upper_q;
  logic        skip_lower_q;  // skip lower half of next fetched word (halfword-aligned flush)

  // Combinational from decompress instances
  logic [31:0] decomp_lower, decomp_upper, decomp_buf;
  logic        decomp_lower_ill, decomp_upper_ill, decomp_buf_ill;

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
    instr_o            = '0;
    instr_valid_o      = 1'b0;
    is_16b_o           = 1'b0;
    align_stall_o      = need_upper_q;
    align_need_upper_o = need_upper_q;

    if (skip_lower_q) begin
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
      if (buf_data_q[1:0] != 2'b11) begin
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
        if (rdata_i[1:0] != 2'b11) begin
          instr_o  = decomp_lower;
          is_16b_o = 1'b1;
        end else begin
          instr_o  = rdata_i;
          is_16b_o = 1'b0;
        end
      end
    end
  end

  // align_needs_fetch_o: deasserted only in BUFFERED state (buffer has instruction ready)
  assign align_needs_fetch_o = ~buf_valid_q | need_upper_q;

  // -------------------------------------------------------------------------
  // State update (sequential)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_valid_q  <= 1'b0;
      buf_data_q   <= '0;
      need_upper_q <= 1'b0;
      skip_lower_q <= 1'b0;
    end else if (flush_i) begin
      buf_valid_q  <= 1'b0;
      buf_data_q   <= '0;
      need_upper_q <= 1'b0;
      skip_lower_q <= pc_offset_i;
    end else if (!stall_i) begin
      // ---- Handle NEED_UPPER: clear on r_valid regardless of align_stall_o ----
      // (align_stall_o = need_upper_q, so we must not gate on !align_stall_o here)
      // After combining, the upper half of the fetched word is the start of the
      // next instruction — buffer it to avoid re-fetching the same word.
      if (need_upper_q) begin
        if (rvalid_i) begin
          buf_valid_q  <= 1'b1;
          buf_data_q   <= rdata_i[31:16];
          need_upper_q <= 1'b0;
        end
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
          if (buf_data_q[1:0] != 2'b11) begin
            // Consumed 16-bit from buffer; back to NORMAL
            buf_valid_q <= 1'b0;
          end else begin
            // Buffer holds lower 16 of 32-bit spanning insn; transition to NEED_UPPER
            need_upper_q <= 1'b1;
          end
        end else if (rvalid_i) begin
          // NORMAL: process incoming word
          if (rdata_i[1:0] != 2'b11) begin
            // 16-bit at lower half; buffer upper half
            buf_valid_q <= 1'b1;
            buf_data_q  <= rdata_i[31:16];
          end
          // else: 32-bit, no buffering
        end
      end
    end
  end

endmodule
