// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_hazard;
  import kronos_pkg::*;

  logic       id_ex_is_load_i, id_ex_valid_i;
  logic [4:0] id_ex_rd_i;
  logic       if_id_rs1_used_i, if_id_rs2_used_i;
  logic [4:0] if_id_rs1_i, if_id_rs2_i;
  logic       if_id_is_jalr_i;
  logic [4:0] ex_mem_rd_i;
  logic       ex_mem_rd_wen_i, ex_mem_valid_i;
  logic       ex_redirect_i, mem_stall_i;

  logic pc_en_o, if_id_en_o, id_ex_en_o, ex_mem_en_o, mem_wb_en_o;
  logic if_id_flush_o, id_ex_flush_o;

  kronos_hazard u_hz (
    .id_ex_is_load_i  (id_ex_is_load_i),
    .id_ex_rd_i       (id_ex_rd_i),
    .id_ex_valid_i    (id_ex_valid_i),
    .if_id_rs1_used_i (if_id_rs1_used_i),
    .if_id_rs1_i      (if_id_rs1_i),
    .if_id_rs2_used_i     (if_id_rs2_used_i),
    .if_id_rs2_i          (if_id_rs2_i),
    .id_ex_is_fp_load_i   ('0),
    .if_id_rs1_fp_i       ('0),
    .if_id_rs2_fp_i       ('0),
    .if_id_rs3_fp_i       ('0),
    .if_id_rs3_i          (5'd0),
    .if_id_is_jalr_i      (if_id_is_jalr_i),
    .ex_mem_rd_i          (ex_mem_rd_i),
    .ex_mem_rd_wen_i      (ex_mem_rd_wen_i),
    .ex_mem_valid_i       (ex_mem_valid_i),
    .ex_redirect_i        (ex_redirect_i),
    .mem_stall_i          (mem_stall_i),
    .pc_en_o              (pc_en_o),
    .if_id_en_o           (if_id_en_o),
    .id_ex_en_o           (id_ex_en_o),
    .ex_mem_en_o          (ex_mem_en_o),
    .mem_wb_en_o          (mem_wb_en_o),
    .if_id_flush_o        (if_id_flush_o),
    .id_ex_flush_o        (id_ex_flush_o)
  );

  int errors = 0;

  task check(
    input string name,
    input logic exp_pc_en, exp_ifid_en, exp_idex_en, exp_exmem_en, exp_memwb_en,
    input logic exp_ifid_flush, exp_idex_flush
  );
    #1;
    if (pc_en_o       !== exp_pc_en      || if_id_en_o   !== exp_ifid_en  ||
        id_ex_en_o    !== exp_idex_en    || ex_mem_en_o  !== exp_exmem_en ||
        mem_wb_en_o   !== exp_memwb_en   ||
        if_id_flush_o !== exp_ifid_flush || id_ex_flush_o !== exp_idex_flush) begin
      $display("FAIL %s", name);
      $display("  pc_en=%0b(exp %0b) ifid_en=%0b(exp %0b) idex_en=%0b(exp %0b)",
               pc_en_o, exp_pc_en, if_id_en_o, exp_ifid_en, id_ex_en_o, exp_idex_en);
      $display("  exmem_en=%0b(exp %0b) memwb_en=%0b(exp %0b)",
               ex_mem_en_o, exp_exmem_en, mem_wb_en_o, exp_memwb_en);
      $display("  ifid_flush=%0b(exp %0b) idex_flush=%0b(exp %0b)",
               if_id_flush_o, exp_ifid_flush, id_ex_flush_o, exp_idex_flush);
      errors++;
    end else $display("PASS %s", name);
  endtask

  initial begin
    id_ex_is_load_i = 0; id_ex_valid_i = 0; id_ex_rd_i = 0;
    if_id_rs1_used_i = 0; if_id_rs1_i = 0;
    if_id_rs2_used_i = 0; if_id_rs2_i = 0;
    if_id_is_jalr_i = 0;
    ex_mem_rd_i = 0; ex_mem_rd_wen_i = 0; ex_mem_valid_i = 0;
    ex_redirect_i = 0; mem_stall_i = 0;

    // Normal advance: all enables, no flush
    //                              pc ifid idex exmem memwb  ifid_fl idex_fl
    check("normal",                  1, 1,   1,   1,    1,     0,      0);

    // EX redirect: flush IF and ID, everything else advances
    ex_redirect_i = 1;
    check("redirect",                1, 1,   1,   1,    1,     1,      1);
    ex_redirect_i = 0;

    // Load-use on RS1: stall PC+IF+ID, bubble ID/EX, EX+MEM advance
    id_ex_is_load_i = 1; id_ex_valid_i = 1; id_ex_rd_i = 5'd3;
    if_id_rs1_used_i = 1; if_id_rs1_i = 5'd3;
    check("load-use RS1",            0, 0,   0,   1,    1,     0,      1);

    // Load-use on RS2
    if_id_rs1_used_i = 0; if_id_rs2_used_i = 1; if_id_rs2_i = 5'd3;
    check("load-use RS2",            0, 0,   0,   1,    1,     0,      1);

    // Load-use with rd=x0 — not a hazard
    id_ex_rd_i = 5'd0;
    check("load-use x0 - no stall", 1, 1,   1,   1,    1,     0,      0);
    id_ex_rd_i = 5'd3; if_id_rs2_used_i = 0;

    // MEM stall: hold everything (highest priority)
    mem_stall_i = 1;
    check("mem-stall",               0, 0,   0,   0,    0,     0,      0);

    // MEM stall + redirect simultaneously: mem-stall wins, no flush
    ex_redirect_i = 1;
    check("mem-stall+redirect",      0, 0,   0,   0,    0,     0,      0);
    ex_redirect_i = 0; mem_stall_i = 0;

    // MEM stall + load-use simultaneously: mem-stall wins
    if_id_rs1_used_i = 1; if_id_rs1_i = 5'd3; mem_stall_i = 1;
    check("mem-stall+load-use",      0, 0,   0,   0,    0,     0,      0);
    mem_stall_i = 0; if_id_rs1_used_i = 0;
    id_ex_is_load_i = 0; id_ex_valid_i = 0;

    // JALR forward stall: JALR in ID, rs1 matches MEM producer
    if_id_is_jalr_i = 1; if_id_rs1_used_i = 1; if_id_rs1_i = 5'd7;
    ex_mem_valid_i = 1; ex_mem_rd_wen_i = 1; ex_mem_rd_i = 5'd7;
    check("jalr-fwd-stall",             0, 0,   0,   1,    1,     0,      1);

    // JALR but rs1 doesn't match MEM rd — no stall
    ex_mem_rd_i = 5'd8;
    check("jalr-no-match",              1, 1,   1,   1,    1,     0,      0);

    // JALR but MEM rd is x0 — no stall
    ex_mem_rd_i = 5'd0;
    check("jalr-x0-no-stall",           1, 1,   1,   1,    1,     0,      0);

    // JALR stall + mem_stall simultaneously: mem_stall wins
    ex_mem_rd_i = 5'd7; mem_stall_i = 1;
    check("jalr-fwd+mem-stall",         0, 0,   0,   0,    0,     0,      0);
    mem_stall_i = 0;

    // Not JALR, same rs1/rd match — no stall
    if_id_is_jalr_i = 0;
    check("non-jalr-no-stall",          1, 1,   1,   1,    1,     0,      0);
    if_id_is_jalr_i = 0; if_id_rs1_used_i = 0;
    ex_mem_valid_i = 0; ex_mem_rd_wen_i = 0; ex_mem_rd_i = 0;

    if (errors == 0) $display("ALL HAZARD TESTS PASSED");
    else $display("%0d HAZARD TEST(S) FAILED", errors);
    $finish;
  end
endmodule
