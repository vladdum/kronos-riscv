// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_forward.sv — pre-registered data-hazard forward select
// Computes fwd_rs1_sel and fwd_rs2_sel for the instruction currently
// entering ID/EX (consumer) based on the instructions in EX (will be in
// MEM next cycle) and MEM (will be in WB next cycle).
// The outputs are stored in id_ex_reg_t and used in the EX bypass mux,
// removing any combinational comparison from the EX critical path.
// EX path has priority over MEM path. A load in EX suppresses EX forward.
// x0 is never forwarded.
module kronos_forward
  import kronos_pkg::*;
(
  // Consumer: instruction being captured into ID/EX (currently in ID stage)
  input  logic [4:0] if_id_rs1_i,
  input  logic       if_id_rs1_used_i,
  input  logic [4:0] if_id_rs2_i,
  input  logic       if_id_rs2_used_i,
  // Producer in EX (will be in MEM next cycle — EX/MEM forward)
  input  logic [4:0] id_ex_rd_i,
  input  logic       id_ex_rd_wen_i,
  input  logic       id_ex_is_load_i,   // suppresses EX forward (data not ready)
  // Producer in MEM (will be in WB next cycle — MEM/WB forward)
  input  logic [4:0] ex_mem_rd_i,
  input  logic       ex_mem_rd_wen_i,
  // Outputs: stored into id_ex_q.fwd_rs1_sel / id_ex_q.fwd_rs2_sel
  output fwd_sel_e   fwd_rs1_sel_o,
  output fwd_sel_e   fwd_rs2_sel_o
);

  logic ex_can_fwd;
  assign ex_can_fwd = id_ex_rd_wen_i && !id_ex_is_load_i && (id_ex_rd_i != 5'd0);

  logic mem_can_fwd;
  assign mem_can_fwd = ex_mem_rd_wen_i && (ex_mem_rd_i != 5'd0);

  always_comb begin
    fwd_rs1_sel_o = FWD_NONE;
    fwd_rs2_sel_o = FWD_NONE;

    // EX path has priority
    if (ex_can_fwd) begin
      if (if_id_rs1_used_i && if_id_rs1_i == id_ex_rd_i) fwd_rs1_sel_o = FWD_EXMEM;
      if (if_id_rs2_used_i && if_id_rs2_i == id_ex_rd_i) fwd_rs2_sel_o = FWD_EXMEM;
    end

    // MEM path — only if EX path did not already forward that operand
    if (mem_can_fwd) begin
      if (if_id_rs1_used_i && if_id_rs1_i == ex_mem_rd_i && fwd_rs1_sel_o == FWD_NONE)
        fwd_rs1_sel_o = FWD_MEMWB;
      if (if_id_rs2_used_i && if_id_rs2_i == ex_mem_rd_i && fwd_rs2_sel_o == FWD_NONE)
        fwd_rs2_sel_o = FWD_MEMWB;
    end
  end

endmodule
