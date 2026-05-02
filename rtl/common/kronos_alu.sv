// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_alu.sv — BOOM/Rocket-style structural ALU.
// One adder (ADD/SUB/SLT/SLTU), one comparator derived from the adder's sign
// bit, one right-only barrel shifter (SLL via input/output bit-reverse), one
// logic block, and a 4:1 op-class final mux. Word-op handled by input
// pre-mask + output sign-extension on a single 64-bit datapath.
module kronos_alu
  import kronos_pkg::*;
(
  input  alu_op_e                       op_i,
  input  logic [kronos_pkg::XLEN-1:0]   a_i,
  input  logic [kronos_pkg::XLEN-1:0]   b_i,
  input  logic                          word_op_i,
  output logic [kronos_pkg::XLEN-1:0]   result_o,
  output logic [kronos_pkg::XLEN-1:0]   adder_out_o,
  output logic                          cmp_lt_o,
  output logic                          eq_o
);

  // ---- Combinational signals ------------------------------------------------

  // Word-op pre-shaping
  logic [kronos_pkg::XLEN-1:0]   a_pre;
  logic [kronos_pkg::XLEN-1:0]   b_pre;
  logic [5:0]                    shamt;

  // Adder
  logic                          is_sub;
  logic [kronos_pkg::XLEN-1:0]   b_inv;
  logic [kronos_pkg::XLEN:0]     adder_full;
  logic [kronos_pkg::XLEN-1:0]   adder_out;

  // Comparator
  logic                          cmp_signed;
  logic                          cmp_lt;
  logic                          cmp_eq;

  // Shifter
  logic [kronos_pkg::XLEN-1:0]   shin;
  logic                          shamt_msb;
  logic [kronos_pkg::XLEN:0]     shin_ext;
  logic [kronos_pkg::XLEN:0]     shout_ext;
  logic [kronos_pkg::XLEN-1:0]   shout_r;
  logic [kronos_pkg::XLEN-1:0]   shift_out;

  // Logic
  logic [kronos_pkg::XLEN-1:0]   logic_out;

  // Result mux
  logic [kronos_pkg::XLEN-1:0]   result_pre;

  // Adder carry-out and shifter sign-fill bit are intentionally dropped at the
  // module boundary (consumed by an OR-reduction sink at the bottom).
  logic                          _unused;

  // ---- Word-op pre-mask -----------------------------------------------------
  // For word ops, run the 64-bit datapath on operands shaped to look like a
  // word. SRAW needs sign-extended low 32 so the shifter sees the right MSB;
  // other ops zero-extend (the post-extend stage takes care of the final
  // sign-extension regardless).
  always_comb begin
    a_pre = a_i;
    b_pre = b_i;
    shamt = b_i[5:0];
    if (word_op_i) begin
      a_pre = (op_i == ALU_SRA)
            ? {{(kronos_pkg::XLEN-kronos_pkg::INST_W){a_i[kronos_pkg::INST_W-1]}},
               a_i[kronos_pkg::INST_W-1:0]}
            : {{(kronos_pkg::XLEN-kronos_pkg::INST_W){1'b0}},
               a_i[kronos_pkg::INST_W-1:0]};
      b_pre = {{(kronos_pkg::XLEN-kronos_pkg::INST_W){1'b0}},
               b_i[kronos_pkg::INST_W-1:0]};
      shamt = {1'b0, b_i[4:0]};
    end
  end

  // ---- Adder ----------------------------------------------------------------
  // SUB is a + ~b + 1. SLT/SLTU drive the same adder so the comparator can
  // derive its result from the sign bit. Synth produces one carry chain.
  assign is_sub     = (op_i == ALU_SUB) | is_alu_slt(op_i);
  assign b_inv      = b_pre ^ {kronos_pkg::XLEN{is_sub}};
  assign adder_full = {1'b0, a_pre} + {1'b0, b_inv}
                                    + {{kronos_pkg::XLEN{1'b0}}, is_sub};
  assign adder_out  = adder_full[kronos_pkg::XLEN-1:0];

  // ---- Comparator (derived from adder) --------------------------------------
  // When operand sign bits agree, sign-of-(a-b) is the answer. When they
  // disagree, signed result depends on a's sign and unsigned result depends
  // on b's sign — pick by cmp_signed. Three small gate stages on top of the
  // adder, no second subtractor.
  assign cmp_signed = (op_i == ALU_SLT);
  assign cmp_lt = (a_pre[kronos_pkg::XLEN-1] ^ b_pre[kronos_pkg::XLEN-1])
                ? (cmp_signed ? a_pre[kronos_pkg::XLEN-1]
                              : b_pre[kronos_pkg::XLEN-1])
                : adder_out[kronos_pkg::XLEN-1];
  assign cmp_eq = (adder_out == {kronos_pkg::XLEN{1'b0}});

  // ---- Shifter --------------------------------------------------------------
  // One right-only barrel shifter; SLL is "reverse → right-shift → reverse".
  // Sign-fill bit for SRA muxed in via shamt_msb. shin_ext is XLEN+1 bits so
  // the SRA sign-fill bit can be folded into the shifted value via $signed();
  // the shifted result is sliced back to XLEN bits.
  assign shin      = (op_i == ALU_SLL) ? {<<{a_pre}} : a_pre;
  assign shamt_msb = (op_i == ALU_SRA) ? a_pre[kronos_pkg::XLEN-1] : 1'b0;
  assign shin_ext  = {shamt_msb, shin};
  assign shout_ext = $signed(shin_ext) >>> shamt[$clog2(kronos_pkg::XLEN)-1:0];
  assign shout_r   = shout_ext[kronos_pkg::XLEN-1:0];
  assign shift_out = (op_i == ALU_SLL) ? {<<{shout_r}} : shout_r;

  // ---- Logic ----------------------------------------------------------------
  always_comb begin
    logic_out = {kronos_pkg::XLEN{1'b0}};
    unique case (op_i)
      ALU_AND:   logic_out = a_pre & b_pre;
      ALU_OR:    logic_out = a_pre | b_pre;
      ALU_XOR:   logic_out = a_pre ^ b_pre;
      ALU_PASSB: logic_out = b_pre;
      default:   logic_out = {kronos_pkg::XLEN{1'b0}};
    endcase
  end

  // ---- Op-class final mux + post-extend -------------------------------------
  // Invalid ops (anything outside the alu_op_e enum) fall through to 0.
  always_comb begin
    result_pre = {kronos_pkg::XLEN{1'b0}};
    unique case (1'b1)
      is_alu_shift(op_i):                   result_pre = shift_out;
      is_alu_slt  (op_i):                   result_pre = {{(kronos_pkg::XLEN-1){1'b0}}, cmp_lt};
      is_alu_logic(op_i):                   result_pre = logic_out;
      (op_i == ALU_ADD) | (op_i == ALU_SUB): result_pre = adder_out;
      default:                              result_pre = {kronos_pkg::XLEN{1'b0}};
    endcase
  end

  assign result_o    = word_op_i
                     ? {{(kronos_pkg::XLEN-kronos_pkg::INST_W){result_pre[kronos_pkg::INST_W-1]}},
                        result_pre[kronos_pkg::INST_W-1:0]}
                     : result_pre;
  assign adder_out_o = adder_out;
  assign cmp_lt_o    = cmp_lt;
  assign eq_o        = cmp_eq;

  assign _unused = ^{adder_full[kronos_pkg::XLEN], shout_ext[kronos_pkg::XLEN]};

endmodule
