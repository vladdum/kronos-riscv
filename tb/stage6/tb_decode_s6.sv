// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_decode_s6.sv — equivalence harness for kronos_decode vs kronos_decode_legacy.
// Compares the (eventually refactored) decoder against a frozen pre-refactor
// snapshot over directed + parametric + random stimulus. Any mismatch in
// decoded_o or illegal_insn_o fails the TB.

`timescale 1ns/1ps

module tb_decode_s6;
  import kronos_pkg::*;

  // Stimulus
  logic [INST_W-1:0] instr;
  logic [2:0]        frm;

  // DUT outputs
  decoded_instr_t    new_decoded;
  decoded_instr_t    old_decoded;
  logic              new_illegal;
  logic              old_illegal;

  // Counters
  int                check_count;
  int                err_count;

  // ----------------------------------------------------------------
  // DUT instances
  // ----------------------------------------------------------------
  kronos_decode u_new (
    .instr_i        (instr),
    .frm_i          (frm),
    .decoded_o      (new_decoded),
    .illegal_insn_o (new_illegal)
  );

  kronos_decode_legacy u_old (
    .instr_i        (instr),
    .frm_i          (frm),
    .decoded_o      (old_decoded),
    .illegal_insn_o (old_illegal)
  );

  // ----------------------------------------------------------------
  // Compare task — call after each stimulus update
  // ----------------------------------------------------------------
  task automatic check(input string label);
    #1;
    check_count++;
    if (new_decoded !== old_decoded || new_illegal !== old_illegal) begin
      err_count++;
      $display("FAIL [%s]: instr=%08h frm=%b", label, instr, frm);
      $display("  new_illegal=%b old_illegal=%b", new_illegal, old_illegal);
      if (err_count >= 20) begin
        $display("Aborting after 20 mismatches.");
        $finish;
      end
    end
  endtask

  // ----------------------------------------------------------------
  // Directed phase — every legal opcode + every Section-4 illegal case
  // ----------------------------------------------------------------
  task automatic directed_phase();
    frm = 3'b000;

    // INT — R-type
    instr = 32'h0000_0033; check("ADD");
    instr = 32'h4000_8033; check("SUB");
    instr = 32'h0000_9033; check("SLL");
    instr = 32'h0000_A033; check("SLT");
    instr = 32'h0000_B033; check("SLTU");
    instr = 32'h0000_C033; check("XOR");
    instr = 32'h0000_D033; check("SRL");
    instr = 32'h4000_D033; check("SRA");
    instr = 32'h0000_E033; check("OR");
    instr = 32'h0000_F033; check("AND");
    instr = 32'h0220_8033; check("MUL");
    instr = 32'h0220_F033; check("REMU");

    // INT — I-type
    instr = 32'h0050_0013; check("ADDI x0,x0,5");
    instr = 32'h0050_2013; check("SLTI x0,x0,5");
    instr = 32'h7FF0_2013; check("SLTI x0,x0,2047");
    instr = 32'h0030_1013; check("SLLI x0,x0,3");
    instr = 32'h0050_5013; check("SRLI x0,x0,5");
    instr = 32'h4050_5013; check("SRAI x0,x0,5");

    // INT — word ops
    instr = 32'h0000_003B; check("ADDW");
    instr = 32'h4000_803B; check("SUBW");
    instr = 32'h0220_803B; check("MULW");
    instr = 32'h0050_001B; check("ADDIW");

    // INT — LUI / AUIPC
    instr = 32'hDEAD_C037; check("LUI");
    instr = 32'h1234_5017; check("AUIPC");

    // CTRL — JAL / JALR / BRANCH
    instr = 32'h0080_00EF; check("JAL");
    instr = 32'h0080_00E7; check("JALR");
    instr = 32'h0080_0063; check("BEQ");
    instr = 32'h0080_1063; check("BNE");
    instr = 32'h0080_4063; check("BLT");
    instr = 32'h0080_5063; check("BGE");
    instr = 32'h0080_6063; check("BLTU");
    instr = 32'h0080_7063; check("BGEU");
    instr = 32'h0080_2063; check("BRANCH funct3=010 illegal");
    instr = 32'h0080_3063; check("BRANCH funct3=011 illegal");
    instr = 32'h0080_10E7; check("JALR funct3!=0 illegal");

    // MEM — LOAD / STORE / FP-LOAD / FP-STORE / AMO
    instr = 32'h0000_0003; check("LB");
    instr = 32'h0000_2003; check("LW");
    instr = 32'h0000_3003; check("LD");
    instr = 32'h0000_7003; check("LOAD funct3=111 illegal");
    instr = 32'h0000_0023; check("SB");
    instr = 32'h0000_3023; check("SD");
    instr = 32'h0000_4023; check("STORE funct3=100 illegal");
    instr = 32'h0000_2007; check("FLW");
    instr = 32'h0000_3007; check("FLD");
    instr = 32'h0000_2027; check("FSW");
    instr = 32'h0000_3027; check("FSD");
    instr = 32'h1000_802F; check("LR.W");
    instr = 32'h0810_802F; check("AMOSWAP.W");

    // SYS — privileged + CSR
    instr = 32'h0000_0073; check("ECALL");
    instr = 32'h0010_0073; check("EBREAK");
    instr = 32'h3020_0073; check("MRET");
    instr = 32'h1020_0073; check("SRET");
    instr = 32'h1050_0073; check("WFI");
    instr = 32'h1230_0073; check("SFENCE.VMA");
    instr = 32'hC000_2073; check("CSRRS rdcycle");
    instr = 32'hF000_50F3; check("CSRRWI x1, mtval, 0");

    // FP — OP_FP arithmetic + compare + classify + move
    instr = 32'h0010_0053; check("FADD.S placeholder");
    instr = 32'h0810_0053; check("FSUB.D placeholder");
    instr = 32'h2000_0053; check("FSGNJ.S placeholder");
    instr = 32'hA000_0053; check("FLE.S placeholder");
    instr = 32'hC000_0053; check("FCVT.W.S placeholder");
    instr = 32'hE000_0053; check("FMV.X.W placeholder");

    // FMA opcodes
    instr = 32'h0000_0043; check("FMADD.S placeholder");
    instr = 32'h0000_0047; check("FMSUB.S placeholder");
    instr = 32'h0000_004B; check("FNMSUB.S placeholder");
    instr = 32'h0000_004F; check("FNMADD.S placeholder");

    // Fully reserved opcode → wrapper default illegal
    instr = 32'h0000_007F; check("opcode 0x7F reserved");
    instr = 32'h0000_001F; check("opcode 0x1F reserved");
  endtask

  // ----------------------------------------------------------------
  // Parametric phase — exhaustive funct3/funct7 sweeps per class
  // ----------------------------------------------------------------
  task automatic parametric_phase();
    logic [6:0] op_field;
    frm = 3'b000;

    // OP (R-type) — full funct3 × funct7 sweep with rs1=x1, rs2=x2, rd=x3
    for (int f7 = 0; f7 < 128; f7++) begin
      for (int f3 = 0; f3 < 8; f3++) begin
        instr = {f7[6:0], 5'd2, 5'd1, f3[2:0], 5'd3, 7'b011_0011};
        check($sformatf("OP f7=%0d f3=%0d", f7, f3));
      end
    end

    // OP_IMM — funct3 sweep with imm=0x123
    for (int f3 = 0; f3 < 8; f3++) begin
      instr = {12'h123, 5'd1, f3[2:0], 5'd3, 7'b001_0011};
      check($sformatf("OP_IMM f3=%0d", f3));
    end

    // OP_32 — funct3 × funct7
    for (int f7 = 0; f7 < 128; f7++) begin
      for (int f3 = 0; f3 < 8; f3++) begin
        instr = {f7[6:0], 5'd2, 5'd1, f3[2:0], 5'd3, 7'b011_1011};
        check($sformatf("OP_32 f7=%0d f3=%0d", f7, f3));
      end
    end

    // BRANCH — funct3 sweep
    for (int f3 = 0; f3 < 8; f3++) begin
      instr = {7'h00, 5'd2, 5'd1, f3[2:0], 5'h00, 7'b110_0011};
      check($sformatf("BRANCH f3=%0d", f3));
    end

    // LOAD — funct3 sweep
    for (int f3 = 0; f3 < 8; f3++) begin
      instr = {12'h000, 5'd1, f3[2:0], 5'd3, 7'b000_0011};
      check($sformatf("LOAD f3=%0d", f3));
    end

    // STORE — funct3 sweep
    for (int f3 = 0; f3 < 8; f3++) begin
      instr = {7'h00, 5'd2, 5'd1, f3[2:0], 5'h00, 7'b010_0011};
      check($sformatf("STORE f3=%0d", f3));
    end

    // SYSTEM funct3 sweep
    for (int f3 = 0; f3 < 8; f3++) begin
      instr = {12'h000, 5'd1, f3[2:0], 5'd3, 7'b111_0011};
      check($sformatf("SYSTEM f3=%0d", f3));
    end

    // OP_FP — funct7[6:2] × funct3 × rm_field sweep
    for (int f7h = 0; f7h < 32; f7h++) begin
      for (int f3 = 0; f3 < 8; f3++) begin
        for (int rm = 0; rm < 8; rm++) begin
          frm   = 3'b000;
          instr = {f7h[4:0], 2'b00, 5'd2, 5'd1, rm[2:0], 5'd3, 7'b101_0011};
          check($sformatf("OP_FP f7h=%0d rm_field=%0d", f7h, rm));
        end
      end
    end
    frm = 3'b000;

    // FMADD/FMSUB/FNMSUB/FNMADD — rm sweep
    for (int op = 0; op < 4; op++) begin
      for (int rm = 0; rm < 8; rm++) begin
        op_field = {3'b100, op[1:0], 2'b11};
        instr    = {5'd0, 2'b00, 5'd2, 5'd1, rm[2:0], 5'd3, op_field};
        check($sformatf("FMA opcode=%0h rm=%0d", op_field, rm));
      end
    end
  endtask

  // ----------------------------------------------------------------
  // Random phase — 100k uniform-random instruction words
  // ----------------------------------------------------------------
  task automatic random_phase();
    for (int i = 0; i < 100_000; i++) begin
      instr = $urandom();
      frm   = 3'($urandom_range(0, 7));
      check("random");
    end
  endtask

  // ----------------------------------------------------------------
  // Main
  // ----------------------------------------------------------------
  initial begin
    instr       = 32'h0;
    frm         = 3'b000;
    check_count = 0;
    err_count   = 0;

    directed_phase();
    parametric_phase();
    random_phase();

    $display("=== tb_decode_s6: %0d checks, %0d errors ===",
             check_count, err_count);
    if (err_count == 0) $display("PASS");
    else                $display("FAIL");
    $finish;
  end
endmodule
