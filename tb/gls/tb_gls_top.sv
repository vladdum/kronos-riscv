// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Gate-level simulation testbench top.
// Instantiates the post-synth/post-route Verilog netlist of kronos_top
// (DUT) and the SystemVerilog AXI memory model. Halt detection mirrors
// sim/sim_main.cpp: AW path (memory model halt_o) plus retire-trace path
// (covers dcache-deferred stores). The testbench is identical for funcsim
// and timesim modes — SDF is wired in via xelab, not the source.

`timescale 1ns/1ps

module tb_gls_top;

  // ── Plusarg-driven configuration ──────────────────────────────────────
  string  hex_path;
  longint max_cycles;
  string  vcd_path;
  int     instr_lat_arg;
  int     data_lat_arg;

  initial begin
    if (!$value$plusargs("HEX=%s", hex_path)) begin
      $display("[GLS] FATAL: +HEX=<path> required");
      $finish(1);
    end
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 5_000_000;
    if (!$value$plusargs("INSTR_LAT=%d",  instr_lat_arg)) instr_lat_arg = 1;
    if (!$value$plusargs("DATA_LAT=%d",   data_lat_arg))  data_lat_arg  = 1;
    if ($value$plusargs("VCD=%s", vcd_path)) begin
      $dumpfile(vcd_path);
      $dumpvars(0, tb_gls_top);
      $display("[GLS] VCD: %s", vcd_path);
    end
    $display("[GLS] HEX=%s MAX_CYCLES=%0d INSTR_LAT=%0d DATA_LAT=%0d",
             hex_path, max_cycles, instr_lat_arg, data_lat_arg);
  end

  // ── Clock & reset ─────────────────────────────────────────────────────
  logic clk;
  logic rst_n;
  initial begin
    clk = 1'b0;
    forever #2.5 clk = ~clk;        // 200 MHz, 5 ns period
  end
  initial begin
    rst_n = 1'b0;
    #100ns;
    @(posedge clk);
    rst_n <= 1'b1;
  end

  // ── DUT (netlist) AXI signals ─────────────────────────────────────────
  logic        instr_ar_valid;
  logic [63:0] instr_ar_addr;
  logic [ 7:0] instr_ar_len;
  logic [ 1:0] instr_ar_burst;
  logic        instr_ar_ready;
  logic        instr_r_valid;
  logic [63:0] instr_r_data;
  logic        instr_r_last;
  logic        instr_r_ready;

  logic        data_ar_valid;
  logic [63:0] data_ar_addr;
  logic [ 7:0] data_ar_len;
  logic [ 1:0] data_ar_burst;
  logic        data_ar_ready;
  logic        data_r_valid;
  logic [63:0] data_r_data;
  logic        data_r_last;
  logic        data_r_ready;

  logic        data_aw_valid;
  logic [63:0] data_aw_addr;
  logic [ 7:0] data_aw_len;
  logic [ 1:0] data_aw_burst;
  logic        data_aw_ready;
  logic        data_w_valid;
  logic [63:0] data_w_data;
  logic [ 7:0] data_w_strb;
  logic        data_w_last;
  logic        data_w_ready;
  logic        data_b_valid;
  logic [ 1:0] data_b_resp;
  logic        data_b_ready;

  // Retire-trace ports (preserved on the netlist boundary)
  logic        retire_valid;
  logic [63:0] retire_pc;
  logic [31:0] retire_instr;
  logic        retire_rd_wen;
  logic [ 4:0] retire_rd;
  logic [63:0] retire_rd_wdata;
  logic        retire_fp_wen;
  logic [ 4:0] retire_fp_rd;
  logic [63:0] retire_fp_wdata;
  logic        retire_mem_wen;
  logic [63:0] retire_mem_addr;
  logic [63:0] retire_mem_wdata;
  logic [ 2:0] retire_mem_funct3;
  logic        retire_csr_wen;
  logic [11:0] retire_csr_addr;
  logic [63:0] retire_csr_wdata;
  logic        retire_trap_taken;
  logic [31:0] retire_trap_cause;

  // ── DUT instance ──────────────────────────────────────────────────────
  // write_verilog -mode funcsim emits packed-struct ports as escaped
  // bracket-style identifiers, e.g. \instr_axi_req_o[ar][addr]. The
  // outer struct member uses [..._valid] / [..._ready] when it's a
  // handshake bit, and [aw][...] / [w][...] / [b][...] / [ar][...] /
  // [r][...] for the sub-struct fields. Unused DUT inputs (id, resp,
  // user side-bands and the instr-port write channel) are tied to '0
  // to avoid X-prop into the core.
  kronos_top dut (
    .clk_i  (clk),
    .rst_ni (rst_n),

    // Instruction read request (DUT outputs)
    .\instr_axi_req_o[ar_valid]  (instr_ar_valid),
    .\instr_axi_req_o[ar][addr]  (instr_ar_addr),
    .\instr_axi_req_o[ar][len]   (instr_ar_len),
    .\instr_axi_req_o[ar][burst] (instr_ar_burst),
    .\instr_axi_req_o[r_ready]   (instr_r_ready),
    // Instruction read response (DUT inputs)
    .\instr_axi_rsp_i[ar_ready]  (instr_ar_ready),
    .\instr_axi_rsp_i[r_valid]   (instr_r_valid),
    .\instr_axi_rsp_i[r][data]   (instr_r_data),
    .\instr_axi_rsp_i[r][last]   (instr_r_last),
    // Instruction-port write channel — DUT never issues writes here, tie low
    .\instr_axi_rsp_i[aw_ready]  (1'b0),
    .\instr_axi_rsp_i[w_ready]   (1'b0),
    .\instr_axi_rsp_i[b_valid]   (1'b0),
    .\instr_axi_rsp_i[b][id]     ('0),
    .\instr_axi_rsp_i[b][resp]   ('0),
    .\instr_axi_rsp_i[b][user]   ('0),
    .\instr_axi_rsp_i[r][id]     ('0),
    .\instr_axi_rsp_i[r][resp]   ('0),
    .\instr_axi_rsp_i[r][user]   ('0),

    // Data read request (DUT outputs)
    .\data_axi_req_o[ar_valid]   (data_ar_valid),
    .\data_axi_req_o[ar][addr]   (data_ar_addr),
    .\data_axi_req_o[ar][len]    (data_ar_len),
    .\data_axi_req_o[ar][burst]  (data_ar_burst),
    .\data_axi_req_o[r_ready]    (data_r_ready),
    // Data write request (DUT outputs)
    .\data_axi_req_o[aw_valid]   (data_aw_valid),
    .\data_axi_req_o[aw][addr]   (data_aw_addr),
    .\data_axi_req_o[aw][len]    (data_aw_len),
    .\data_axi_req_o[aw][burst]  (data_aw_burst),
    .\data_axi_req_o[w_valid]    (data_w_valid),
    .\data_axi_req_o[w][data]    (data_w_data),
    .\data_axi_req_o[w][strb]    (data_w_strb),
    .\data_axi_req_o[w][last]    (data_w_last),
    .\data_axi_req_o[b_ready]    (data_b_ready),
    // Data response (DUT inputs)
    .\data_axi_rsp_i[ar_ready]   (data_ar_ready),
    .\data_axi_rsp_i[r_valid]    (data_r_valid),
    .\data_axi_rsp_i[r][data]    (data_r_data),
    .\data_axi_rsp_i[r][last]    (data_r_last),
    .\data_axi_rsp_i[aw_ready]   (data_aw_ready),
    .\data_axi_rsp_i[w_ready]    (data_w_ready),
    .\data_axi_rsp_i[b_valid]    (data_b_valid),
    .\data_axi_rsp_i[b][resp]    (data_b_resp),
    // Side-band rsp fields not modeled — tie low
    .\data_axi_rsp_i[b][id]      ('0),
    .\data_axi_rsp_i[b][user]    ('0),
    .\data_axi_rsp_i[r][id]      ('0),
    .\data_axi_rsp_i[r][resp]    ('0),
    .\data_axi_rsp_i[r][user]    ('0),

    .irq_timer_i  (1'b0),
    .irq_fast_i   (15'b0),
    .boot_addr_i  (32'h0000_0000),

    .retire_valid_o      (retire_valid),
    .retire_pc_o         (retire_pc),
    .retire_instr_o      (retire_instr),
    .retire_rd_wen_o     (retire_rd_wen),
    .retire_rd_o         (retire_rd),
    .retire_rd_wdata_o   (retire_rd_wdata),
    .retire_fp_wen_o     (retire_fp_wen),
    .retire_fp_rd_o      (retire_fp_rd),
    .retire_fp_wdata_o   (retire_fp_wdata),
    .retire_mem_wen_o    (retire_mem_wen),
    .retire_mem_addr_o   (retire_mem_addr),
    .retire_mem_wdata_o  (retire_mem_wdata),
    .retire_mem_funct3_o (retire_mem_funct3),
    .retire_csr_wen_o    (retire_csr_wen),
    .retire_csr_addr_o   (retire_csr_addr),
    .retire_csr_wdata_o  (retire_csr_wdata),
    .retire_trap_taken_o (retire_trap_taken),
    .retire_trap_cause_o (retire_trap_cause)
  );

  // ── Memory model ──────────────────────────────────────────────────────
  string mem_hex_path;
  initial begin
    if (!$value$plusargs("HEX=%s", mem_hex_path)) mem_hex_path = "";
  end
  // Load the hex into the memory model after reset deasserts. The original
  // wait was @(negedge rst_n) — but rst_n starts at 0 and only transitions
  // 0→1, so that edge never fires and the hex was never loaded.
  initial begin
    @(posedge rst_n);
    if (mem_hex_path != "") begin
      $readmemh(mem_hex_path, u_mem.mem);
      $display("[GLS] loaded %s into memory", mem_hex_path);
    end
  end

  logic        halt_axi;
  logic [31:0] halt_code_axi;

  axi_mem_model #(
    .MEM_WORDS (524288),
    .INSTR_LAT (1),
    .DATA_LAT  (1)
  ) u_mem (
    .clk_i  (clk),
    .rst_ni (rst_n),

    .instr_ar_valid_i (instr_ar_valid),
    .instr_ar_addr_i  (instr_ar_addr),
    .instr_ar_len_i   (instr_ar_len),
    .instr_ar_burst_i (instr_ar_burst),
    .instr_ar_ready_o (instr_ar_ready),
    .instr_r_valid_o  (instr_r_valid),
    .instr_r_data_o   (instr_r_data),
    .instr_r_last_o   (instr_r_last),
    .instr_r_ready_i  (instr_r_ready),

    .data_ar_valid_i  (data_ar_valid),
    .data_ar_addr_i   (data_ar_addr),
    .data_ar_len_i    (data_ar_len),
    .data_ar_burst_i  (data_ar_burst),
    .data_ar_ready_o  (data_ar_ready),
    .data_r_valid_o   (data_r_valid),
    .data_r_data_o    (data_r_data),
    .data_r_last_o    (data_r_last),
    .data_r_ready_i   (data_r_ready),

    .data_aw_valid_i  (data_aw_valid),
    .data_aw_addr_i   (data_aw_addr),
    .data_aw_len_i    (data_aw_len),
    .data_aw_burst_i  (data_aw_burst),
    .data_aw_ready_o  (data_aw_ready),
    .data_w_valid_i   (data_w_valid),
    .data_w_data_i    (data_w_data),
    .data_w_strb_i    (data_w_strb),
    .data_w_last_i    (data_w_last),
    .data_w_ready_o   (data_w_ready),
    .data_b_valid_o   (data_b_valid),
    .data_b_resp_o    (data_b_resp),
    .data_b_ready_i   (data_b_ready),

    .halt_o      (halt_axi),
    .halt_code_o (halt_code_axi)
  );

  // ── Halt detection — dual mechanism (mirrors sim_main.cpp) ────────────
  logic        halt_retire;
  logic [31:0] halt_code_retire;
  logic        halted;
  logic [31:0] halt_code;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halt_retire      <= 1'b0;
      halt_code_retire <= 32'h0;
    end else if (!halt_retire && retire_mem_wen &&
                 ((retire_mem_addr[31:0] & 32'hC000_0000) == 32'h4000_0000)) begin
      halt_retire      <= 1'b1;
      halt_code_retire <= retire_mem_wdata[31:0];
    end
  end

  assign halted    = halt_axi | halt_retire;
  assign halt_code = halt_axi ? halt_code_axi : halt_code_retire;

  // ── Retire ring buffer (16 deep) ──────────────────────────────────────
  localparam int RING_DEPTH = 16;
  logic [63:0] ring_pc    [RING_DEPTH];
  logic [31:0] ring_instr [RING_DEPTH];
  // Declaration-init avoids xelab's "multiple procedural drivers" error
  // that fires when an `initial` block + an `always_ff` both write the var.
  int          ring_wp = 0;

  always_ff @(posedge clk) begin
    if (rst_n && retire_valid) begin
      ring_pc   [ring_wp] <= retire_pc;
      ring_instr[ring_wp] <= retire_instr;
      ring_wp             <= (ring_wp + 1) % RING_DEPTH;
    end
  end

  // ── Cycle counter, timeout, finish ────────────────────────────────────
  longint cycle = 0;
  always_ff @(posedge clk) cycle <= cycle + 1;

  task automatic dump_ring();
    int idx;
    $display("[GLS] last %0d retired:", RING_DEPTH);
    for (int i = 0; i < RING_DEPTH; i++) begin
      idx = (ring_wp + i) % RING_DEPTH;
      $display("  pc=%016h  instr=%08h", ring_pc[idx], ring_instr[idx]);
    end
  endtask

  // Plain `always` (not `always_ff`) so the post-halt drain delay is legal.
  always @(posedge clk) begin
    if (rst_n && halted) begin
      #20ns;
      if (halt_code == 32'h0) begin
        $display("[GLS] PASS at cycle %0d, halt_code=%0d", cycle, halt_code);
        $finish(0);
      end else begin
        $display("[GLS] FAIL at cycle %0d, halt_code=%0d", cycle, halt_code);
        dump_ring();
        $finish(1);
      end
    end else if (cycle >= max_cycles) begin
      $display("[GLS] TIMEOUT at cycle %0d, last retire pc=%016h",
               cycle, ring_pc[(ring_wp - 1 + RING_DEPTH) % RING_DEPTH]);
      dump_ring();
      $finish(1);
    end
  end

  // ── X-propagation guards ──────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if ($isunknown(instr_ar_valid) || $isunknown(instr_ar_ready) ||
          $isunknown(data_ar_valid)  || $isunknown(data_ar_ready)  ||
          $isunknown(data_aw_valid)  || $isunknown(data_aw_ready)  ||
          $isunknown(data_w_valid)   || $isunknown(data_w_ready)   ||
          $isunknown(data_b_valid)   || $isunknown(data_b_ready)) begin
        $display("[GLS] X-PROP at cycle %0d on AXI handshake signal", cycle);
        dump_ring();
        $finish(1);
      end
    end
  end

endmodule
