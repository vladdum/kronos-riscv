// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_alu.sv (stage4) — 64-bit ALU with W-suffix support.
// When word_op_i=1, operates on lower 32 bits and sign-extends result to 64.
module kronos_alu
  import kronos_pkg::*;
(
  input  alu_op_e     op_i,
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic        word_op_i,
  output logic [63:0] result_o
);

  logic [63:0] result_64;
  logic [31:0] result_32;

  always_comb begin
    result_64 = {64{1'b0}};
    result_32 = {32{1'b0}};

    unique case (op_i)
      ALU_ADD: begin
        result_64 = a_i + b_i;
        result_32 = a_i[31:0] + b_i[31:0];
      end
      ALU_SUB: begin
        result_64 = a_i - b_i;
        result_32 = a_i[31:0] - b_i[31:0];
      end
      ALU_SLL: begin
        result_64 = a_i << b_i[5:0];
        result_32 = a_i[31:0] << b_i[4:0];
      end
      ALU_SLT: begin
        result_64 = {63'b0, $signed(a_i) < $signed(b_i)};
        result_32 = result_64[31:0];
      end
      ALU_SLTU: begin
        result_64 = {63'b0, a_i < b_i};
        result_32 = result_64[31:0];
      end
      ALU_XOR: begin
        result_64 = a_i ^ b_i;
        result_32 = a_i[31:0] ^ b_i[31:0];
      end
      ALU_SRL: begin
        result_64 = a_i >> b_i[5:0];
        result_32 = a_i[31:0] >> b_i[4:0];
      end
      ALU_SRA: begin
        result_64 = 64'($signed(a_i) >>> b_i[5:0]);
        result_32 = 32'($signed(a_i[31:0]) >>> b_i[4:0]);
      end
      ALU_OR: begin
        result_64 = a_i | b_i;
        result_32 = a_i[31:0] | b_i[31:0];
      end
      ALU_AND: begin
        result_64 = a_i & b_i;
        result_32 = a_i[31:0] & b_i[31:0];
      end
      ALU_PASSB: begin
        result_64 = b_i;
        result_32 = b_i[31:0];
      end
      default: begin
        result_64 = {64{1'b0}};
        result_32 = {32{1'b0}};
      end
    endcase

    result_o = word_op_i ? {{32{result_32[31]}}, result_32} : result_64;
  end

endmodule
