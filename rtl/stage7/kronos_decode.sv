// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_decode.sv (stage6) — RV64IMAFDC instruction-decode dispatch wrapper.
// Instantiates five per-class sub-decoders and dispatches by opcode[6:0].
// Each sub-decoder owns its class's funct3/funct7-level decoding + per-class
// illegal-encoding checks. The wrapper owns the "no class matched" illegal.

module kronos_decode
  import kronos_pkg::*;
(
  input  logic [kronos_pkg::INST_W-1:0] instr_i,
  input  logic [2:0]                    frm_i,
  output decoded_instr_t                decoded_o,
  output logic                          illegal_insn_o
);

  logic [6:0]      opcode;
  decoded_instr_t  int_decoded;
  decoded_instr_t  ctrl_decoded;
  decoded_instr_t  mem_decoded;
  decoded_instr_t  sys_decoded;
  decoded_instr_t  fp_decoded;
  logic            int_illegal;
  logic            ctrl_illegal;
  logic            mem_illegal;
  logic            sys_illegal;
  logic            fp_illegal;

  assign opcode = instr_i[6:0];

  kronos_decode_int  u_int  (
    .instr_i   (instr_i),
    .decoded_o (int_decoded),
    .illegal_o (int_illegal)
  );

  kronos_decode_ctrl u_ctrl (
    .instr_i   (instr_i),
    .decoded_o (ctrl_decoded),
    .illegal_o (ctrl_illegal)
  );

  kronos_decode_mem  u_mem  (
    .instr_i   (instr_i),
    .decoded_o (mem_decoded),
    .illegal_o (mem_illegal)
  );

  kronos_decode_sys  u_sys  (
    .instr_i   (instr_i),
    .decoded_o (sys_decoded),
    .illegal_o (sys_illegal)
  );

  kronos_decode_fp   u_fp   (
    .instr_i   (instr_i),
    .frm_i     (frm_i),
    .decoded_o (fp_decoded),
    .illegal_o (fp_illegal)
  );

  always_comb begin
    decoded_o              = kronos_pkg::DECODED_INSTR_ZERO;
    decoded_o.rs1          = instr_i[19:15];
    decoded_o.rs2          = instr_i[24:20];
    decoded_o.rd           = instr_i[11:7];
    illegal_insn_o         = 1'b1;

    unique case (opcode)
      OP, OP_IMM, OP_IMM_32, OP_32, LUI, AUIPC: begin
        decoded_o      = int_decoded;
        illegal_insn_o = int_illegal;
      end
      JAL, JALR, BRANCH: begin
        decoded_o      = ctrl_decoded;
        illegal_insn_o = ctrl_illegal;
      end
      LOAD, STORE, LOAD_FP, STORE_FP, AMO: begin
        decoded_o      = mem_decoded;
        illegal_insn_o = mem_illegal;
      end
      SYSTEM: begin
        decoded_o      = sys_decoded;
        illegal_insn_o = sys_illegal;
      end
      OP_FP, FMADD_OP, FMSUB_OP, FNMSUB_OP, FNMADD_OP: begin
        decoded_o      = fp_decoded;
        illegal_insn_o = fp_illegal;
      end
      default: illegal_insn_o = 1'b1;
    endcase

    decoded_o.illegal = illegal_insn_o;
  end

endmodule
