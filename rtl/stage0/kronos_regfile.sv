// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_regfile.sv — 32×64-bit integer register file
// x0 is hardwired to 0. Reads are asynchronous. Write on rising clock edge.
module kronos_regfile (
  input  logic        clk_i,
  input  logic [4:0]  rs1_addr_i,
  input  logic [4:0]  rs2_addr_i,
  output logic [63:0] rs1_rdata_o,
  output logic [63:0] rs2_rdata_o,
  input  logic [4:0]  rd_addr_i,
  input  logic        rd_wen_i,
  input  logic [63:0] rd_wdata_i
);

  // -------------------------------------------------------------------------
  // State registers (driven by always_ff)
  // -------------------------------------------------------------------------
  logic [63:0] regs_q [32];

  always_ff @(posedge clk_i) begin
    if (rd_wen_i && rd_addr_i != 5'd0) begin
      regs_q[rd_addr_i] <= rd_wdata_i;
    end
  end

  assign rs1_rdata_o = (rs1_addr_i == 5'd0) ? 64'd0 : regs_q[rs1_addr_i];
  assign rs2_rdata_o = (rs2_addr_i == 5'd0) ? 64'd0 : regs_q[rs2_addr_i];

endmodule
