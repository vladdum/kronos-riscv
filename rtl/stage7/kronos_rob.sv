// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stage 7a: 16-entry circular reorder buffer.
// Single dispatch port, two completion ports (port A: in-pipe, port B: async),
// single commit port. Branch flush invalidates entries strictly newer than a
// given index; trap flush invalidates everything.

module kronos_rob
  import kronos_pkg::*;
(
  input  logic                       clk_i,
  input  logic                       rst_ni,

  // ---- Status -------------------------------------------------------------
  output logic                       full_o,
  output logic                       empty_o,
  output rob_idx_t                   head_o,
  output rob_idx_t                   tail_o,
  output rob_entry_t [ROB_DEPTH-1:0] rob_q_o,            // for busy table rebuild + ID-stage bypass
  output logic [ROB_DEPTH-1:0]       is_at_head_o,       // one-hot

  // ---- Dispatch port (1/cycle) -------------------------------------------
  input  logic                       dispatch_i,
  input  rob_entry_t                 dispatch_entry_i,
  output rob_idx_t                   dispatch_idx_o,     // = current tail; valid combinationally

  // ---- Completion port A (in-pipe: ALU/LSU/CSR/branch) -------------------
  input  logic                       compA_i,
  input  rob_idx_t                   compA_idx_i,
  input  logic [63:0]                compA_result_i,
  input  logic [63:0]                compA_csr_new_val_i,
  input  logic                       compA_trap_taken_i,
  input  logic [4:0]                 compA_trap_cause_i,
  input  logic [63:0]                compA_tval_i,
  input  logic                       compA_actual_taken_i,
  input  logic [31:0]                compA_actual_target_i,
  input  logic                       compA_mispredict_i,
  input  logic [63:0]                compA_mem_addr_i,
  input  logic [63:0]                compA_mem_wdata_i,
  input  logic [2:0]                 compA_mem_funct3_i,

  // ---- Completion port B (async: FPU + muldiv with arbiter) --------------
  input  logic                       compB_i,
  input  rob_idx_t                   compB_idx_i,
  input  logic [63:0]                compB_result_i,
  input  logic [4:0]                 compB_fflags_i,

  // ---- Commit port (1/cycle from head) -----------------------------------
  output logic                       commit_o,
  output rob_entry_t                 commit_entry_o,
  output rob_idx_t                   commit_idx_o,
  input  logic                       commit_block_i,    // external stall (e.g., trap-CSR drain)

  // ---- Branch flush ------------------------------------------------------
  input  logic                       branch_flush_i,
  input  rob_idx_t                   branch_flush_idx_i, // entries STRICTLY newer than this are killed

  // ---- Trap flush --------------------------------------------------------
  input  logic                       trap_flush_i        // kills everything
);

  // -------------------------------------------------------------------------
  // State (unpacked array — synthesises to individual flip-flops per field)
  // -------------------------------------------------------------------------
  rob_entry_t                  rob_q [ROB_DEPTH];
  rob_idx_t                    head_q, tail_q;
  logic [ROB_COUNT_W-1:0]      count_q;

  // -------------------------------------------------------------------------
  // Combinational outputs
  // -------------------------------------------------------------------------
  assign full_o     = (count_q == ROB_COUNT_W'(ROB_DEPTH));
  assign empty_o    = (count_q == '0);
  assign head_o     = head_q;
  assign tail_o     = tail_q;

  // Copy unpacked internal array to packed output port.
  always_comb begin
    for (int i = 0; i < ROB_DEPTH; i++) rob_q_o[i] = rob_q[i];
  end

  always_comb begin
    is_at_head_o = '0;
    if (!empty_o) is_at_head_o[head_q] = 1'b1;
  end

  assign dispatch_idx_o   = tail_q;

  assign commit_o         = !empty_o
                          && rob_q[head_q].valid
                          && rob_q[head_q].complete
                          && !commit_block_i;

  assign commit_entry_o   = rob_q[head_q];
  assign commit_idx_o     = head_q;

  // -------------------------------------------------------------------------
  // Sequential update
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < ROB_DEPTH; i++) rob_q[i] <= '0;
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end
    else if (trap_flush_i) begin
      // Trap flush: kill everything.
      for (int i = 0; i < ROB_DEPTH; i++) rob_q[i].valid <= 1'b0;
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end
    else if (branch_flush_i) begin
      // Branch flush: invalidate entries strictly newer than branch_flush_idx.
      // Walk from branch_flush_idx+1 ... up to current tail (mod ROB_DEPTH).
      for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
        static rob_idx_t cur;
        cur = rob_idx_t'(branch_flush_idx_i + rob_idx_t'(i) + 1'b1);
        if (cur == tail_q) break;
        rob_q[cur].valid <= 1'b0;
      end
      tail_q  <= rob_idx_t'(branch_flush_idx_i + 1'b1);
      // Recompute count: entries surviving = (branch_flush_idx - head + 1) mod DEPTH.
      count_q <= ROB_COUNT_W'(rob_idx_t'(branch_flush_idx_i - head_q) + 1'b1);
    end
    else begin
      // Normal cycle: dispatch / commit / port A / port B / count update.

      // Dispatch (write tail).
      if (dispatch_i) begin
        rob_q[tail_q] <= dispatch_entry_i;
        tail_q        <= tail_q + 1'b1;
      end

      // Commit (advance head).
      if (commit_o) begin
        rob_q[head_q].valid <= 1'b0;
        head_q              <= head_q + 1'b1;
      end

      // Port A — in-pipe completion. ALU/LSU/CSR/branch results land here.
      // Gate by current valid (a flush in the same cycle clears valid; we
      // must not reanimate a killed entry).
      if (compA_i && rob_q[compA_idx_i].valid) begin
        rob_q[compA_idx_i].complete         <= 1'b1;
        rob_q[compA_idx_i].result           <= compA_result_i;
        rob_q[compA_idx_i].csr_new_val      <= compA_csr_new_val_i;
        rob_q[compA_idx_i].trap_taken       <= compA_trap_taken_i;
        rob_q[compA_idx_i].trap_cause       <= compA_trap_cause_i;
        rob_q[compA_idx_i].tval             <= compA_tval_i;
        rob_q[compA_idx_i].actual_taken     <= compA_actual_taken_i;
        rob_q[compA_idx_i].actual_target    <= compA_actual_target_i;
        rob_q[compA_idx_i].mispredict       <= compA_mispredict_i;
        rob_q[compA_idx_i].mem_addr         <= compA_mem_addr_i;
        rob_q[compA_idx_i].mem_wdata        <= compA_mem_wdata_i;
        rob_q[compA_idx_i].mem_funct3       <= compA_mem_funct3_i;
      end

      // Port B — async completion (FPU + muldiv with arbitration upstream).
      // The arbiter outside chooses one source per cycle; this port just writes
      // the chosen result. Same valid-gating as port A.
      if (compB_i && rob_q[compB_idx_i].valid) begin
        rob_q[compB_idx_i].complete <= 1'b1;
        rob_q[compB_idx_i].result   <= compB_result_i;
        rob_q[compB_idx_i].fflags   <= compB_fflags_i;
      end

      // Count update — net change of dispatch and commit.
      count_q <= count_q + ROB_COUNT_W'(dispatch_i)
                         - ROB_COUNT_W'(commit_o);
    end
  end

endmodule
