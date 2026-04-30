// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_alu_s6;
  import kronos_pkg::*;

  logic [63:0] a, b, result, adder_out;
  logic        cmp_lt, eq;
  alu_op_e     op;
  logic        word_op;

  kronos_alu dut (
    .op_i        (op),
    .a_i         (a),
    .b_i         (b),
    .word_op_i   (word_op),
    .result_o    (result),
    .adder_out_o (adder_out),
    .cmp_lt_o    (cmp_lt),
    .eq_o        (eq)
  );

  int errors = 0;

  task check_result(string name, logic [63:0] expected);
    if (result !== expected) begin
      $display("FAIL %s: result got %016h, expected %016h", name, result, expected);
      errors++;
    end
  endtask

  task check_adder(string name, logic [63:0] expected);
    if (adder_out !== expected) begin
      $display("FAIL %s: adder_out got %016h, expected %016h", name, adder_out, expected);
      errors++;
    end
  endtask

  task check_cmp(string name, logic expected_lt, logic expected_eq);
    if (cmp_lt !== expected_lt) begin
      $display("FAIL %s: cmp_lt got %0b, expected %0b", name, cmp_lt, expected_lt);
      errors++;
    end
    if (eq !== expected_eq) begin
      $display("FAIL %s: eq got %0b, expected %0b", name, eq, expected_eq);
      errors++;
    end
  endtask

  // Behavioural model — used by the random-vector phase to cross-check `result_o`.
  function automatic logic [63:0] model_result(alu_op_e mop, logic [63:0] ma, logic [63:0] mb,
                                                logic mw);
    logic [63:0] r64;
    logic [31:0] r32;
    case (mop)
      ALU_ADD:   begin r64 = ma + mb;                                   r32 = ma[31:0] + mb[31:0]; end
      ALU_SUB:   begin r64 = ma - mb;                                   r32 = ma[31:0] - mb[31:0]; end
      ALU_SLL:   begin r64 = ma << mb[5:0];                             r32 = ma[31:0] << mb[4:0]; end
      ALU_SLT:   begin r64 = {63'b0, $signed(ma) < $signed(mb)};        r32 = r64[31:0];           end
      ALU_SLTU:  begin r64 = {63'b0, ma < mb};                          r32 = r64[31:0];           end
      ALU_XOR:   begin r64 = ma ^ mb;                                   r32 = ma[31:0] ^ mb[31:0]; end
      ALU_SRL:   begin r64 = ma >> mb[5:0];                             r32 = ma[31:0] >> mb[4:0]; end
      ALU_SRA:   begin r64 = 64'($signed(ma) >>> mb[5:0]);
                       r32 = 32'($signed(ma[31:0]) >>> mb[4:0]); end
      ALU_OR:    begin r64 = ma | mb;                                   r32 = ma[31:0] | mb[31:0]; end
      ALU_AND:   begin r64 = ma & mb;                                   r32 = ma[31:0] & mb[31:0]; end
      ALU_PASSB: begin r64 = mb;                                        r32 = mb[31:0];            end
      default:   begin r64 = 64'b0;                                     r32 = 32'b0;               end
    endcase
    if (mw) model_result = {{32{r32[31]}}, r32};
    else    model_result = r64;
  endfunction

  initial begin
    // -------------------------------------------------------------------
    // Directed: carryover from tb_alu_s5 (full 64-bit ops)
    // -------------------------------------------------------------------
    word_op = 0;
    op = ALU_ADD;   a = 64'h00000001_00000001; b = 64'h00000000_FFFFFFFF; #1;
    check_result("ADD64",          64'h00000002_00000000);
    op = ALU_SUB;   a = 64'h00000001_00000000; b = 64'h00000000_00000001; #1;
    check_result("SUB64",          64'h00000000_FFFFFFFF);
    op = ALU_SLL;   a = 64'h00000000_00000001; b = 64'd32; #1;
    check_result("SLL64_32",       64'h00000001_00000000);
    op = ALU_SLL;   a = 64'h00000000_00000001; b = 64'd63; #1;
    check_result("SLL64_63",       64'h80000000_00000000);
    op = ALU_SLL;   a = 64'hFFFFFFFF_FFFFFFFF; b = 64'd0;  #1;
    check_result("SLL64_0",        64'hFFFFFFFF_FFFFFFFF);
    op = ALU_SRL;   a = 64'h80000000_00000000; b = 64'd32; #1;
    check_result("SRL64_32",       64'h00000000_80000000);
    op = ALU_SRL;   a = 64'h80000000_00000000; b = 64'd63; #1;
    check_result("SRL64_63",       64'h00000000_00000001);
    op = ALU_SRA;   a = 64'hF000000000000000; b = 64'd4;  #1;
    check_result("SRA64_4",        64'hFF00000000000000);
    op = ALU_SRA;   a = 64'h8000000000000000; b = 64'd63; #1;
    check_result("SRA64_63_neg",   64'hFFFFFFFF_FFFFFFFF);
    op = ALU_SLT;   a = 64'hFFFFFFFF_FFFFFFFF; b = 64'h00000000_00000001; #1;
    check_result("SLT64_neg",      64'h1);
    op = ALU_SLTU;  a = 64'hFFFFFFFF_FFFFFFFF; b = 64'h00000000_00000001; #1;
    check_result("SLTU64",         64'h0);
    op = ALU_XOR;   a = 64'hAAAAAAAA_AAAAAAAA; b = 64'h55555555_55555555; #1;
    check_result("XOR64",          64'hFFFFFFFF_FFFFFFFF);
    op = ALU_OR;    a = 64'hAAAAAAAA_00000000; b = 64'h00000000_55555555; #1;
    check_result("OR64",           64'hAAAAAAAA_55555555);
    op = ALU_AND;   a = 64'hFFFFFFFF_00000000; b = 64'h0F0F0F0F_0F0F0F0F; #1;
    check_result("AND64",          64'h0F0F0F0F_00000000);
    op = ALU_PASSB; a = 64'hDEADBEEF;          b = 64'hCAFEBABE_12345678; #1;
    check_result("PASSB64",        64'hCAFEBABE_12345678);

    // -------------------------------------------------------------------
    // Directed: carryover word-op vectors
    // -------------------------------------------------------------------
    word_op = 1;
    op = ALU_ADD;   a = 64'h00000000_7FFFFFFF; b = 64'h00000000_00000001; #1;
    check_result("ADDW_overflow",  64'hFFFFFFFF_80000000);
    op = ALU_SUB;   a = 64'h0;                 b = 64'h1; #1;
    check_result("SUBW_neg",       64'hFFFFFFFF_FFFFFFFF);
    op = ALU_SLL;   a = 64'h00000000_00000001; b = 64'd31; #1;
    check_result("SLLW_31",        64'hFFFFFFFF_80000000);
    op = ALU_SRL;   a = 64'hFFFFFFFF_80000000; b = 64'd1;  #1;
    check_result("SRLW",           64'h00000000_40000000);
    op = ALU_SRA;   a = 64'hFFFFFFFF_80000000; b = 64'd1;  #1;
    check_result("SRAW",           64'hFFFFFFFF_C0000000);
    op = ALU_SLL;   a = 64'h00000000_00000001; b = 64'd32; #1;
    check_result("SLLW_wrap32",    64'h00000000_00000001);

    // -------------------------------------------------------------------
    // Adder output (raw): SUB and ADD modes
    // -------------------------------------------------------------------
    word_op = 0;
    op = ALU_ADD;   a = 64'h0000_0000_DEAD_BEEF; b = 64'h0000_0000_1111_2222; #1;
    check_adder("ADDER_ADD",   64'h0000_0000_EFBE_E111);
    op = ALU_SUB;   a = 64'h0000_0000_DEAD_BEEF; b = 64'h0000_0000_1111_2222; #1;
    check_adder("ADDER_SUB",   64'h0000_0000_CD9C_9CCD);

    // -------------------------------------------------------------------
    // Comparator: signed/unsigned + overflow corner cases
    //   - both MSBs clear -> adder MSB drives result
    //   - both MSBs set   -> adder MSB drives result
    //   - MSBs differ     -> operand MSB drives result (signed vs unsigned)
    // -------------------------------------------------------------------
    op = ALU_SLT;   a = 64'h0000_0000_0000_0001; b = 64'h0000_0000_0000_0002; #1;
    check_cmp("SLT_pos_lt",       1'b1, 1'b0);
    op = ALU_SLT;   a = 64'h0000_0000_0000_0002; b = 64'h0000_0000_0000_0001; #1;
    check_cmp("SLT_pos_gt",       1'b0, 1'b0);
    op = ALU_SLT;   a = 64'h7FFFFFFF_FFFFFFFF; b = 64'h7FFFFFFF_FFFFFFFE; #1;
    check_cmp("SLT_pos_max",      1'b0, 1'b0);
    op = ALU_SLT;   a = 64'h8000_0000_0000_0000; b = 64'h7FFF_FFFF_FFFF_FFFF; #1;
    check_cmp("SLT_neg_vs_pos",   1'b1, 1'b0);  // signed: most-negative < most-positive
    op = ALU_SLT;   a = 64'h7FFF_FFFF_FFFF_FFFF; b = 64'h8000_0000_0000_0000; #1;
    check_cmp("SLT_pos_vs_neg",   1'b0, 1'b0);
    op = ALU_SLT;   a = 64'hFFFF_FFFF_FFFF_FFFE; b = 64'hFFFF_FFFF_FFFF_FFFF; #1;
    check_cmp("SLT_neg_lt_neg",   1'b1, 1'b0);  // both MSBs set, -2 < -1
    op = ALU_SLTU;  a = 64'h8000_0000_0000_0000; b = 64'h7FFF_FFFF_FFFF_FFFF; #1;
    check_cmp("SLTU_high_vs_low", 1'b0, 1'b0);  // unsigned: 8.. > 7..
    op = ALU_SLTU;  a = 64'h7FFF_FFFF_FFFF_FFFF; b = 64'h8000_0000_0000_0000; #1;
    check_cmp("SLTU_low_vs_high", 1'b1, 1'b0);
    op = ALU_SUB;   a = 64'hCAFE_BABE_DEAD_BEEF; b = 64'hCAFE_BABE_DEAD_BEEF; #1;
    check_cmp("EQ_via_SUB",       1'b0, 1'b1);  // adder_out == 0 -> eq=1
    op = ALU_SLT;   a = 64'hCAFE_BABE_DEAD_BEEF; b = 64'hCAFE_BABE_DEAD_BEEF; #1;
    check_cmp("EQ_via_SLT",       1'b0, 1'b1);

    // -------------------------------------------------------------------
    // Invalid opcode -> result = 0 (default arm of result mux)
    // -------------------------------------------------------------------
    op = alu_op_e'(4'd15); a = 64'hDEAD_BEEF_CAFE_1234; b = 64'hFFFF; #1;
    check_result("invalid_op", 64'h0);

    // -------------------------------------------------------------------
    // Random vectors: 1k iterations per op, cross-check `result_o`
    // -------------------------------------------------------------------
    for (int op_idx = 0; op_idx < 11; op_idx++) begin
      automatic alu_op_e rop = alu_op_e'(op_idx);
      for (int it = 0; it < 1000; it++) begin
        automatic logic [63:0] ra = {$urandom(), $urandom()};
        automatic logic [63:0] rb = {$urandom(), $urandom()};
        automatic logic        rw = $urandom_range(0, 1) != 0;
        // SLT/SLTU have no W variant — force word_op=0 for them
        if (rop == ALU_SLT || rop == ALU_SLTU) rw = 1'b0;
        a = ra; b = rb; op = rop; word_op = rw; #1;
        if (result !== model_result(rop, ra, rb, rw)) begin
          $display("FAIL random op=%0d a=%016h b=%016h w=%0b: got %016h, expected %016h",
                   op_idx, ra, rb, rw, result, model_result(rop, ra, rb, rw));
          errors++;
        end
      end
    end

    if (errors == 0) $display("tb_alu_s6: ALL PASSED");
    else             $display("tb_alu_s6: %0d FAILED", errors);
    $finish;
  end
endmodule
