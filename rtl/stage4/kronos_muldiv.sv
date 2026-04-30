// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_muldiv.sv — multi-cycle 64-bit multiply/divide unit (RV64M).
//
// MUL/MULH/MULHSU/MULHU: 2-cycle latency (MUL_BUSY then DONE).
//   Operands are stored on req; a combinational 65x65 signed product is
//   registered during MUL_BUSY so synthesis sees a single multiplier.
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
//   busy_o  — HIGH while computing (MUL_BUSY or COMPUTE state); stalls the pipeline
//   valid_o — HIGH for exactly one cycle when result_o is ready (DONE state)
//   idle_o  — HIGH when ready to accept a new operation (IDLE state)
module kronos_muldiv
  import kronos_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  muldiv_op_e  op_i,
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic        word_op_i,
  output logic [63:0] result_o,
  output logic        busy_o,
  output logic        valid_o,
  output logic        idle_o
);

  // -------------------------------------------------------------------------
  // 1. Constants
  // -------------------------------------------------------------------------
  localparam logic [63:0] ALL_ONES_64 = 64'hFFFF_FFFF_FFFF_FFFF;
  localparam logic [63:0] INT_MIN_64  = 64'h8000_0000_0000_0000;
  localparam logic [63:0] INT_MIN_32  = 64'hFFFF_FFFF_8000_0000;

  // -------------------------------------------------------------------------
  // 2. Types — FSM state encoding
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE     = 2'd0,
    MUL_BUSY = 2'd1,
    COMPUTE  = 2'd2,
    DONE     = 2'd3
  } muldiv_state_e;

  // -------------------------------------------------------------------------
  // 3. State registers
  // -------------------------------------------------------------------------
  muldiv_state_e state_q;
  logic [63:0]   result_q;
  // Divider registers (restoring division)
  logic [63:0]   dividend_q;   // left-shifted each step; MSB feeds remainder
  logic [64:0]   remainder_q;  // 65-bit partial remainder (extra bit for borrow)
  logic [63:0]   quotient_q;
  logic [63:0]   abs_b_q;
  logic [6:0]    count_q;      // counts down from 64 (or 32 for word_op)
  logic          div_neg_q;    // negate quotient at end (signed DIV)
  logic          rem_neg_q;    // negate remainder at end (signed REM)
  logic          is_rem_q;     // 1 = REM/REMU, 0 = DIV/DIVU
  logic          word_op_q;    // latch of word_op_i for this operation

  // -------------------------------------------------------------------------
  // 4. Combinational signals
  // -------------------------------------------------------------------------
  // Multiplier (combinational 65x65 -> 130-bit signed product)
  logic                mul_signed_a;
  logic                mul_signed_b;
  logic [31:0]         mul_a_low;
  logic [31:0]         mul_b_low;
  logic                mul_a_sign_bit;
  logic                mul_b_sign_bit;
  logic [63:0]         mul_a_eff;
  logic [63:0]         mul_b_eff;
  logic [64:0]         mul_a65;
  logic [64:0]         mul_b65;
  logic signed [129:0] mul_product;
  logic [63:0]         mul_result_comb;
  logic [63:0]         mul_result_final;

  // IDLE → division setup combinational signals
  logic                is_signed_div;
  logic                a_sign_bit;
  logic                b_sign_bit;
  logic [63:0]         a_eff;
  logic [63:0]         b_eff;
  logic                neg_a;
  logic                neg_b;
  logic [63:0]         abs_a;
  logic [63:0]         abs_b;
  logic                b_is_zero;
  logic                ov_div;
  logic                ov_rem;
  logic [63:0]         int_min;

  // Restoring-division step
  logic [64:0]         rem_shifted;
  logic [64:0]         rem_sub;
  logic [63:0]         div_shifted;

  // Final-step divider result composition
  logic [63:0]         final_quot;
  logic [63:0]         final_rem;
  logic [63:0]         signed_quot;
  logic [63:0]         signed_rem;
  logic [63:0]         pre_result;

  // -------------------------------------------------------------------------
  // Multiplier operand shaping
  // -------------------------------------------------------------------------
  // MUL, MULH, MULHSU treat A as signed; MULHU is unsigned.
  assign mul_signed_a = (op_i == MULDIV_MUL) | (op_i == MULDIV_MULH) | (op_i == MULDIV_MULHSU);
  // MUL, MULH treat B as signed; MULHSU and MULHU are unsigned in B.
  assign mul_signed_b = (op_i == MULDIV_MUL) | (op_i == MULDIV_MULH);

  // For word_op, the effective operands are the low 32 bits, extended to 64.
  assign mul_a_low = a_i[31:0];
  assign mul_b_low = b_i[31:0];
  assign mul_a_sign_bit = mul_signed_a ? mul_a_low[31] : 1'b0;
  assign mul_b_sign_bit = mul_signed_b ? mul_b_low[31] : 1'b0;

  assign mul_a_eff = word_op_i ? {{32{mul_a_sign_bit}}, mul_a_low} : a_i;
  assign mul_b_eff = word_op_i ? {{32{mul_b_sign_bit}}, mul_b_low} : b_i;

  // Extend to 65 bits for signed/unsigned product.
  assign mul_a65 = mul_signed_a ? {mul_a_eff[63], mul_a_eff} : {1'b0, mul_a_eff};
  assign mul_b65 = mul_signed_b ? {mul_b_eff[63], mul_b_eff} : {1'b0, mul_b_eff};
  assign mul_product = $signed(mul_a65) * $signed(mul_b65);

  // Select high or low half of the product depending on op.
  always_comb begin
    mul_result_comb = mul_product[63:0];
    unique case (op_i)
      MULDIV_MUL:    mul_result_comb = mul_product[63:0];
      MULDIV_MULH:   mul_result_comb = mul_product[127:64];
      MULDIV_MULHSU: mul_result_comb = mul_product[127:64];
      MULDIV_MULHU:  mul_result_comb = mul_product[127:64];
      default:       mul_result_comb = mul_product[63:0];
    endcase
  end

  // Apply word_op sign extension to the registered multiplier output.
  assign mul_result_final = word_op_i
                          ? {{32{mul_result_comb[31]}}, mul_result_comb[31:0]}
                          : mul_result_comb;

  // -------------------------------------------------------------------------
  // Divider setup (combinational, used in IDLE on req_i)
  // -------------------------------------------------------------------------
  assign is_signed_div = (op_i == MULDIV_DIV) | (op_i == MULDIV_REM);

  // Effective operands: low 32 bits sign-extended when word_op.
  assign a_sign_bit = is_signed_div ? a_i[31] : 1'b0;
  assign b_sign_bit = is_signed_div ? b_i[31] : 1'b0;
  assign a_eff      = word_op_i ? {{32{a_sign_bit}}, a_i[31:0]} : a_i;
  assign b_eff      = word_op_i ? {{32{b_sign_bit}}, b_i[31:0]} : b_i;

  assign neg_a = is_signed_div & a_eff[63];
  assign neg_b = is_signed_div & b_eff[63];
  assign abs_a = neg_a ? (~a_eff + 64'd1) : a_eff;
  assign abs_b = neg_b ? (~b_eff + 64'd1) : b_eff;

  assign b_is_zero = (b_eff == 64'd0);

  assign int_min = word_op_i ? INT_MIN_32 : INT_MIN_64;
  assign ov_div  = (op_i == MULDIV_DIV) & (a_eff == int_min) & (b_eff == ALL_ONES_64);
  assign ov_rem  = (op_i == MULDIV_REM) & (a_eff == int_min) & (b_eff == ALL_ONES_64);

  // -------------------------------------------------------------------------
  // Restoring-division step
  // -------------------------------------------------------------------------
  assign rem_shifted = {remainder_q[63:0], dividend_q[63]};
  assign rem_sub     = rem_shifted - {1'b0, abs_b_q};
  assign div_shifted = {dividend_q[62:0], 1'b0};

  // -------------------------------------------------------------------------
  // Final-step divider result composition (used in COMPUTE last cycle)
  // -------------------------------------------------------------------------
  always_comb begin
    final_quot  = {quotient_q[62:0], 1'b0};
    final_rem   = rem_shifted[63:0];
    if (!rem_sub[64]) begin
      final_quot = {quotient_q[62:0], 1'b1};
      final_rem  = rem_sub[63:0];
    end
    signed_quot = div_neg_q ? (~final_quot + 64'd1) : final_quot;
    signed_rem  = rem_neg_q ? (~final_rem  + 64'd1) : final_rem;
    pre_result  = is_rem_q  ? signed_rem : signed_quot;
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign busy_o   = (state_q == MUL_BUSY) | (state_q == COMPUTE);
  assign valid_o  = (state_q == DONE);
  assign idle_o   = (state_q == IDLE);
  assign result_o = result_q;

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= IDLE;
      result_q    <= {64{1'b0}};
      dividend_q  <= {64{1'b0}};
      remainder_q <= {65{1'b0}};
      quotient_q  <= {64{1'b0}};
      abs_b_q     <= {64{1'b0}};
      count_q     <= {7{1'b0}};
      div_neg_q   <= 1'b0;
      rem_neg_q   <= 1'b0;
      is_rem_q    <= 1'b0;
      word_op_q   <= 1'b0;
    end else begin
      unique case (state_q)

        // ---------------------------------------------------------------
        IDLE: begin
          if (req_i) begin
            unique case (op_i)
              MULDIV_MUL, MULDIV_MULH, MULDIV_MULHSU, MULDIV_MULHU: begin
                // Capture combinational product; spend one cycle in MUL_BUSY.
                result_q  <= mul_result_final;
                word_op_q <= word_op_i;
                state_q   <= MUL_BUSY;
              end

              MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU: begin
                word_op_q <= word_op_i;

                if (b_is_zero) begin
                  // Divide by zero: DIV/DIVU -> all ones; REM/REMU -> dividend.
                  // For word_op the all-ones is naturally sign-extended.
                  if ((op_i == MULDIV_REM) | (op_i == MULDIV_REMU)) begin
                    result_q <= word_op_i
                                ? {{32{a_i[31]}}, a_i[31:0]}
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
                  result_q <= 64'd0;
                  state_q  <= DONE;
                end else begin
                  // Normal case: iterative restoring division.
                  // For word_op, left-align the 32-bit dividend into the
                  // upper 32 bits so the MSB-first shift consumes real bits.
                  dividend_q  <= word_op_i ? {abs_a[31:0], 32'd0} : abs_a;
                  remainder_q <= {65{1'b0}};
                  quotient_q  <= {64{1'b0}};
                  abs_b_q     <= abs_b;
                  div_neg_q   <= (op_i == MULDIV_DIV) & (a_eff[63] ^ b_eff[63]);
                  rem_neg_q   <= (op_i == MULDIV_REM) & a_eff[63];
                  is_rem_q    <= (op_i == MULDIV_REM) | (op_i == MULDIV_REMU);
                  count_q     <= word_op_i ? 7'd32 : 7'd64;
                  state_q     <= COMPUTE;
                end
              end

              default: state_q <= IDLE;
            endcase
          end
        end

        // ---------------------------------------------------------------
        MUL_BUSY: begin
          // result_q already holds the product; one busy cycle then expose.
          state_q <= DONE;
        end

        // ---------------------------------------------------------------
        COMPUTE: begin
          // One restoring-division step per cycle.
          if (!rem_sub[64]) begin
            remainder_q <= {1'b0, rem_sub[63:0]};
            quotient_q  <= {quotient_q[62:0], 1'b1};
          end else begin
            remainder_q <= {1'b0, rem_shifted[63:0]};
            quotient_q  <= {quotient_q[62:0], 1'b0};
          end
          dividend_q <= div_shifted;
          count_q    <= count_q - 7'd1;

          if (count_q == 7'd1) begin
            // For word_op, sign-extend the low 32 bits of the result.
            // pre_result is computed combinationally above.
            result_q <= word_op_q
                        ? {{32{pre_result[31]}}, pre_result[31:0]}
                        : pre_result;
            state_q  <= DONE;
          end
        end

        // ---------------------------------------------------------------
        DONE: begin
          state_q <= IDLE;
        end

        default: state_q <= IDLE;
      endcase
    end
  end

endmodule
