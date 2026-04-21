// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_decode_fp;
  import kronos_pkg::*;

  logic [31:0]    instr;
  logic [2:0]     frm = 3'b000;
  decoded_instr_t dec;
  logic           illegal;

  kronos_decode u_dut (.instr_i(instr), .frm_i(frm),
                       .decoded_o(dec), .illegal_insn_o(illegal));

  task automatic check(input string name, input bit ok);
    if (!ok) $fatal(1, "FAIL %s", name);
    else     $display("ok %s", name);
  endtask

  initial begin
    // FADD.S f1, f2, f3  (funct7=0000000, fmt=00, rm=000, opcode=0x53)
    instr = {7'b0000000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fadd.s is_fp",  dec.is_fp);
    check("fadd.s rd_fp",  dec.rd_fp);
    check("fadd.s rs1_fp", dec.rs1_fp);
    check("fadd.s rs2_fp", dec.rs2_fp);
    check("fadd.s fmt",    dec.fmt_d === 1'b0);
    check("fadd.s op",     dec.fp_op === FP_FADD);
    check("fadd.s rm",     dec.rm_resolved === 3'b000);
    check("fadd.s legal",  !illegal);

    // FADD.D with dynamic rm, FRM=010
    frm   = 3'b010;
    instr = {7'b0000001, 5'd3, 5'd2, 3'b111, 5'd1, 7'b1010011};
    #1;
    check("fadd.d rm=frm", dec.rm_resolved === 3'b010);
    check("fadd.d legal",  !illegal);

    // Illegal rm = 101 in instruction
    instr = {7'b0000000, 5'd3, 5'd2, 3'b101, 5'd1, 7'b1010011};
    #1;
    check("illegal rm 101", illegal);

    // Illegal rm = 111 (dynamic) but FRM holds 110 (illegal)
    frm   = 3'b110;
    instr = {7'b0000000, 5'd3, 5'd2, 3'b111, 5'd1, 7'b1010011};
    #1;
    check("dyn frm=110 illegal", illegal);
    frm = 3'b000;

    // FLD: rd=f1, rs1=x2, imm=8, funct3=011, opcode=0x07
    instr = {12'd8, 5'd2, 3'b011, 5'd1, 7'b0000111};
    #1;
    check("fld fp_load",  dec.fp_load);
    check("fld rd_fp",    dec.rd_fp);
    check("fld !rs1_fp",  !dec.rs1_fp);

    // FSW: rs1=x2, rs2=f3, imm=0, funct3=010, opcode=0x27
    instr = {7'b0, 5'd3, 5'd2, 3'b010, 5'b0, 7'b0100111};
    #1;
    check("fsw fp_store", dec.fp_store);
    check("fsw rs2_fp",   dec.rs2_fp);
    check("fsw !rd_fp",   !dec.rd_fp);

    // FCVT.W.S: rs1=f1, rd=x2, funct7=1100000, rs2=00000
    instr = {7'b1100000, 5'd0, 5'd1, 3'b000, 5'd2, 7'b1010011};
    #1;
    check("fcvt.w.s rs1_fp", dec.rs1_fp);
    check("fcvt.w.s !rd_fp", !dec.rd_fp);
    check("fcvt.w.s op",     dec.fp_op === FP_FCVT_W_F);

    // FMADD.D f1,f2,f3,f4  (funct7 fmt=01, funct3=000 rm, opcode=0x43)
    instr = {5'd4, 2'b01, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1000011};
    #1;
    check("fmadd.d is_fp", dec.is_fp);
    check("fmadd.d rs3_fp", dec.rs3_fp);
    check("fmadd.d rs3",    dec.rs3 === 5'd4);
    check("fmadd.d op",     dec.fp_op === FP_FMADD);
    check("fmadd.d fmt_d",  dec.fmt_d);

    // FSGNJ.S f1, f2, f3  (funct7=0010000, funct3=000, opcode=0x53)
    instr = {7'b0010000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fsgnj.s op",     dec.fp_op === FP_FSGNJ);
    check("fsgnj.s rs1_fp", dec.rs1_fp);
    check("fsgnj.s rs2_fp", dec.rs2_fp);
    check("fsgnj.s rd_fp",  dec.rd_fp);

    // FMIN.D f1, f2, f3  (funct7=0010101, funct3=000, opcode=0x53)
    instr = {7'b0010101, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fmin.d op",    dec.fp_op === FP_FMIN);
    check("fmin.d fmt_d", dec.fmt_d);
    check("fmin.d rd_fp", dec.rd_fp);

    // FEQ.S f2, f3 -> x1  (funct7=1010000, funct3=010, opcode=0x53, rd=x1 integer)
    instr = {7'b1010000, 5'd3, 5'd2, 3'b010, 5'd1, 7'b1010011};
    #1;
    check("feq.s op",     dec.fp_op === FP_FEQ);
    check("feq.s rs1_fp", dec.rs1_fp);
    check("feq.s rs2_fp", dec.rs2_fp);
    check("feq.s !rd_fp", !dec.rd_fp);
    check("feq.s legal",  !illegal);
    check("feq.s rd_wen", dec.rd_wen === 1'b1);

    // FCLASS.D f1 -> x2  (funct7=1110001, funct3=001, rs2=00000, opcode=0x53)
    instr = {7'b1110001, 5'd0, 5'd1, 3'b001, 5'd2, 7'b1010011};
    #1;
    check("fclass.d op",     dec.fp_op === FP_FCLASS);
    check("fclass.d rs1_fp", dec.rs1_fp);
    check("fclass.d !rd_fp", !dec.rd_fp);
    check("fclass.d rd_wen", dec.rd_wen);

    // FMV.W.X f1, x2  (funct7=1111000, funct3=000, rs2=00000, opcode=0x53)
    instr = {7'b1111000, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fmv.w.x op",      dec.fp_op === FP_FMV_W_X);
    check("fmv.w.x !rs1_fp", !dec.rs1_fp);
    check("fmv.w.x rd_fp",   dec.rd_fp);

    // FCVT.D.S f1, f2  (funct7=0100001, rs2=00000, opcode=0x53)
    // funct7[6:2]=01000, funct7[1:0]=01 → S→D conversion
    instr = {7'b0100001, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.d.s op",     dec.fp_op === FP_FCVT_D_S);
    check("fcvt.d.s rs1_fp", dec.rs1_fp);
    check("fcvt.d.s rd_fp",  dec.rd_fp);
    check("fcvt.d.s legal",  !illegal);

    // FNMADD.S f1, f2, f3, f5  (opcode=0x4F, fmt=00, rs3=f5, rs2=f3, rs1=f2, rm=000, rd=f1)
    instr = {5'd5, 2'b00, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1001111};
    #1;
    check("fnmadd.s op",     dec.fp_op === FP_FNMADD);
    check("fnmadd.s rs3_fp", dec.rs3_fp);
    check("fnmadd.s rs3",    dec.rs3 === 5'd5);
    check("fnmadd.s !fmt_d", !dec.fmt_d);

    // FDIV.S — legal in Stage 5b (iterative SRT)
    instr = {7'b0001100, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fdiv.s legal", !illegal);

    // FSUB.S f1, f2, f3
    instr = {7'b0000100, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fsub.s op", dec.fp_op === FP_FSUB);
    check("fsub.s rd_fp", dec.rd_fp);
    check("fsub.s legal", !illegal);

    // FSGNJN.S f1, f2, f3
    instr = {7'b0010000, 5'd3, 5'd2, 3'b001, 5'd1, 7'b1010011};
    #1;
    check("fsgnjn.s op", dec.fp_op === FP_FSGNJN);

    // FSGNJX.S f1, f2, f3
    instr = {7'b0010000, 5'd3, 5'd2, 3'b010, 5'd1, 7'b1010011};
    #1;
    check("fsgnjx.s op", dec.fp_op === FP_FSGNJX);

    // FSGNJ illegal funct3
    instr = {7'b0010000, 5'd3, 5'd2, 3'b011, 5'd1, 7'b1010011};
    #1;
    check("fsgnj_ill illegal", illegal);

    // FMAX.S f1, f2, f3
    instr = {7'b0010100, 5'd3, 5'd2, 3'b001, 5'd1, 7'b1010011};
    #1;
    check("fmax.s op", dec.fp_op === FP_FMAX);

    // FMIN/FMAX illegal funct3
    instr = {7'b0010100, 5'd3, 5'd2, 3'b010, 5'd1, 7'b1010011};
    #1;
    check("fminmax_ill illegal", illegal);

    // FCVT.S.D f1, f2  (funct7=0100000, funct7[1:0]=00 → D→S)
    instr = {7'b0100000, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.s.d op",    dec.fp_op === FP_FCVT_S_D);
    check("fcvt.s.d legal", !illegal);

    // FCVT S/D format illegal (funct7[1:0]=10)
    instr = {7'b0100010, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt_fmt_ill illegal", illegal);

    // FSQRT.S f1, f2  (rs2 must be 00000)
    instr = {7'b0101100, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fsqrt.s op",    dec.fp_op === FP_FSQRT);
    check("fsqrt.s rd_fp", dec.rd_fp);
    check("fsqrt.s legal", !illegal);

    // FLT.S f2, f3 -> x1
    instr = {7'b1010000, 5'd3, 5'd2, 3'b001, 5'd1, 7'b1010011};
    #1;
    check("flt.s op", dec.fp_op === FP_FLT);

    // FLE.S f2, f3 -> x1
    instr = {7'b1010000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fle.s op", dec.fp_op === FP_FLE);

    // FEQ/FLT/FLE illegal funct3
    instr = {7'b1010000, 5'd3, 5'd2, 3'b011, 5'd1, 7'b1010011};
    #1;
    check("feqflt_ill illegal", illegal);

    // FCVT.WU.S f1 -> x2  (rs2=00001)
    instr = {7'b1100000, 5'b00001, 5'd1, 3'b000, 5'd2, 7'b1010011};
    #1;
    check("fcvt.wu.s op", dec.fp_op === FP_FCVT_WU_F);

    // FCVT.L.S f1 -> x2  (rs2=00010)
    instr = {7'b1100000, 5'b00010, 5'd1, 3'b000, 5'd2, 7'b1010011};
    #1;
    check("fcvt.l.s op", dec.fp_op === FP_FCVT_L_F);

    // FCVT.LU.S f1 -> x2  (rs2=00011)
    instr = {7'b1100000, 5'b00011, 5'd1, 3'b000, 5'd2, 7'b1010011};
    #1;
    check("fcvt.lu.s op", dec.fp_op === FP_FCVT_LU_F);

    // FCVT.W.F illegal rs2
    instr = {7'b1100000, 5'b00100, 5'd1, 3'b000, 5'd2, 7'b1010011};
    #1;
    check("fcvt_wf_ill illegal", illegal);

    // FCVT.S.W x2 -> f1  (funct7=1101000, rs2=00000)
    instr = {7'b1101000, 5'b00000, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.s.w op",    dec.fp_op === FP_FCVT_F_W);
    check("fcvt.s.w rd_fp", dec.rd_fp);
    check("fcvt.s.w legal", !illegal);

    // FCVT.S.WU x2 -> f1  (rs2=00001)
    instr = {7'b1101000, 5'b00001, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.s.wu op", dec.fp_op === FP_FCVT_F_WU);

    // FCVT.S.L x2 -> f1  (rs2=00010)
    instr = {7'b1101000, 5'b00010, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.s.l op", dec.fp_op === FP_FCVT_F_L);

    // FCVT.S.LU x2 -> f1  (rs2=00011)
    instr = {7'b1101000, 5'b00011, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt.s.lu op", dec.fp_op === FP_FCVT_F_LU);

    // FCVT.F.W illegal rs2
    instr = {7'b1101000, 5'b00100, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fcvt_fw_ill illegal", illegal);

    // FMV.X.W x1, f2  (funct7=1110000, instr[25]=0 single, funct3=000)
    instr = {7'b1110000, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fmv.x.w op",     dec.fp_op === FP_FMV_X_W);
    check("fmv.x.w rs1_fp", dec.rs1_fp);
    check("fmv.x.w !rd_fp", !dec.rd_fp);

    // FCLASS.S x1, f2  (funct7=1110000, funct3=001)
    instr = {7'b1110000, 5'd0, 5'd2, 3'b001, 5'd1, 7'b1010011};
    #1;
    check("fclass.s op", dec.fp_op === FP_FCLASS);

    // FMV.X.W/FCLASS.S illegal funct3
    instr = {7'b1110000, 5'd0, 5'd2, 3'b010, 5'd1, 7'b1010011};
    #1;
    check("fmvxw_ill illegal", illegal);

    // FMV.X.D x1, f2  (funct7=1110001, instr[25]=1 double, funct3=000)
    instr = {7'b1110001, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fmv.x.d op", dec.fp_op === FP_FMV_X_D);

    // FMV.X.D/FCLASS.D illegal funct3
    instr = {7'b1110001, 5'd0, 5'd2, 3'b010, 5'd1, 7'b1010011};
    #1;
    check("fmvxd_ill illegal", illegal);

    // FMV.D.X f1, x2  (funct7=1111001, instr[25]=1 double)
    instr = {7'b1111001, 5'd0, 5'd2, 3'b000, 5'd1, 7'b1010011};
    #1;
    check("fmv.d.x op",    dec.fp_op === FP_FMV_D_X);
    check("fmv.d.x rd_fp", dec.rd_fp);

    // FMSUB.S f1, f2, f3, f5  (opcode=0x47 FMSUB_OP, fmt=00)
    instr = {5'd5, 2'b00, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1000111};
    #1;
    check("fmsub.s op",     dec.fp_op === FP_FMSUB);
    check("fmsub.s rs3_fp", dec.rs3_fp);
    check("fmsub.s !fmt_d", !dec.fmt_d);

    // FNMSUB.S f1, f2, f3, f5  (opcode=0x4B FNMSUB_OP, fmt=00)
    instr = {5'd5, 2'b00, 5'd3, 5'd2, 3'b000, 5'd1, 7'b1001011};
    #1;
    check("fnmsub.s op",     dec.fp_op === FP_FNMSUB);
    check("fnmsub.s rs3_fp", dec.rs3_fp);

    // Reserved opcode — triggers top-level default: illegal
    instr = 32'h0000000B;
    #1;
    check("reserved_op illegal", illegal);

    $display("tb_decode_fp PASS");
    $finish;
  end
endmodule
