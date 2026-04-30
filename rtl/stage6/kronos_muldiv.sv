// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_muldiv.sv — multi-cycle 64-bit multiply/divide unit (RV64M).
//
// MUL/MULH/MULHSU/MULHU: 5-cycle latency (MUL_IN, MUL_MID, MUL_OUT, DONE).
//   IDLE: latch sign-extended 65-bit operands into mul_a65_q / mul_b65_q.
//   MUL_IN: split mul_b65_q into a 33-bit signed high half [64:32] and a
//           32-bit unsigned low half [31:0], compute two 65×33 partial
//           products pp_hi_q / pp_lo_q.  Each fits in a short DSP48E2
//           cascade rather than the 3-DSP cascade a single 65×65 requires.
//   MUL_MID: sum pp_hi_q << 32 + pp_lo_q into mul_product_q.
//   MUL_OUT: select high/low half, apply word_op sign extension → result_q.
//   DONE: expose result.
//
// DIV/DIVU/REM/REMU: IDLE -> COMPUTE x N -> DONE, where
//   N = 64 for full 64-bit ops and N = 32 when word_op_i is asserted.
//   Uses an iterative restoring algorithm. Edge cases (divide-by-zero,
//   INT_MIN / -1) are detected in the IDLE->COMPUTE transition and jump
//   straight to DONE.
//
// word_op_i widens/narrows the datapath:
//   * Multiplier: for word_op, only the low 32 bits of each operand are
//     used. They are sign- or zero-extended into the 65-bit operand based
//     on the multiply variant (MULHU is unsigned, others signed).
//   * Divider: the absolute 32-bit dividend is left-aligned into the
//     upper half of the 64-bit dividend register and the FSM runs for
//     only 32 iterations so the quotient lands in the low 32 bits.
//   * Final result has its low 32 bits sign-extended to 64.
//
// Interface:
//   req_i   — pulse HIGH for one cycle to start an operation (only when idle_o=1)
//   busy_o  — HIGH while computing (MUL_IN, MUL_OUT, or COMPUTE state)
//   valid_o — HIGH for exactly one cycle when result_o is ready (DONE state)
//   idle_o  — HIGH when ready to accept a new operation (IDLE state)
module kronos_muldiv
  import kronos_pkg::*;
(
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            req_i,
  input  muldiv_op_e      op_i,
  input  logic [XLEN-1:0] a_i,
  input  logic [XLEN-1:0] b_i,
  input  logic            word_op_i,
  output logic [XLEN-1:0] result_o,
  output logic            busy_o,
  output logic            valid_o,
  output logic            idle_o
);

  // -------------------------------------------------------------------------
  // 1. Constants
  // -------------------------------------------------------------------------
  localparam logic [XLEN-1:0] ALL_ONES_64 = 64'hFFFF_FFFF_FFFF_FFFF;
  localparam logic [XLEN-1:0] INT_MIN_64  = 64'h8000_0000_0000_0000;
  localparam logic [XLEN-1:0] INT_MIN_32  = 64'hFFFF_FFFF_8000_0000;

  // -------------------------------------------------------------------------
  // 2. Types
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE    = 3'd0,
    MUL_IN  = 3'd1,  // register sign-extended operands
    MUL_MID = 3'd2,  // register 65x33 partial products
    MUL_OUT = 3'd3,  // register 130-bit full product
    COMPUTE = 3'd4,  // iterative division step
    DONE    = 3'd5
  } muldiv_state_e;

  // -------------------------------------------------------------------------
  // 3. State registers
  // -------------------------------------------------------------------------
  muldiv_state_e         state_q;
  logic [XLEN-1:0]       result_q;
  // Multiplier pipeline registers.
  // Partial-product width: 65 (signed a) × 33 (signed b-half) = 98 bits signed.
  // The 65×65 signed multiply is decomposed into pp_hi = a × b[64:32]_signed
  // and pp_lo = a × {1'b0, b[31:0]} (the low half treated as positive), then
  // summed as (pp_hi << 32) + pp_lo in MUL_MID.
  logic [XLEN:0]         mul_a65_q;
  logic [XLEN:0]         mul_b65_q;
  logic signed [97:0]    pp_lo_q;
  logic signed [97:0]    pp_hi_q;
  logic signed [129:0]   mul_product_q;
  muldiv_op_e            op_q;
  // Divider registers (restoring division)
  logic [XLEN-1:0]       dividend_q;   // left-shifted each step; MSB feeds remainder
  logic [XLEN:0]         remainder_q;  // 65-bit partial remainder (extra bit for borrow)
  logic [XLEN-1:0]       quotient_q;
  logic [XLEN-1:0]       abs_b_q;
  logic [6:0]            count_q;      // counts down from 64 (or 32 for word_op)
  logic                  div_neg_q;    // negate quotient at end (signed DIV)
  logic                  rem_neg_q;    // negate remainder at end (signed REM)
  logic                  is_rem_q;     // 1 = REM/REMU, 0 = DIV/DIVU
  logic                  word_op_q;    // latch of word_op_i for this operation

  // -------------------------------------------------------------------------
  // 4. Combinational signals
  // -------------------------------------------------------------------------
  // Multiplier sign-extend / word-op shaping
  logic              mul_signed_a;
  logic              mul_signed_b;
  logic [INST_W-1:0] mul_a_low;
  logic [INST_W-1:0] mul_b_low;
  logic              mul_a_sign_bit;
  logic              mul_b_sign_bit;
  logic [XLEN-1:0]   mul_a_eff;
  logic [XLEN-1:0]   mul_b_eff;
  logic [XLEN:0]     mul_a65;
  logic [XLEN:0]     mul_b65;

  // MUL_OUT half-select
  logic [XLEN-1:0]   mul_sel;

  // IDLE → division setup combinational signals
  logic              is_signed_div;
  logic              a_sign_bit;
  logic              b_sign_bit;
  logic [XLEN-1:0]   a_eff;
  logic [XLEN-1:0]   b_eff;
  logic              neg_a;
  logic              neg_b;
  logic [XLEN-1:0]   abs_a;
  logic [XLEN-1:0]   abs_b;
  logic              b_is_zero;
  logic              ov_div;
  logic              ov_rem;
  logic [XLEN-1:0]   int_min;

  // Restoring-division step
  logic [XLEN:0]     rem_shifted;
  logic [XLEN:0]     rem_sub;
  logic [XLEN-1:0]   div_shifted;

  // Final-step divider result composition
  logic [XLEN-1:0]   final_quot;
  logic [XLEN-1:0]   final_rem;
  logic [XLEN-1:0]   signed_quot;
  logic [XLEN-1:0]   signed_rem;
  logic [XLEN-1:0]   pre_result;

  // -------------------------------------------------------------------------
  // Multiplier operand shaping
  // -------------------------------------------------------------------------
  // MUL, MULH, MULHSU treat A as signed; MULHU is unsigned.
  assign mul_signed_a = (op_i == MULDIV_MUL) | (op_i == MULDIV_MULH) | (op_i == MULDIV_MULHSU);
  // MUL, MULH treat B as signed; MULHSU and MULHU are unsigned in B.
  assign mul_signed_b = (op_i == MULDIV_MUL) | (op_i == MULDIV_MULH);

  // For word_op, the effective operands are the low 32 bits, extended to 64.
  assign mul_a_low = a_i[INST_W-1:0];
  assign mul_b_low = b_i[INST_W-1:0];
  assign mul_a_sign_bit = mul_signed_a ? mul_a_low[INST_W-1] : 1'b0;
  assign mul_b_sign_bit = mul_signed_b ? mul_b_low[INST_W-1] : 1'b0;

  assign mul_a_eff = word_op_i ? {{INST_W{mul_a_sign_bit}}, mul_a_low} : a_i;
  assign mul_b_eff = word_op_i ? {{INST_W{mul_b_sign_bit}}, mul_b_low} : b_i;

  // Extend to 65 bits for signed/unsigned product.
  assign mul_a65 = mul_signed_a ? {mul_a_eff[XLEN-1], mul_a_eff} : {1'b0, mul_a_eff};
  assign mul_b65 = mul_signed_b ? {mul_b_eff[XLEN-1], mul_b_eff} : {1'b0, mul_b_eff};

  // -------------------------------------------------------------------------
  // MUL_OUT half-select
  // -------------------------------------------------------------------------
  always_comb begin
    mul_sel = mul_product_q[XLEN-1:0];
    unique case (op_q)
      MULDIV_MUL:    mul_sel = mul_product_q[XLEN-1:0];
      MULDIV_MULH:   mul_sel = mul_product_q[2*XLEN-1:XLEN];
      MULDIV_MULHSU: mul_sel = mul_product_q[2*XLEN-1:XLEN];
      MULDIV_MULHU:  mul_sel = mul_product_q[2*XLEN-1:XLEN];
      // verilator coverage_off
      default:       mul_sel = mul_product_q[XLEN-1:0];
      // verilator coverage_on
    endcase
  end

  // -------------------------------------------------------------------------
  // Divider setup (combinational, used in IDLE on req_i)
  // -------------------------------------------------------------------------
  assign is_signed_div = (op_i == MULDIV_DIV) | (op_i == MULDIV_REM);

  // Effective operands: low 32 bits sign-extended when word_op.
  assign a_sign_bit = is_signed_div ? a_i[INST_W-1] : 1'b0;
  assign b_sign_bit = is_signed_div ? b_i[INST_W-1] : 1'b0;
  assign a_eff      = word_op_i ? {{INST_W{a_sign_bit}}, a_i[INST_W-1:0]} : a_i;
  assign b_eff      = word_op_i ? {{INST_W{b_sign_bit}}, b_i[INST_W-1:0]} : b_i;

  assign neg_a = is_signed_div & a_eff[XLEN-1];
  assign neg_b = is_signed_div & b_eff[XLEN-1];
  assign abs_a = neg_a ? (~a_eff + XLEN'(1)) : a_eff;
  assign abs_b = neg_b ? (~b_eff + XLEN'(1)) : b_eff;

  assign b_is_zero = (b_eff == XLEN'(0));

  assign int_min = word_op_i ? INT_MIN_32 : INT_MIN_64;
  assign ov_div  = (op_i == MULDIV_DIV) & (a_eff == int_min) & (b_eff == ALL_ONES_64);
  assign ov_rem  = (op_i == MULDIV_REM) & (a_eff == int_min) & (b_eff == ALL_ONES_64);

  // -------------------------------------------------------------------------
  // Restoring-division step
  // -------------------------------------------------------------------------
  assign rem_shifted = {remainder_q[XLEN-1:0], dividend_q[XLEN-1]};
  assign rem_sub     = rem_shifted - {1'b0, abs_b_q};
  assign div_shifted = {dividend_q[XLEN-2:0], 1'b0};

  // -------------------------------------------------------------------------
  // Final-step divider result composition (used in COMPUTE last cycle)
  // -------------------------------------------------------------------------
  always_comb begin
    final_quot  = {quotient_q[XLEN-2:0], 1'b0};
    final_rem   = rem_shifted[XLEN-1:0];
    if (!rem_sub[XLEN]) begin
      final_quot = {quotient_q[XLEN-2:0], 1'b1};
      final_rem  = rem_sub[XLEN-1:0];
    end
    signed_quot = div_neg_q ? (~final_quot + XLEN'(1)) : final_quot;
    signed_rem  = rem_neg_q ? (~final_rem  + XLEN'(1)) : final_rem;
    pre_result  = is_rem_q  ? signed_rem : signed_quot;
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign busy_o   = (state_q == MUL_IN) | (state_q == MUL_MID) |
                    (state_q == MUL_OUT) | (state_q == COMPUTE);
  assign valid_o  = (state_q == DONE);
  assign idle_o   = (state_q == IDLE);
  assign result_o = result_q;

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= IDLE;
      result_q      <= {XLEN{1'b0}};
      mul_a65_q     <= {(XLEN+1){1'b0}};
      mul_b65_q     <= {(XLEN+1){1'b0}};
      pp_lo_q       <= 98'sd0;
      pp_hi_q       <= 98'sd0;
      mul_product_q <= {(2*XLEN+2){1'b0}};
      op_q          <= MULDIV_MUL;
      dividend_q    <= {XLEN{1'b0}};
      remainder_q   <= {(XLEN+1){1'b0}};
      quotient_q    <= {XLEN{1'b0}};
      abs_b_q       <= {XLEN{1'b0}};
      count_q       <= 7'b0;
      div_neg_q     <= 1'b0;
      rem_neg_q     <= 1'b0;
      is_rem_q      <= 1'b0;
      word_op_q     <= 1'b0;
    end else begin
      unique case (state_q)

        // ---------------------------------------------------------------
        IDLE: begin
          if (req_i) begin
            unique case (op_i)
              MULDIV_MUL, MULDIV_MULH, MULDIV_MULHSU, MULDIV_MULHU: begin
                // Pipeline stage 1: capture sign-extended 65-bit operands.
                // Path A: a_i/b_i → word_op mux → sign-extend → register.
                // ~2–3 ns, well within budget.
                mul_a65_q <= mul_a65;
                mul_b65_q <= mul_b65;
                op_q      <= op_i;
                word_op_q <= word_op_i;
                state_q   <= MUL_IN;
              end

              MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU: begin
                word_op_q <= word_op_i;

                if (b_is_zero) begin
                  // Divide by zero: DIV/DIVU -> all ones; REM/REMU -> dividend.
                  // For word_op the all-ones is naturally sign-extended.
                  if ((op_i == MULDIV_REM) | (op_i == MULDIV_REMU)) begin
                    result_q <= word_op_i
                                ? {{INST_W{a_i[INST_W-1]}}, a_i[INST_W-1:0]}
                                : a_i;
                  end else begin
                    result_q <= ALL_ONES_64;
                  end
                  state_q <= DONE;
                end else if (ov_div) begin
                  // Signed overflow: INT_MIN / -1 = INT_MIN
                  result_q <= int_min;
                  state_q  <= DONE;
                end else if (ov_rem) begin
                  // Signed overflow: INT_MIN % -1 = 0
                  result_q <= XLEN'(0);
                  state_q  <= DONE;
                end else begin
                  // Normal case: iterative restoring division.
                  // For word_op, left-align the 32-bit dividend into the
                  // upper 32 bits so the MSB-first shift consumes real bits.
                  dividend_q  <= word_op_i ? {abs_a[INST_W-1:0], {INST_W{1'b0}}} : abs_a;
                  remainder_q <= {(XLEN+1){1'b0}};
                  quotient_q  <= {XLEN{1'b0}};
                  abs_b_q     <= abs_b;
                  div_neg_q   <= (op_i == MULDIV_DIV) & (a_eff[XLEN-1] ^ b_eff[XLEN-1]);
                  rem_neg_q   <= (op_i == MULDIV_REM) & a_eff[XLEN-1];
                  is_rem_q    <= (op_i == MULDIV_REM) | (op_i == MULDIV_REMU);
                  count_q     <= word_op_i ? 7'(INST_W) : 7'(XLEN);
                  state_q     <= COMPUTE;
                end
              end

              // verilator coverage_off
              default: state_q <= IDLE;
              // verilator coverage_on
            endcase
          end
        end

        // ---------------------------------------------------------------
        // Pipeline stage 2: compute two 65×33 partial products.
        // Splitting the 65×65 multiply into (a × b[64:32]_signed) and
        // (a × {1'b0, b[31:0]}) lets each partial fit in a short DSP48E2
        // cascade, keeping the logic depth per cycle under budget.
        MUL_IN: begin
          pp_lo_q <= $signed(mul_a65_q) * $signed({1'b0, mul_b65_q[INST_W-1:0]});
          pp_hi_q <= $signed(mul_a65_q) * $signed(mul_b65_q[XLEN:INST_W]);
          state_q <= MUL_MID;
        end

        // ---------------------------------------------------------------
        // Pipeline stage 3: sum the partials into the full 130-bit product.
        // {pp_hi_q, 32'd0} is pp_hi_q << 32 with sign preserved because the
        // MSB of pp_hi_q lands in bit 129 of mul_product_q, the sign bit of
        // the 130-bit signed result.
        MUL_MID: begin
          mul_product_q <= 130'($signed({pp_hi_q, {INST_W{1'b0}}})
                                + $signed({{33{pp_lo_q[97]}}, pp_lo_q}));
          state_q <= MUL_OUT;
        end

        // ---------------------------------------------------------------
        // Pipeline stage 4: select result half and sign-extend to 64 bits.
        // Path: product register → mux → result_q. ~1.5 ns.
        MUL_OUT: begin
          result_q <= word_op_q ? {{INST_W{mul_sel[INST_W-1]}}, mul_sel[INST_W-1:0]} : mul_sel;
          state_q  <= DONE;
        end

        // ---------------------------------------------------------------
        COMPUTE: begin
          // One restoring-division step per cycle.
          if (!rem_sub[XLEN]) begin
            remainder_q <= {1'b0, rem_sub[XLEN-1:0]};
            quotient_q  <= {quotient_q[XLEN-2:0], 1'b1};
          end else begin
            remainder_q <= {1'b0, rem_shifted[XLEN-1:0]};
            quotient_q  <= {quotient_q[XLEN-2:0], 1'b0};
          end
          dividend_q <= div_shifted;
          count_q    <= count_q - 7'd1;

          if (count_q == 7'd1) begin
            // For word_op, sign-extend the low 32 bits of the result.
            result_q <= word_op_q
                        ? {{INST_W{pre_result[INST_W-1]}}, pre_result[INST_W-1:0]}
                        : pre_result;
            state_q  <= DONE;
          end
        end

        // ---------------------------------------------------------------
        DONE: begin
          state_q <= IDLE;
        end

        // verilator coverage_off
        default: state_q <= IDLE;
        // verilator coverage_on
      endcase
    end
  end

endmodule
