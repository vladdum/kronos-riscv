// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// tb_core_fp_basic — integration TB: one FP instruction per class through kronos_top.
//
// Program (boot at 0x0000):
//   lui  x1, 0x3F800   ; x1 = 0x3F800000 (1.0f bit-pattern)
//   lui  x2, 0x40000   ; x2 = 0x40000000 (2.0f bit-pattern)
//   fmv.w.x f1, x1     ; f1 = NaN-boxed 1.0f  (FMISC)
//   fmv.w.x f2, x2     ; f2 = NaN-boxed 2.0f  (FMISC)
//   fadd.s  f3, f1, f2 ; f3 = NaN-boxed 3.0f  (FADD)
//   lui  x5, 0x40000   ; x5 = 0x40000000 (halt sentinel)
//   sw   x10, 0(x5)    ; halt  (x10=0 → pass)
//
// Expected after halt: f3 == 64'hFFFFFFFF_40400000

`timescale 1ns/1ps
module tb_core_fp_basic;
  import kronos_pkg::*;

  // -----------------------------------------------------------------------
  // Memory: 256 B / 64 words, word-addressed. Code at 0x000.
  // -----------------------------------------------------------------------
  logic [31:0] mem [64];

  // -----------------------------------------------------------------------
  // Clock / reset
  // -----------------------------------------------------------------------
  logic clk  = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  kronos_axi_req_t  instr_req, data_req;
  kronos_axi_resp_t instr_rsp, data_rsp;
  logic             retire_mem_wen;
  logic [63:0]      retire_mem_addr;

  kronos_top u_top (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .instr_axi_req_o      (instr_req),
    .instr_axi_rsp_i      (instr_rsp),
    .data_axi_req_o       (data_req),
    .data_axi_rsp_i       (data_rsp),
    .irq_timer_i          (1'b0),
    .irq_fast_i           (15'd0),
    .irq_msi_i            (1'b0),
    .irq_mei_i            (1'b0),
    .irq_ssi_i            (1'b0),
    .irq_sti_i            (1'b0),
    .irq_sei_i            (1'b0),
    .boot_addr_i          (32'h0),
    .retire_valid_o       (),
    .retire_pc_o          (),
    .retire_instr_o       (),
    .retire_rd_wen_o      (),
    .retire_rd_o          (),
    .retire_rd_wdata_o    (),
    .retire_fp_wen_o      (),
    .retire_fp_rd_o       (),
    .retire_fp_wdata_o    (),
    .retire_mem_wen_o     (retire_mem_wen),
    .retire_mem_addr_o    (retire_mem_addr),
    .retire_mem_wdata_o   (),
    .retire_mem_funct3_o  (),
    .retire_csr_wen_o     (),
    .retire_csr_addr_o    (),
    .retire_csr_wdata_o   (),
    .retire_trap_taken_o  (),
    .retire_trap_cause_o  ()
  );

  // -----------------------------------------------------------------------
  // AXI slave — instruction port (multi-beat read, icache issues 8-beat bursts)
  // -----------------------------------------------------------------------
  logic        instr_r_pend;
  logic [63:0] instr_ar_addr_q;
  logic [7:0]  instr_ar_len_q;
  logic [7:0]  instr_r_beat;

  // TB memory-index helpers (promoted from `automatic` block-locals; see R2).
  int          instr_wi;
  int          data_r_wi;
  logic [63:0] data_w_beat_addr;
  int          data_w_wi_lo;
  int          data_w_wi_hi;

  // -----------------------------------------------------------------------
  // AXI slave — data port (multi-beat read + write, dcache issues 8-beat bursts)
  // -----------------------------------------------------------------------
  // Read channel
  logic        data_r_pend;
  logic [63:0] data_ar_addr_q;
  logic [7:0]  data_ar_len_q;
  logic [7:0]  data_r_beat;
  // Write channel
  logic        data_aw_pend;
  logic [63:0] data_aw_addr_q;
  logic [7:0]  data_aw_len_q;
  logic [7:0]  data_w_beat;
  logic        data_b_pend;
  logic [31:0] halted;

  // -----------------------------------------------------------------------
  // Test body
  // -----------------------------------------------------------------------
  int errors;

  always_comb begin
    instr_rsp          = '{default: '0};
    instr_rsp.ar_ready = ~instr_r_pend;
    instr_rsp.r_valid  = instr_r_pend;
    instr_wi           = int'(({25'b0, instr_ar_addr_q[9:3]} + {24'b0, instr_r_beat}) & 32'h3F) * 2;
    instr_rsp.r.data   = {mem[instr_wi+1], mem[instr_wi]};
    instr_rsp.r.last   = (instr_r_beat == instr_ar_len_q);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_r_pend    <= 1'b0;
      instr_ar_addr_q <= 64'h0;
      instr_ar_len_q  <= 8'h0;
      instr_r_beat    <= 8'h0;
    end else begin
      if (!instr_r_pend && instr_req.ar_valid) begin
        instr_ar_addr_q <= instr_req.ar.addr;
        instr_ar_len_q  <= instr_req.ar.len;
        instr_r_beat    <= 8'h0;
        instr_r_pend    <= 1'b1;
      end else if (instr_r_pend && instr_req.r_ready) begin
        if (instr_r_beat == instr_ar_len_q) begin
          instr_r_pend <= 1'b0;
          instr_r_beat    <= 8'h0;
        end else begin
          instr_r_beat <= instr_r_beat + 8'd1;
        end
      end
    end
  end

  always_comb begin
    data_rsp          = '{default: '0};
    data_rsp.ar_ready = ~data_r_pend;
    data_rsp.aw_ready = ~data_aw_pend;
    data_rsp.w_ready  = data_aw_pend;
    data_rsp.r_valid  = data_r_pend;
    data_rsp.r.last   = (data_r_beat == data_ar_len_q);
    data_rsp.b_valid  = data_b_pend;
    data_r_wi         = int'(({25'b0, data_ar_addr_q[9:3]} + {24'b0, data_r_beat}) & 32'h3F) * 2;
    data_rsp.r.data   = {mem[data_r_wi+1], mem[data_r_wi]};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_r_pend    <= 1'b0;
      data_ar_addr_q <= 64'h0;
      data_ar_len_q  <= 8'h0;
      data_r_beat    <= 8'h0;
      data_aw_pend   <= 1'b0;
      data_aw_addr_q <= 64'h0;
      data_aw_len_q  <= 8'h0;
      data_w_beat    <= 8'h0;
      data_b_pend    <= 1'b0;
    end else begin
      // ---- Read ----
      if (!data_r_pend && data_req.ar_valid) begin
        data_ar_addr_q <= data_req.ar.addr;
        data_ar_len_q  <= data_req.ar.len;
        data_r_beat    <= 8'h0;
        data_r_pend    <= 1'b1;
      end else if (data_r_pend && data_req.r_ready) begin
        if (data_r_beat == data_ar_len_q) begin
          data_r_pend <= 1'b0;
          data_r_beat    <= 8'h0;
        end else begin
          data_r_beat <= data_r_beat + 8'd1;
        end
      end

      // ---- Write AW ----
      if (!data_aw_pend && data_req.aw_valid) begin
        data_aw_addr_q <= data_req.aw.addr;
        data_aw_len_q  <= data_req.aw.len;
        data_w_beat    <= 8'h0;
        data_aw_pend   <= 1'b1;
      end

      // ---- Write W beats ----
      if (data_aw_pend && data_req.w_valid) begin
        // Compute beat-aligned word indices into the per-word backing store.
        // Promoted from `automatic` block-locals (R2); driven combinationally
        // for transparency at the use site.
        data_w_beat_addr = data_aw_addr_q + {56'b0, data_w_beat} * 8;
        data_w_wi_lo     = int'(data_w_beat_addr[9:3]) * 2;
        data_w_wi_hi     = data_w_wi_lo + 1;
        if (1'b0) begin
          // halt detection moved to retire_mem path
        end else begin
          if (data_req.w.strb[0]) mem[data_w_wi_lo][ 7: 0] <= data_req.w.data[ 7: 0];
          if (data_req.w.strb[1]) mem[data_w_wi_lo][15: 8] <= data_req.w.data[15: 8];
          if (data_req.w.strb[2]) mem[data_w_wi_lo][23:16] <= data_req.w.data[23:16];
          if (data_req.w.strb[3]) mem[data_w_wi_lo][31:24] <= data_req.w.data[31:24];
          if (data_req.w.strb[4]) mem[data_w_wi_hi][ 7: 0] <= data_req.w.data[39:32];
          if (data_req.w.strb[5]) mem[data_w_wi_hi][15: 8] <= data_req.w.data[47:40];
          if (data_req.w.strb[6]) mem[data_w_wi_hi][23:16] <= data_req.w.data[55:48];
          if (data_req.w.strb[7]) mem[data_w_wi_hi][31:24] <= data_req.w.data[63:56];
        end
        data_w_beat <= data_w_beat + 8'd1;
        if (data_req.w.last) begin
          data_aw_pend <= 1'b0;
          data_b_pend  <= 1'b1;
        end
      end

      // ---- B handshake ----
      if (data_b_pend && data_req.b_ready) begin
        data_b_pend <= 1'b0;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Halt detection via retire port (write to 0x4000_0000 region).
  // Using retire_mem_wen + retire_mem_addr avoids depending on dcache
  // write-back eviction timing.
  // -----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted <= 0;
    end else if (retire_mem_wen && (retire_mem_addr & 64'hC000_0000) == 64'h4000_0000) begin
      halted <= halted + 1;
    end
  end

  // -----------------------------------------------------------------------
  // Test body
  // -----------------------------------------------------------------------
  initial begin
    // Fill with NOP
    for (int i = 0; i < 64; i++) mem[i] = 32'h0000_0013; // ADDI x0, x0, 0

    // Instruction program (word indices = byte_addr/4)
    mem[0] = 32'h3F80_00B7; // lui  x1, 0x3F800   ; x1 = 1.0f bits
    mem[1] = 32'h4000_0137; // lui  x2, 0x40000   ; x2 = 2.0f bits
    mem[2] = 32'hF000_80D3; // fmv.w.x f1, x1
    mem[3] = 32'hF001_0153; // fmv.w.x f2, x2
    mem[4] = 32'h0020_81D3; // fadd.s  f3, f1, f2 ; f3 = 3.0f
    mem[5] = 32'h4000_02B7; // lui  x5, 0x40000   ; x5 = 0x40000000
    mem[6] = 32'h00A2_A023; // sw   x10, 0(x5)    ; halt

    errors = 0;

    // Reset
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;

    // Wait for halt (max 5000 cycles — dcache refills take ~10 cycles each)
    fork
      begin : wait_halt
        wait (halted > 0);
      end
      begin : timeout
        for (int i = 0; i < 5000; i++) @(posedge clk);
        $display("FAIL tb_core_fp_basic: timeout (no halt within 5000 cycles)");
        errors++;
        $finish(1);
      end
    join_any
    disable fork;

    // Allow one more cycle for any trailing writeback
    @(posedge clk);

    // Check: f3 should be NaN-boxed 3.0f = 0xFFFFFFFF_40400000
    if (u_top.u_regfile_fp.rf[3] !== 64'hFFFF_FFFF_4040_0000) begin
      $display("FAIL tb_core_fp_basic: f3 = %016h, expected FFFFFFFF40400000",
               u_top.u_regfile_fp.rf[3]);
      errors++;
    end else begin
      $display("PASS tb_core_fp_basic: f3 = %016h", u_top.u_regfile_fp.rf[3]);
    end

    $finish(errors != 0);
  end

endmodule
