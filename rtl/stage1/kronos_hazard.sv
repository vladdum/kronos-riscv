// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_hazard.sv — pipeline stall and flush control unit
// Priority (highest first): MEM stall > load-use > EX redirect > normal.
// Flush overrides enable: when both asserted, the register is cleared.
module kronos_hazard
  import kronos_pkg::*;
(
  // Load-use detection inputs
  input  logic       id_ex_is_load_i,
  input  logic [4:0] id_ex_rd_i,
  input  logic       id_ex_valid_i,
  // ID-stage register addresses (for load-use check)
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs2_used_i,
  input  logic [4:0] if_id_rs2_i,
  // EX redirect (branch taken, JAL/JALR, trap, MRET)
  input  logic       ex_redirect_i,
  // MEM stall (LSU waiting for OBI rvalid)
  input  logic       mem_stall_i,
  // Pipeline register enables
  output logic       pc_en_o,
  output logic       if_id_en_o,
  output logic       id_ex_en_o,
  output logic       ex_mem_en_o,
  output logic       mem_wb_en_o,
  // Pipeline register flush (clear to NOP)
  output logic       if_id_flush_o,
  output logic       id_ex_flush_o
);

  logic load_use;

  assign load_use = id_ex_valid_i && id_ex_is_load_i && (id_ex_rd_i != 5'd0) &&
                    ((if_id_rs1_used_i && if_id_rs1_i == id_ex_rd_i) ||
                     (if_id_rs2_used_i && if_id_rs2_i == id_ex_rd_i));

  always_comb begin
    // Default: full advance, no flush
    pc_en_o       = 1'b1;
    if_id_en_o    = 1'b1;
    id_ex_en_o    = 1'b1;
    ex_mem_en_o   = 1'b1;
    mem_wb_en_o   = 1'b1;
    if_id_flush_o = 1'b0;
    id_ex_flush_o = 1'b0;

    if (mem_stall_i) begin
      // Priority 1: OBI stall — hold all stages
      pc_en_o     = 1'b0;
      if_id_en_o  = 1'b0;
      id_ex_en_o  = 1'b0;
      ex_mem_en_o = 1'b0;
      mem_wb_en_o = 1'b0;
    end else if (load_use) begin
      // Priority 2: load-use — stall PC+IF+ID, bubble into EX
      pc_en_o       = 1'b0;
      if_id_en_o    = 1'b0;
      id_ex_en_o    = 1'b0;
      id_ex_flush_o = 1'b1;   // flush overrides en → bubble in ID/EX
    end else if (ex_redirect_i) begin
      // Priority 3: EX redirect — squash IF and ID
      if_id_flush_o = 1'b1;
      id_ex_flush_o = 1'b1;
    end
  end

endmodule
