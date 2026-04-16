// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module tb_fpu_fdiv_core;
  logic clk = 0;
  always #5 clk = ~clk;

  logic        rst_n = 0, start = 0, fmt_d = 0;
  logic [52:0] a, b;
  logic        done;
  logic [55:0] quot;
  logic        rem_nz;

  kronos_fpu_fdiv_core dut (
    .clk_i    (clk),
    .rst_ni   (rst_n),
    .flush_i  (1'b0),
    .start_i  (start),
    .fmt_d_i  (fmt_d),
    .a_i      (a),
    .b_i      (b),
    .done_o   (done),
    .quot_o   (quot),
    .rem_nz_o (rem_nz)
  );

  integer fd, errors = 0, tests = 0;

  initial begin
    rst_n = 1'b0;
    #20;
    rst_n = 1'b1;
    #10;

    fd = $fopen("fdiv_vectors.hex", "r");
    if (fd == 0) begin
      $display("ERROR: cannot open fdiv_vectors.hex");
      $finish;
    end

    while (!$feof(fd)) begin
      logic        exp_s;
      logic [55:0] exp_q;
      logic        fmt_v;
      logic [52:0] a_v, b_v;
      int          scan_result;

      scan_result = $fscanf(fd, "%b %h %h %h %b\n", fmt_v, a_v, b_v, exp_q, exp_s);
      if (scan_result != 5) continue;

      fmt_d = fmt_v;
      a     = a_v;
      b     = b_v;
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;

      // Wait for done
      while (!done) @(posedge clk);

      tests++;
      if (quot !== exp_q || rem_nz !== exp_s) begin
        $display("FAIL[%0d] fmt=%b a=%h b=%h exp_q=%h got_q=%h exp_s=%b got_s=%b",
                 tests, fmt_v, a_v, b_v, exp_q, quot, exp_s, rem_nz);
        errors++;
      end

      @(posedge clk);  // one idle cycle between tests
    end

    $fclose(fd);
    if (errors == 0) $display("PASS (%0d tests)", tests);
    else             $display("FAIL %0d/%0d errors", errors, tests);
    $finish;
  end
endmodule
