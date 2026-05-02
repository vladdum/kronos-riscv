// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_fetch_buffer.sv — Standalone FIFO between the rewritten icache S2
// stage and the new predecode block.  Each entry carries the 4-byte-aligned
// PC of the fetched word alongside the data.  Producer and consumer share
// only the valid/ready handshake — no shared stall signal — which is the
// decoupling point that lets the BOOM-style frontend avoid the v1/v2 stall
// loops.
//
// flush_i is single-cycle: it drops all entries on the rising edge of clk_i
// while flush_i is asserted.  Push and pop semantics during flush: when
// flush_i is high, both ready outputs go low (no traffic gets through this
// cycle) so the redirect chain has a clean snapshot.
module kronos_fetch_buffer
  import kronos_pkg::*;
#(
  parameter int unsigned DEPTH = 4
)(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,

  // Producer side (icache S2)
  input  logic        enq_valid_i,
  input  logic [31:0] enq_pc_i,
  input  logic [31:0] enq_data_i,
  output logic        enq_ready_o,

  // Consumer side (predecode)
  output logic        deq_valid_o,
  output logic [31:0] deq_pc_o,
  output logic [31:0] deq_data_o,
  input  logic        deq_ready_i
);

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  localparam int unsigned PTR_W   = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned COUNT_W = $clog2(DEPTH + 1);

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------
  logic [31:0]        data_q [DEPTH];
  logic [31:0]        pc_q   [DEPTH];
  logic [PTR_W-1:0]   head_ptr_q;
  logic [PTR_W-1:0]   tail_ptr_q;
  logic [COUNT_W-1:0] count_q;

  // -------------------------------------------------------------------------
  // Combinational signals
  // -------------------------------------------------------------------------
  logic do_push;
  logic do_pop;

  // -------------------------------------------------------------------------
  // Handshake
  // -------------------------------------------------------------------------
  // The flush input clears `count_q` synchronously on the next rising edge,
  // so naturally-derived deq_valid_o / enq_ready_o values will return to a
  // clean state one cycle later.  We deliberately do NOT gate the handshake
  // signals with `~flush_i` here: in kronos_top, flush_i is driven by
  // `redirect_load`, which already lives on a long combinational chain
  // (mem_redirect/ex_redirect/pred_taken).  Gating the FB outputs with
  // flush_i would close a comb loop through the pipeline's stall chain
  // (flush_i → deq_valid_o → predecode.instr_valid_o → instr_fetch_stall →
  // combined_stall → trig_hit → ex_redirect → redirect_load = flush_i).
  // Wrong-path data emitted on the flush cycle is harmless because the
  // consuming IF/ID register is also flushed the same cycle.
  assign enq_ready_o = (count_q != COUNT_W'(DEPTH));
  assign deq_valid_o = (count_q != {COUNT_W{1'b0}});

  assign do_push = enq_valid_i & enq_ready_o;
  assign do_pop  = deq_ready_i & deq_valid_o;

  assign deq_data_o = data_q[head_ptr_q];
  assign deq_pc_o   = pc_q[head_ptr_q];

  // -------------------------------------------------------------------------
  // Sequential update
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_ptr_q <= {PTR_W{1'b0}};
      tail_ptr_q <= {PTR_W{1'b0}};
      count_q    <= {COUNT_W{1'b0}};
      for (int i = 0; i < DEPTH; i++) begin
        data_q[i] <= 32'h0;
        pc_q[i]   <= 32'h0;
      end
    end else if (flush_i) begin
      head_ptr_q <= {PTR_W{1'b0}};
      tail_ptr_q <= {PTR_W{1'b0}};
      count_q    <= {COUNT_W{1'b0}};
    end else begin
      if (do_push) begin
        data_q[tail_ptr_q] <= enq_data_i;
        pc_q[tail_ptr_q]   <= enq_pc_i;
        if (tail_ptr_q == PTR_W'(DEPTH - 1)) begin
          tail_ptr_q <= {PTR_W{1'b0}};
        end else begin
          tail_ptr_q <= tail_ptr_q + PTR_W'(1);
        end
      end
      if (do_pop) begin
        if (head_ptr_q == PTR_W'(DEPTH - 1)) begin
          head_ptr_q <= {PTR_W{1'b0}};
        end else begin
          head_ptr_q <= head_ptr_q + PTR_W'(1);
        end
      end
      unique case ({do_push, do_pop})
        2'b10:   count_q <= count_q + COUNT_W'(1);
        2'b01:   count_q <= count_q - COUNT_W'(1);
        2'b11:   count_q <= count_q;
        2'b00:   count_q <= count_q;
        default: count_q <= count_q;
      endcase
    end
  end

endmodule
