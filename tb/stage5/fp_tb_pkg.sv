// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Shared helpers for Stage 5a FPU testbenches.
package fp_tb_pkg;

  // One stimulus/expected row read from a testfloat vector file.
  typedef struct {
    longint unsigned a;
    longint unsigned b;
    longint unsigned c;
    longint unsigned expected;
    byte     unsigned rm;
    byte     unsigned exp_flags;
  } fp_vec_t;

  // Decode a whitespace-separated line "a b c expected rm flags" (hex, no 0x).
  // Returns 1 on success (6 fields or 5 fields), 0 otherwise.
  function automatic int unsigned parse_vec_line(input string s,
                                                 output fp_vec_t v);
    int c;
    c = $sscanf(s, "%h %h %h %h %h %h",
                v.a, v.b, v.c, v.expected, v.rm, v.exp_flags);
    if (c == 6) return 1;
    // 2-operand form with no c
    c = $sscanf(s, "%h %h %h %h %h",
                v.a, v.b, v.expected, v.rm, v.exp_flags);
    v.c = '0;
    return (c == 5) ? 1 : 0;
  endfunction

  // Three-way diff: dut vs hf vs sf. Returns 1 if all match, 0 otherwise.
  function automatic int unsigned three_way_check(
    input  string           label,
    input  longint unsigned a, b, c,
    input  byte     unsigned rm,
    input  longint unsigned dut_res, hf_res, sf_res,
    input  byte     unsigned dut_flg, hf_flg, sf_flg
  );
    if (hf_res !== sf_res || hf_flg !== sf_flg) begin
      $error("[%s] reference mismatch: hf=%h/%02h sf=%h/%02h a=%h b=%h c=%h rm=%0d",
             label, hf_res, hf_flg, sf_res, sf_flg, a, b, c, rm);
      return 0;
    end
    if (dut_res !== hf_res || dut_flg !== hf_flg) begin
      $error("[%s] dut mismatch: dut=%h/%02h ref=%h/%02h a=%h b=%h c=%h rm=%0d",
             label, dut_res, dut_flg, hf_res, hf_flg, a, b, c, rm);
      return 0;
    end
    return 1;
  endfunction

  // Two-way diff: dut vs sf only (used when HardFloat is stubbed/unavailable).
  function automatic int unsigned two_way_check(
    input  string           label,
    input  longint unsigned a, b, c,
    input  byte     unsigned rm,
    input  longint unsigned dut_res, sf_res,
    input  byte     unsigned dut_flg, sf_flg
  );
    if (dut_res !== sf_res || dut_flg !== sf_flg) begin
      $error("[%s] dut mismatch: dut=%h/%02h ref=%h/%02h a=%h b=%h c=%h rm=%0d",
             label, dut_res, dut_flg, sf_res, sf_flg, a, b, c, rm);
      return 0;
    end
    return 1;
  endfunction

endpackage
