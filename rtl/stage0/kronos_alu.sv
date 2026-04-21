// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module kronos_alu
  import kronos_pkg::*;
(
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  alu_op_e     op_i,
  output logic [31:0] result_o
);

  always_comb begin
    result_o = {32{1'b0}};
    unique case (op_i)
      ALU_ADD:   result_o = a_i + b_i;
      ALU_SUB:   result_o = a_i - b_i;
      ALU_SLL:   result_o = a_i << b_i[4:0];
      ALU_SLT:   result_o = {31'b0, $signed(a_i) < $signed(b_i)};
      ALU_SLTU:  result_o = {31'b0, a_i < b_i};
      ALU_XOR:   result_o = a_i ^ b_i;
      ALU_SRL:   result_o = a_i >> b_i[4:0];
      ALU_SRA:   result_o = 32'($signed(a_i) >>> b_i[4:0]);
      ALU_OR:    result_o = a_i | b_i;
      ALU_AND:   result_o = a_i & b_i;
      ALU_PASSB: result_o = b_i;
      default:   result_o = {32{1'b0}};
    endcase
  end

endmodule
