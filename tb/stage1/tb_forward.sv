// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_forward;
  import kronos_pkg::*;

  logic [4:0] if_id_rs1_i, if_id_rs2_i;
  logic       if_id_rs1_used_i, if_id_rs2_used_i;
  logic [4:0] id_ex_rd_i;
  logic       id_ex_rd_wen_i, id_ex_is_load_i;
  logic [4:0] ex_mem_rd_i;
  logic       ex_mem_rd_wen_i;
  fwd_sel_e   fwd_rs1_sel_o, fwd_rs2_sel_o;

  kronos_forward u_fwd (
    .if_id_rs1_i      (if_id_rs1_i),
    .if_id_rs1_used_i (if_id_rs1_used_i),
    .if_id_rs2_i      (if_id_rs2_i),
    .if_id_rs2_used_i (if_id_rs2_used_i),
    .id_ex_rd_i       (id_ex_rd_i),
    .id_ex_rd_wen_i   (id_ex_rd_wen_i),
    .id_ex_is_load_i  (id_ex_is_load_i),
    .ex_mem_rd_i      (ex_mem_rd_i),
    .ex_mem_rd_wen_i  (ex_mem_rd_wen_i),
    .fwd_rs1_sel_o    (fwd_rs1_sel_o),
    .fwd_rs2_sel_o    (fwd_rs2_sel_o)
  );

  int errors = 0;

  task check(input fwd_sel_e exp1, exp2, input string name);
    #1;
    if (fwd_rs1_sel_o !== exp1 || fwd_rs2_sel_o !== exp2) begin
      $display("FAIL %s: rs1=%0d(exp %0d) rs2=%0d(exp %0d)",
               name, fwd_rs1_sel_o, exp1, fwd_rs2_sel_o, exp2);
      errors++;
    end else $display("PASS %s", name);
  endtask

  initial begin
    // baseline: nothing produces, nothing consumes
    if_id_rs1_i = 5'd1; if_id_rs1_used_i = 1;
    if_id_rs2_i = 5'd2; if_id_rs2_used_i = 1;
    id_ex_rd_i = 5'd0; id_ex_rd_wen_i = 0; id_ex_is_load_i = 0;
    ex_mem_rd_i = 5'd0; ex_mem_rd_wen_i = 0;
    check(FWD_NONE, FWD_NONE, "no hazard");

    // EX/MEM forward to RS1
    id_ex_rd_i = 5'd1; id_ex_rd_wen_i = 1; id_ex_is_load_i = 0;
    check(FWD_EXMEM, FWD_NONE, "EX/MEM -> RS1");

    // EX/MEM forward to RS2
    id_ex_rd_i = 5'd2; id_ex_rd_wen_i = 1; id_ex_is_load_i = 0;
    check(FWD_NONE, FWD_EXMEM, "EX/MEM -> RS2");

    // EX/MEM forward to both RS1 and RS2
    if_id_rs1_i = 5'd3; if_id_rs2_i = 5'd3;
    id_ex_rd_i = 5'd3; id_ex_rd_wen_i = 1; id_ex_is_load_i = 0;
    check(FWD_EXMEM, FWD_EXMEM, "EX/MEM -> RS1+RS2");

    // EX/MEM is a load — no EX/MEM forward (load-use case, handled by stall)
    if_id_rs1_i = 5'd1; if_id_rs2_i = 5'd2;
    id_ex_rd_i = 5'd1; id_ex_rd_wen_i = 1; id_ex_is_load_i = 1;
    check(FWD_NONE, FWD_NONE, "load in MEM - no EX/MEM fwd");

    // MEM/WB forward to RS1
    id_ex_rd_wen_i = 0; id_ex_is_load_i = 0;
    ex_mem_rd_i = 5'd1; ex_mem_rd_wen_i = 1;
    check(FWD_MEMWB, FWD_NONE, "MEM/WB -> RS1");

    // MEM/WB forward to RS2
    if_id_rs2_i = 5'd1;
    check(FWD_MEMWB, FWD_MEMWB, "MEM/WB -> RS1+RS2");

    // EX/MEM takes priority over MEM/WB
    if_id_rs1_i = 5'd5; if_id_rs2_i = 5'd5;
    id_ex_rd_i = 5'd5; id_ex_rd_wen_i = 1; id_ex_is_load_i = 0;
    ex_mem_rd_i = 5'd5; ex_mem_rd_wen_i = 1;
    check(FWD_EXMEM, FWD_EXMEM, "EX/MEM priority > MEM/WB");

    // No forward when rs_used=0 even if address matches
    if_id_rs1_i = 5'd1; if_id_rs1_used_i = 0;
    if_id_rs2_i = 5'd1; if_id_rs2_used_i = 0;
    id_ex_rd_i = 5'd1; id_ex_rd_wen_i = 1; id_ex_is_load_i = 0;
    ex_mem_rd_i = 5'd1; ex_mem_rd_wen_i = 1;
    check(FWD_NONE, FWD_NONE, "rs_used=0 suppresses forward");

    // No forward when producer rd=x0
    if_id_rs1_used_i = 1; if_id_rs2_used_i = 1;
    id_ex_rd_i = 5'd0; id_ex_rd_wen_i = 1;
    ex_mem_rd_i = 5'd0; ex_mem_rd_wen_i = 1;
    if_id_rs1_i = 5'd0; if_id_rs2_i = 5'd0;
    check(FWD_NONE, FWD_NONE, "rd=x0 never forwarded");

    if (errors == 0) $display("ALL FORWARD TESTS PASSED");
    else $display("%0d FORWARD TEST(S) FAILED", errors);
    $finish;
  end
endmodule
