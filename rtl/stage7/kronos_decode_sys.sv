// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode_sys.sv — SYSTEM sub-decoder.
// Owns funct3=0 priv/sfence cluster and CSR* variants.

module kronos_decode_sys
  import kronos_pkg::*;
(
  input  logic [kronos_pkg::INST_W-1:0] instr_i,
  output decoded_instr_t                decoded_o,
  output logic                          illegal_o
);

  logic [6:0] opcode;
  logic [4:0] rd;
  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [2:0] funct3;
  logic       illegal;

  assign opcode = instr_i[6:0];
  assign rd     = instr_i[11:7];
  assign rs1    = instr_i[19:15];
  assign rs2    = instr_i[24:20];
  assign funct3 = instr_i[14:12];

  always_comb begin
    decoded_o     = kronos_pkg::DECODED_INSTR_ZERO;
    decoded_o.rs1 = rs1;
    decoded_o.rs2 = rs2;
    decoded_o.rd  = rd;
    illegal       = 1'b0;

    unique case (opcode)
      SYSTEM: begin
        unique case (funct3)
          3'b000: begin
            // SFENCE.VMA (funct7 = 0x09)
            if (instr_i[31:25] == 7'b000_1001) begin
              decoded_o.is_sfence_vma = 1'b1;
              illegal                 = 1'b0;
            end else begin
              unique case (instr_i[31:20])
                12'h000: decoded_o.is_ecall  = 1'b1;
                12'h001: decoded_o.is_ebreak = 1'b1;
                12'h302: decoded_o.is_mret   = 1'b1;
                12'h102: decoded_o.is_sret   = 1'b1;
                12'h105: decoded_o.is_wfi    = 1'b1;
                default: illegal             = 1'b1;
              endcase
            end
          end
          default: begin
            // CSRRW/RS/RC and immediate variants
            decoded_o.is_csr      = 1'b1;
            decoded_o.rd_wen      = 1'b1;
            decoded_o.rs1_used    = ~funct3[2];
            decoded_o.csr_addr    = instr_i[31:20];
            decoded_o.csr_funct3  = funct3;
            decoded_o.csr_use_imm = funct3[2];
            decoded_o.wb_sel      = WB_CSR;
          end
        endcase
      end

      default: begin
        decoded_o = kronos_pkg::DECODED_INSTR_ZERO;
        illegal   = 1'b0;
      end
    endcase

    illegal_o = illegal;
  end

endmodule
