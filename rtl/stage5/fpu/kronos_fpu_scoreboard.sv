// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module kronos_fpu_scoreboard #(
  parameter int unsigned DEPTH = 5  // max FPU latency
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       flush_i,
  // Dispatch probe
  input  logic       req_i,
  input  logic       fp_dest_i,   // instruction writes FP regfile
  input  logic       int_dest_i,  // instruction writes integer regfile
  input  logic [2:0] latency_i,   // 1..DEPTH
  output logic       grant_comb_o, // combinational grant (for dispatch gating)
  output logic       grant_o,      // registered grant (stable post-posedge)
  // Late probe — iterative unit reserves a writeback slot at ROUND time
  input  logic       late_req_i,
  input  logic       late_fp_dest_i,
  input  logic [2:0] late_latency_i,
  output logic       late_grant_comb_o
);
  typedef struct packed {
    logic fp;
    logic intr;
  } slot_t;

  // slots_q[i] = reservation for writeback arriving (i+1) cycles from now.
  // The vector shifts left every clock: slot[0] is consumed, slot[DEPTH-1] freed.
  //
  // Indexing: for a dispatch with latency L, the writeback slot is slots_q[L-1].
  //   - Collision check: read slots_q[L-1] before this posedge.
  //   - Reservation write: override slots_n[L-1] (post-shift) with the grant.
  //     Because the shift computes slots_n[i]=slots_q[i+1], overriding slots_n[L-1]
  //     leaves slots_q[L-1] = reserved after this posedge, which naturally drifts
  //     toward slot[0] over L clock cycles.
  slot_t slots_q [DEPTH];
  slot_t slots_n [DEPTH];

  // Registered grant: captures the combinational decision at posedge so that
  // the TB's "@(posedge clk) #1" read sees a stable value.
  logic grant_q;
  logic grant_comb;

  // Target slot fields, selected by latency.
  logic target_fp, target_intr;
  logic collision;

  // Late-probe signals.
  logic late_target_fp;
  logic late_collision;
  logic late_grant_comb;

  always_comb begin
    // Select the target slot for the incoming dispatch (latency L → slot L-1).
    target_fp   = 1'b0;
    target_intr = 1'b0;
    unique case (latency_i)
      3'd1:    begin target_fp = slots_q[0].fp; target_intr = slots_q[0].intr; end
      3'd2:    begin target_fp = slots_q[1].fp; target_intr = slots_q[1].intr; end
      3'd3:    begin target_fp = slots_q[2].fp; target_intr = slots_q[2].intr; end
      3'd4:    begin target_fp = slots_q[3].fp; target_intr = slots_q[3].intr; end
      3'd5:    begin target_fp = slots_q[4].fp; target_intr = slots_q[4].intr; end
      default: begin target_fp = 1'b0;          target_intr = 1'b0;            end
    endcase

    collision = 1'b0;
    if (req_i) begin
      if (fp_dest_i  && target_fp)   collision = 1'b1;
      if (int_dest_i && target_intr) collision = 1'b1;
    end

    grant_comb = req_i & ~collision;

    // Shift: consume slot[0], free slot[DEPTH-1].
    for (int i = 0; i < DEPTH-1; i++) slots_n[i] = slots_q[i+1];
    slots_n[DEPTH-1] = '0;

    // On grant, reserve slot L-1 in the next state (overrides the shift result
    // for that index, preserving it one more cycle and allowing time to elapse).
    if (grant_comb) begin
      unique case (latency_i)
        3'd1:    begin slots_n[0].fp = slots_n[0].fp | fp_dest_i;
                       slots_n[0].intr = slots_n[0].intr | int_dest_i; end
        3'd2:    begin slots_n[1].fp = slots_n[1].fp | fp_dest_i;
                       slots_n[1].intr = slots_n[1].intr | int_dest_i; end
        3'd3:    begin slots_n[2].fp = slots_n[2].fp | fp_dest_i;
                       slots_n[2].intr = slots_n[2].intr | int_dest_i; end
        3'd4:    begin slots_n[3].fp = slots_n[3].fp | fp_dest_i;
                       slots_n[3].intr = slots_n[3].intr | int_dest_i; end
        3'd5:    begin slots_n[4].fp = slots_n[4].fp | fp_dest_i;
                       slots_n[4].intr = slots_n[4].intr | int_dest_i; end
        default: ; // latency out of range, do nothing
      endcase
    end

    // Late probe: iterative unit reserves a writeback slot at ROUND time.
    // Collision check is FP-only (iterative unit always writes FP regfile).
    late_target_fp = 1'b0;
    unique case (late_latency_i)
      3'd1:    late_target_fp = slots_q[0].fp;
      3'd2:    late_target_fp = slots_q[1].fp;
      3'd3:    late_target_fp = slots_q[2].fp;
      3'd4:    late_target_fp = slots_q[3].fp;
      3'd5:    late_target_fp = slots_q[4].fp;
      default: late_target_fp = 1'b0;
    endcase

    late_collision  = late_req_i & (late_fp_dest_i & late_target_fp);
    late_grant_comb = late_req_i & ~late_collision;

    // On late grant, OR-in the reservation (mutually exclusive with dispatch
    // at the system level, but structurally OR'd for safety).
    if (late_grant_comb) begin
      unique case (late_latency_i)
        3'd1:    slots_n[0].fp = slots_n[0].fp | late_fp_dest_i;
        3'd2:    slots_n[1].fp = slots_n[1].fp | late_fp_dest_i;
        3'd3:    slots_n[2].fp = slots_n[2].fp | late_fp_dest_i;
        3'd4:    slots_n[3].fp = slots_n[3].fp | late_fp_dest_i;
        3'd5:    slots_n[4].fp = slots_n[4].fp | late_fp_dest_i;
        default: ; // latency out of range, do nothing
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) begin
      grant_q <= 1'b0;
      for (int i = 0; i < DEPTH; i++) slots_q[i] <= '0;
    end else begin
      grant_q <= grant_comb;
      for (int i = 0; i < DEPTH; i++) slots_q[i] <= slots_n[i];
    end
  end

  assign grant_comb_o      = grant_comb;
  assign grant_o           = grant_q;
  assign late_grant_comb_o = late_grant_comb;

endmodule
