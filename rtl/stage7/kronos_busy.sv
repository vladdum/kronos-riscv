// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stage 7a: per-arch-reg busy table.
// 32 int + 32 fp entries. Each entry holds {busy, prod_idx} where prod_idx
// is the youngest in-flight ROB index that writes that arch reg.
//
// Reads (combinational): one per source register lookup at ID/DISP.
// Writes (clocked):
//   - dispatch: set busy[rd] = {1, tail_q}
//   - commit:   conditionally clear (only if prod_idx matches committing idx)
//   - flush:    combinational rebuild from surviving ROB entries

module kronos_busy
  import kronos_pkg::*;
(
  input  logic                       clk_i,
  input  logic                       rst_ni,

  // ---- Lookup ports (combinational) --------------------------------------
  // ID/DISP reads two int sources and (optionally) two fp sources per cycle.
  input  logic [4:0]                 rs1_int_addr_i,
  input  logic [4:0]                 rs2_int_addr_i,
  input  logic [4:0]                 rs1_fp_addr_i,
  input  logic [4:0]                 rs2_fp_addr_i,
  output busy_entry_t                rs1_int_o,
  output busy_entry_t                rs2_int_o,
  output busy_entry_t                rs1_fp_o,
  output busy_entry_t                rs2_fp_o,

  // ---- Dispatch port (clocked) -------------------------------------------
  input  logic                       dispatch_i,
  input  logic                       dispatch_rd_fp_i,
  input  logic [4:0]                 dispatch_rd_addr_i,
  input  rob_idx_t                   dispatch_rob_idx_i,

  // ---- Commit port (clocked) ---------------------------------------------
  input  logic                       commit_i,
  input  logic                       commit_rd_fp_i,
  input  logic [4:0]                 commit_rd_addr_i,
  input  rob_idx_t                   commit_rob_idx_i,

  // ---- Flush port (clocked, combinational rebuild) -----------------------
  input  logic                       flush_i,
  input  rob_entry_t [ROB_DEPTH-1:0] rob_q_i,         // for rebuild scan
  input  rob_idx_t                   flush_new_head_i,
  input  rob_idx_t                   flush_new_tail_i  // exclusive (one past last surviving)
);

  busy_entry_t int_busy_q [32];
  busy_entry_t fp_busy_q  [32];

  // ---- Lookup -------------------------------------------------------------
  assign rs1_int_o = (rs1_int_addr_i == 5'd0) ? '0 : int_busy_q[rs1_int_addr_i];
  assign rs2_int_o = (rs2_int_addr_i == 5'd0) ? '0 : int_busy_q[rs2_int_addr_i];
  assign rs1_fp_o  = fp_busy_q[rs1_fp_addr_i];
  assign rs2_fp_o  = fp_busy_q[rs2_fp_addr_i];

  // ---- Combinational rebuild — only valid the cycle flush_i=1 -------------
  busy_entry_t int_rebuild [32];
  busy_entry_t fp_rebuild  [32];

  always_comb begin
    rob_idx_t   cur_idx;
    rob_entry_t e;
    cur_idx     = '0;
    e           = '0;
    int_rebuild = '{default: '0};
    fp_rebuild  = '{default: '0};
    if (flush_i) begin
      // Walk ROB entries from head (inclusive) to flush_new_tail (exclusive),
      // wrapping mod ROB_DEPTH. Last write per arch reg wins.
      for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
        cur_idx = rob_idx_t'(flush_new_head_i + rob_idx_t'(i));
        e       = rob_q_i[cur_idx];
        // Stop once we reach flush_new_tail (or run out of valid entries).
        if (cur_idx == flush_new_tail_i) break;
        if (!e.valid) continue;
        if (e.dec.rd_wen && e.dec.rd != 5'd0) begin
          if (!e.dec.rd_fp) int_rebuild[e.dec.rd] = '{busy: 1'b1, prod_idx: cur_idx};
          else              fp_rebuild [e.dec.rd] = '{busy: 1'b1, prod_idx: cur_idx};
        end
      end
    end
  end

  // ---- Sequential update --------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      int_busy_q <= '{default: '0};
      fp_busy_q  <= '{default: '0};
    end
    else if (flush_i) begin
      int_busy_q <= int_rebuild;
      fp_busy_q  <= fp_rebuild;
    end
    else begin
      // Commit first (so dispatch's NBA wins on same-cycle WAW collisions).
      if (commit_i) begin
        if (!commit_rd_fp_i && commit_rd_addr_i != 5'd0) begin
          if (int_busy_q[commit_rd_addr_i].prod_idx == commit_rob_idx_i) begin
            int_busy_q[commit_rd_addr_i] <= '0;
          end
        end
        else if (commit_rd_fp_i) begin
          if (fp_busy_q[commit_rd_addr_i].prod_idx == commit_rob_idx_i) begin
            fp_busy_q[commit_rd_addr_i]  <= '0;
          end
        end
      end
      if (dispatch_i) begin
        if (!dispatch_rd_fp_i && dispatch_rd_addr_i != 5'd0) begin
          int_busy_q[dispatch_rd_addr_i] <= '{busy: 1'b1, prod_idx: dispatch_rob_idx_i};
        end
        else if (dispatch_rd_fp_i) begin
          fp_busy_q[dispatch_rd_addr_i]  <= '{busy: 1'b1, prod_idx: dispatch_rob_idx_i};
        end
      end
    end
  end

endmodule
