// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_muldiv.sv — multi-cycle multiply/divide unit (RV32M).
//
// MUL/MULH/MULHSU/MULHU: 3-cycle latency (MUL_BUSY_1 → MUL_BUSY_2 → DONE).
//   Cycle 1 (MUL_BUSY_1): register the raw 66-bit product into product_q.
//     No logic between the multiply and the register; synthesis can map this
//     to the DSP48E1 M register (MREG=1), removing the multiplier from the
//     combinational timing path.
//   Cycle 2 (MUL_BUSY_2): apply the half-select and sign correction from
//     product_q into result_q.
//   This costs one extra stall cycle per MUL vs the previous 2-cycle design
//   but allows Vivado to pipeline the DSP48E1 tiles and reach ~80-100 MHz
//   on Artix-7, up from ~62 MHz.
//
// DIV/DIVU/REM/REMU: 34-cycle latency (IDLE→COMPUTE×32→DONE).
//   Uses an iterative restoring algorithm. Edge cases (divide-by-zero,
//   INT_MIN÷−1) are detected in the IDLE→COMPUTE transition and go
//   directly to DONE.
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
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] result_o,
  output logic        busy_o,
  output logic        valid_o,
  output logic        idle_o
);

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE       = 3'd0,
    MUL_BUSY_1 = 3'd1,
    MUL_BUSY_2 = 3'd2,
    COMPUTE    = 3'd3,
    DONE       = 3'd4
  } muldiv_state_e;

  muldiv_state_e state_q;

  assign busy_o   = (state_q == MUL_BUSY_1) | (state_q == MUL_BUSY_2) | (state_q == COMPUTE);
  assign valid_o  = (state_q == DONE);
  assign idle_o   = (state_q == IDLE);
  assign result_o = result_q;

  // -------------------------------------------------------------------------
  // Stored result
  // -------------------------------------------------------------------------
  logic [31:0] result_q;

  // -------------------------------------------------------------------------
  // MUL pipeline:
  //   Stage 1 (MUL_BUSY_1): product_q ← raw 66-bit product.
  //     Clean flop-to-flop path: mul_a_q/mul_b_q → multiply → product_q.
  //     Synthesis maps product_q to the DSP48E1 M register (MREG=1).
  //   Stage 2 (MUL_BUSY_2): result_q ← half-select applied to product_q.
  //     Short path: product_q mux → result_q.
  // -------------------------------------------------------------------------
  logic signed [65:0] product_q;
  logic [31:0]   mul_a_q, mul_b_q;
  muldiv_op_e    mul_op_q;

  logic        mul_signed_a, mul_signed_b;
  logic [32:0] mul_a33, mul_b33;
  logic signed [65:0] mul_product;

  assign mul_signed_a = (mul_op_q == MULDIV_MUL) | (mul_op_q == MULDIV_MULH) | (mul_op_q == MULDIV_MULHSU);
  assign mul_signed_b = (mul_op_q == MULDIV_MUL) | (mul_op_q == MULDIV_MULH);
  assign mul_a33      = mul_signed_a ? {mul_a_q[31], mul_a_q} : {1'b0, mul_a_q};
  assign mul_b33      = mul_signed_b ? {mul_b_q[31], mul_b_q} : {1'b0, mul_b_q};
  assign mul_product  = $signed(mul_a33) * $signed(mul_b33);

  logic [31:0] mul_result_comb;
  assign mul_result_comb = (mul_op_q == MULDIV_MUL) ? product_q[31:0] : product_q[63:32];

  // -------------------------------------------------------------------------
  // DIV: registers for iterative restoring division
  // -------------------------------------------------------------------------
  logic [31:0] dividend_q;    // remaining dividend bits (shifted out left-to-right)
  logic [32:0] remainder_q;   // 33-bit partial remainder (extra bit for borrow detection)
  logic [31:0] quotient_q;
  logic [31:0] abs_b_q;       // |divisor| stored at start
  logic [5:0]  count_q;       // 32 down to 1
  logic        div_neg_q;     // negate quotient at end (signed DIV only)
  logic        rem_neg_q;     // negate remainder at end (signed REM only)
  logic        is_rem_q;      // 1 = REM/REMU, 0 = DIV/DIVU

  // Combinational signals for one restoring-division step
  logic [32:0] rem_shifted;   // {remainder_q[31:0], dividend_q[31]}
  logic [32:0] rem_sub;       // rem_shifted - {1'b0, abs_b_q}
  logic [31:0] div_shifted;   // {dividend_q[30:0], 1'b0}

  assign rem_shifted = {remainder_q[31:0], dividend_q[31]};
  assign rem_sub     = rem_shifted - {1'b0, abs_b_q};
  assign div_shifted = {dividend_q[30:0], 1'b0};

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= IDLE;
      result_q    <= '0;
      product_q   <= '0;
      mul_a_q     <= '0;
      mul_b_q     <= '0;
      mul_op_q    <= MULDIV_MUL;
      dividend_q  <= '0;
      remainder_q <= '0;
      quotient_q  <= '0;
      abs_b_q     <= '0;
      count_q     <= '0;
      div_neg_q   <= '0;
      rem_neg_q   <= '0;
      is_rem_q    <= '0;
    end else begin
      unique case (state_q)

        // ---------------------------------------------------------------
        IDLE: begin
          if (req_i) begin
            unique case (op_i)
              MULDIV_MUL, MULDIV_MULH, MULDIV_MULHSU, MULDIV_MULHU: begin
                // Latch operands; product is registered in MUL_BUSY_1
                mul_a_q  <= a_i;
                mul_b_q  <= b_i;
                mul_op_q <= op_i;
                state_q  <= MUL_BUSY_1;
              end

              MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU: begin
                // Pre-compute absolute values and sign correction flags
                logic        is_signed_div;
                logic        neg_a, neg_b;
                logic [31:0] abs_a, abs_b;

                is_signed_div = (op_i == MULDIV_DIV) | (op_i == MULDIV_REM);
                neg_a         = is_signed_div & a_i[31];
                neg_b         = is_signed_div & b_i[31];
                abs_a         = neg_a ? (~a_i + 32'd1) : a_i;
                abs_b         = neg_b ? (~b_i + 32'd1) : b_i;

                // RISC-V M-extension edge cases (return immediately to DONE)
                if (b_i == 32'd0) begin
                  // Divide by zero: DIV/DIVU → -1; REM/REMU → dividend
                  result_q <= ((op_i == MULDIV_REM) | (op_i == MULDIV_REMU))
                              ? a_i : 32'hFFFF_FFFF;
                  state_q  <= DONE;
                end else if ((op_i == MULDIV_DIV) &&
                             (a_i == 32'h8000_0000) && (b_i == 32'hFFFF_FFFF)) begin
                  // Signed overflow: INT_MIN / -1 = INT_MIN
                  result_q <= 32'h8000_0000;
                  state_q  <= DONE;
                end else if ((op_i == MULDIV_REM) &&
                             (a_i == 32'h8000_0000) && (b_i == 32'hFFFF_FFFF)) begin
                  // Signed overflow: INT_MIN % -1 = 0
                  result_q <= 32'h0000_0000;
                  state_q  <= DONE;
                end else begin
                  // Normal case: iterative restoring division
                  dividend_q  <= abs_a;
                  remainder_q <= '0;
                  quotient_q  <= '0;
                  abs_b_q     <= abs_b;
                  div_neg_q   <= (op_i == MULDIV_DIV) & (a_i[31] ^ b_i[31]);
                  rem_neg_q   <= (op_i == MULDIV_REM) & a_i[31];
                  is_rem_q    <= (op_i == MULDIV_REM) | (op_i == MULDIV_REMU);
                  count_q     <= 6'd32;
                  state_q     <= COMPUTE;
                end
              end

              default: state_q <= IDLE;
            endcase
          end
        end

        // ---------------------------------------------------------------
        MUL_BUSY_1: begin
          // Operands stable in mul_a_q/mul_b_q. Register the raw product.
          // Clean path: mul_a_q/mul_b_q → multiply → product_q (MREG).
          product_q <= mul_product;
          state_q   <= MUL_BUSY_2;
        end

        // ---------------------------------------------------------------
        MUL_BUSY_2: begin
          // product_q stable. Apply half-select and write result_q.
          // Short path: product_q mux → result_q.
          result_q <= mul_result_comb;
          state_q  <= DONE;
        end

        // ---------------------------------------------------------------
        COMPUTE: begin
          // One restoring-division step per cycle.
          if (!rem_sub[32]) begin
            // Subtraction did not underflow: accept
            remainder_q <= {1'b0, rem_sub[31:0]};
            quotient_q  <= {quotient_q[30:0], 1'b1};
          end else begin
            // Subtraction underflowed: restore
            remainder_q <= {1'b0, rem_shifted[31:0]};
            quotient_q  <= {quotient_q[30:0], 1'b0};
          end
          dividend_q <= div_shifted;
          count_q    <= count_q - 6'd1;

          if (count_q == 6'd1) begin
            // Final step: compute and sign-correct result
            logic [31:0] final_quot, final_rem;

            // Re-apply the last step outcome in comb to get the final values.
            if (!rem_sub[32]) begin
              final_quot = {quotient_q[30:0], 1'b1};
              final_rem  = rem_sub[31:0];
            end else begin
              final_quot = {quotient_q[30:0], 1'b0};
              final_rem  = rem_shifted[31:0];
            end

            if (is_rem_q) begin
              result_q <= rem_neg_q ? (~final_rem + 32'd1) : final_rem;
            end else begin
              result_q <= div_neg_q ? (~final_quot + 32'd1) : final_quot;
            end
            state_q <= DONE;
          end
        end

        // ---------------------------------------------------------------
        DONE: begin
          // valid_o is high this cycle; pipeline captures result_o.
          // Return to IDLE immediately.
          state_q <= IDLE;
        end

        default: state_q <= IDLE;
      endcase
    end
  end

endmodule
