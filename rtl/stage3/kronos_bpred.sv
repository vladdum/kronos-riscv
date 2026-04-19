// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_bpred.sv — Bimodal branch predictor with Branch Target Buffer.
//
// Bimodal table: 2^BPRED_BITS entries of 2-bit saturating counters.
//   Index:  pc[BPRED_BITS+1:2]
//   Predict taken when counter[1]=1 (10 or 11)
//
// BTB: 2^BTB_BITS direct-mapped entries.
//   Index:  pc[BTB_BITS+1:2]
//   Tag:    pc[31:BTB_BITS+2]
//   Hit:    entry.valid && (entry.tag == pc[31:BTB_BITS+2])
//
// Prediction: pred_taken = BTB hit AND counter MSB=1.
// Updates happen two cycles after EX: update inputs are pipelined through a
// one-stage register (_q suffix) inside this module to break the long
// mem_wb -> WB->EX forwarding cone feeding upd_target_i.
module kronos_bpred
  import kronos_pkg::*;
#(
  parameter int unsigned BPRED_BITS = 6,
  parameter int unsigned BTB_BITS   = 4
)
(
  input  logic        clk_i,
  input  logic        rst_ni,
  // Prediction port (combinational)
  input  logic [31:0] pc_i,
  output logic        pred_taken_o,
  output logic [31:0] pred_target_o,
  // Update port (2-cycle registered path — fires when a branch resolves)
  input  logic        upd_valid_i,
  input  logic [31:0] upd_pc_i,
  input  logic        upd_taken_i,
  input  logic [31:0] upd_target_i,
  input  logic        upd_is_jal_i    // JAL always taken — skip counter update
);
  localparam int unsigned BPRED_ENTRIES = 1 << BPRED_BITS;
  localparam int unsigned BTB_ENTRIES   = 1 << BTB_BITS;
  localparam int unsigned BTB_TAG_BITS  = 32 - BTB_BITS - 2;

  // 2-bit saturating counters (one per bimodal table entry)
  logic [1:0] counters [BPRED_ENTRIES];

  // BTB (direct-mapped)
  btb_entry_t btb [BTB_ENTRIES];

  // Lookup index signals
  logic [BPRED_BITS-1:0]     lookup_idx;
  logic [BTB_BITS-1:0]       lookup_btb_idx;
  logic [BTB_TAG_BITS-1:0]   lookup_tag;

  // Update index signals
  logic [BPRED_BITS-1:0]     update_idx;
  logic [BTB_BITS-1:0]       update_btb_idx;
  logic [BTB_TAG_BITS-1:0]   update_tag;

  // BTB lookup result
  logic btb_hit;

  // -----------------------------------------------------------------------
  // Update-port pipeline register (timing fix: breaks the
  // mem_wb_q -> WB->EX forwarding -> ex_pc_next -> btb write cone).
  // Updates now fire 2 cycles after EX instead of 1 -- no correctness
  // impact (predictor only).
  // -----------------------------------------------------------------------
  logic        upd_valid_q;
  logic [31:0] upd_pc_q;
  logic        upd_taken_q;
  logic [31:0] upd_target_q;
  logic        upd_is_jal_q;

  assign lookup_idx     = pc_i[BPRED_BITS+1:2];
  assign lookup_btb_idx = pc_i[BTB_BITS+1:2];
  assign lookup_tag     = pc_i[31:BTB_BITS+2];

  assign update_idx     = upd_pc_q[BPRED_BITS+1:2];
  assign update_btb_idx = upd_pc_q[BTB_BITS+1:2];
  assign update_tag     = upd_pc_q[31:BTB_BITS+2];

  assign btb_hit       = btb[lookup_btb_idx].valid &&
                         (btb[lookup_btb_idx].tag == BTB_TAG_BITS'(lookup_tag));
  assign pred_taken_o  = btb_hit && counters[lookup_idx][1];
  assign pred_target_o = btb[lookup_btb_idx].target;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_upd_pipe
    if (!rst_ni) begin
      upd_valid_q  <= 1'b0;
      upd_pc_q     <= '0;
      upd_taken_q  <= 1'b0;
      upd_target_q <= '0;
      upd_is_jal_q <= 1'b0;
    end else begin
      upd_valid_q  <= upd_valid_i;
      upd_pc_q     <= upd_pc_i;
      upd_taken_q  <= upd_taken_i;
      upd_target_q <= upd_target_i;
      upd_is_jal_q <= upd_is_jal_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_update
    if (!rst_ni) begin
      for (int i = 0; i < BPRED_ENTRIES; i++) counters[i] <= 2'b01; // weak NT
      for (int i = 0; i < BTB_ENTRIES;   i++) btb[i]      <= '0;
    end else if (upd_valid_q) begin
      // Update 2-bit saturating counter — only for conditional branches, not JAL
      if (!upd_is_jal_q) begin
        if (upd_taken_q) begin
          if (counters[update_idx] != 2'b11)
            counters[update_idx] <= counters[update_idx] + 2'd1;
        end else begin
          if (counters[update_idx] != 2'b00)
            counters[update_idx] <= counters[update_idx] - 2'd1;
        end
      end

      // Update BTB: write on taken or JAL; clear only when counter saturates at 00
      if (upd_taken_q || upd_is_jal_q) begin
        btb[update_btb_idx].valid  <= 1'b1;
        btb[update_btb_idx].tag    <= BTB_TAG_BITS'(update_tag);
        btb[update_btb_idx].target <= upd_target_q;
      end else begin
        // Not-taken conditional branch: counter will decrement to 00 — invalidate BTB entry
        if (counters[update_idx] == 2'b01) begin
          if (btb[update_btb_idx].valid &&
              btb[update_btb_idx].tag == BTB_TAG_BITS'(update_tag))
            btb[update_btb_idx].valid <= 1'b0;
        end
      end
    end
  end

endmodule
