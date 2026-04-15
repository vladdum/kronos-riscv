// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_pkg_fp;
  import kronos_pkg::*;

  fp_op_e      op;
  fpu_tag_t    tag;
  fp_round_e   rm;
  logic [63:0] canon_qnan_d;
  logic [31:0] canon_qnan_s;

  initial begin
    // These references must resolve at elaboration time.
    op           = FP_FADD;
    rm           = FP_RM_RNE;
    tag          = '{rd: 5'd3, fp_dest: 1'b1};
    canon_qnan_d = FP_CANON_QNAN_D;
    canon_qnan_s = FP_CANON_QNAN_S;
    $display("pkg_fp ok: op=%0d rm=%0d rd=%0d fp=%b qnan_s=%h qnan_d=%h",
             op, rm, tag.rd, tag.fp_dest, canon_qnan_s, canon_qnan_d);
    if (WB_TAG_W != 5) $fatal(1, "WB_TAG_W must be 5 in Stage 5a");
    $finish;
  end
endmodule
