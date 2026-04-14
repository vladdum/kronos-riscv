// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_decompress.sv — Unit tests for kronos_decompress.
// Each test applies a 16-bit C encoding and checks the 32-bit expansion.
// Encodings and expected outputs are verified against riscv64-unknown-elf-objdump.
module tb_decompress;
  logic [15:0] instr16;
  logic [31:0] instr32;
  logic        illegal;

  int failures = 0;

  kronos_decompress u_dut (.instr16_i(instr16), .instr32_o(instr32), .illegal_o(illegal));

  task automatic check(input logic [15:0] c16, input logic [31:0] expected,
                       input string name);
    instr16 = c16;
    #1;
    if (instr32 !== expected || illegal !== 1'b0) begin
      $display("FAIL %s: in=0x%04x got=0x%08x ill=%b expected=0x%08x",
               name, c16, instr32, illegal, expected);
      failures++;
    end
  endtask

  task automatic check_illegal(input logic [15:0] c16, input string name);
    instr16 = c16;
    #1;
    if (illegal !== 1'b1) begin
      $display("FAIL %s: in=0x%04x expected illegal, got instr32=0x%08x", name, c16, instr32);
      failures++;
    end
  endtask

  initial begin
    // ---------------------------------------------------------------
    // Quadrant 0
    // ---------------------------------------------------------------
    // C.ADDI4SPN s0,sp,8  → ADDI x8,x2,8
    check(16'h0020, 32'h00810413, "C.ADDI4SPN x8,sp,8");
    // nzuimm=0 is reserved
    check_illegal(16'h0000, "C.ADDI4SPN nzuimm=0");
    // Q0 funct3=001 is reserved → illegal
    check_illegal(16'h2000, "Q0 reserved funct3=001");
    // C.LW a2,12(a3)  → LW x12,12(x13)
    check(16'h46D0, 32'h00C6A603, "C.LW x12,12(x13)");
    // C.SW a5,0(s0)   → SW x15,0(x8)   (offset=0, not 4)
    check(16'hC01C, 32'h00F42023, "C.SW x15,0(x8)");

    // ---------------------------------------------------------------
    // Quadrant 1
    // ---------------------------------------------------------------
    // C.NOP  → ADDI x0,x0,0
    check(16'h0001, 32'h00000013, "C.NOP");
    // C.ADDI a0,-1  → ADDI x10,x10,-1
    check(16'h157D, 32'hFFF50513, "C.ADDI a0,-1");
    // C.JAL -6  → JAL x1,-6
    check(16'h3FED, 32'hFFBFF0EF, "C.JAL -6");
    // C.LI a1,5  → ADDI x11,x0,5
    check(16'h4595, 32'h00500593, "C.LI a1,5");
    // C.LUI gp,1  → LUI x3,1   (rd=x3/gp, not x6/t1)
    check(16'h6185, 32'h000011B7, "C.LUI gp,1");
    // C.ADDI16SP -512  → ADDI x2,x2,-512
    check(16'h7101, 32'hE0010113, "C.ADDI16SP sp,-512");
    // C.SRLI x8,1  → SRLI x8,x8,1
    check(16'h8005, 32'h00145413, "C.SRLI x8,1");
    // C.SRAI x8,1  → SRAI x8,x8,1
    check(16'h8405, 32'h40145413, "C.SRAI x8,1");
    // C.ANDI x9,3  → ANDI x9,x9,3   (imm=3, not 7)
    check(16'h888D, 32'h0034F493, "C.ANDI x9,3");
    // C.SUB x8,x9  → SUB x8,x8,x9
    check(16'h8C05, 32'h40940433, "C.SUB x8,x9");
    // C.XOR x8,x9  → XOR x8,x8,x9
    check(16'h8C25, 32'h00944433, "C.XOR x8,x9");
    // C.OR  x8,x9  → OR  x8,x8,x9
    check(16'h8C45, 32'h00946433, "C.OR x8,x9");
    // C.AND x8,x9  → AND x8,x8,x9
    check(16'h8C65, 32'h00947433, "C.AND x8,x9");
    // C.J -14  → JAL x0,-14
    check(16'hBFCD, 32'hFF3FF06F, "C.J -14");
    // C.BEQZ x8,2  → BEQ x8,x0,2
    check(16'hC009, 32'h00040163, "C.BEQZ x8,2");
    // C.BNEZ x9,-16  → BNE x9,x0,-16
    check(16'hF8E5, 32'hFE0498E3, "C.BNEZ x9,-16");

    // ---------------------------------------------------------------
    // Quadrant 2
    // ---------------------------------------------------------------
    // C.SLLI a0,4  → SLLI x10,x10,4   (shamt=4, not 2)
    check(16'h0512, 32'h00451513, "C.SLLI a0,4");
    // C.LWSP a2,4  → LW x12,4(x2)     (offset=4, not 8)
    check(16'h4612, 32'h00412603, "C.LWSP a2,4");
    // C.SWSP a1,8  → SW x11,8(x2)     (rs2=a1/x11, offset=8)
    check(16'hC42E, 32'h00B12423, "C.SWSP a1,8");
    // C.JR a1  → JALR x0,0(x11)
    check(16'h8582, 32'h00058067, "C.JR a1");
    // C.MV t0,a0  → ADD x5,x0,x10
    check(16'h82AA, 32'h00A002B3, "C.MV t0,a0");
    // C.EBREAK  → EBREAK
    check(16'h9002, 32'h00100073, "C.EBREAK");
    // C.JALR a0  → JALR x1,0(x10)
    check(16'h9502, 32'h000500E7, "C.JALR a0");
    // C.ADD a0,a1  → ADD x10,x10,x11
    check(16'h952E, 32'h00B50533, "C.ADD a0,a1");

    if (failures == 0) $display("PASS: all tb_decompress checks");
    else               $display("FAIL: %0d tb_decompress checks failed", failures);
    $finish;
  end
endmodule
