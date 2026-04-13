// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_forward.sv — data hazard forwarding mux select logic
// Computes fwd_rs1_sel and fwd_rs2_sel for the EX stage.
// EX/MEM takes priority over MEM/WB. Load-in-MEM suppresses EX/MEM forward.
// x0 is never forwarded.
module kronos_forward
  import kronos_pkg::*;
(
  // Consumer: instruction currently in EX (from ID/EX register)
  input  logic [4:0] id_ex_rs1_i,
  input  logic       id_ex_rs1_used_i,
  input  logic [4:0] id_ex_rs2_i,
  input  logic       id_ex_rs2_used_i,
  // Producer in MEM (from EX/MEM register)
  input  logic [4:0] ex_mem_rd_i,
  input  logic       ex_mem_rd_wen_i,
  input  logic       ex_mem_is_load_i,   // result not yet available — stall instead
  // Producer in WB (from MEM/WB register)
  input  logic [4:0] mem_wb_rd_i,
  input  logic       mem_wb_rd_wen_i,
  // Outputs
  output fwd_sel_e   fwd_rs1_sel_o,
  output fwd_sel_e   fwd_rs2_sel_o
);

  logic ex_mem_can_fwd;
  assign ex_mem_can_fwd = ex_mem_rd_wen_i && !ex_mem_is_load_i && (ex_mem_rd_i != 5'd0);

  logic mem_wb_can_fwd;
  assign mem_wb_can_fwd = mem_wb_rd_wen_i && (mem_wb_rd_i != 5'd0);

  always_comb begin
    fwd_rs1_sel_o = FWD_NONE;
    fwd_rs2_sel_o = FWD_NONE;

    // EX/MEM has priority
    if (ex_mem_can_fwd) begin
      if (id_ex_rs1_used_i && id_ex_rs1_i == ex_mem_rd_i) fwd_rs1_sel_o = FWD_EXMEM;
      if (id_ex_rs2_used_i && id_ex_rs2_i == ex_mem_rd_i) fwd_rs2_sel_o = FWD_EXMEM;
    end

    // MEM/WB — only if EX/MEM did not already forward for that operand
    if (mem_wb_can_fwd) begin
      if (id_ex_rs1_used_i && id_ex_rs1_i == mem_wb_rd_i && fwd_rs1_sel_o == FWD_NONE)
        fwd_rs1_sel_o = FWD_MEMWB;
      if (id_ex_rs2_used_i && id_ex_rs2_i == mem_wb_rd_i && fwd_rs2_sel_o == FWD_NONE)
        fwd_rs2_sel_o = FWD_MEMWB;
    end
  end

endmodule
