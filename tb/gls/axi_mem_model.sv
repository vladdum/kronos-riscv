// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// AXI4 slave memory model for gate-level simulation.
// Semantic peer of sim/sim_main.cpp — single-outstanding per port,
// configurable read latency, INCR + WRAP burst support, halt-on-store to
// the 0x4000_0000–0x7FFF_FFFF sentinel region, console writes silently
// absorbed at 0x1000_0000.
//
// WRAP burst semantics (icache + dcache cache-line refills): the address
// advances modulo (len+1)*8 bytes within the line, so beats following the
// line boundary wrap back to the start of the same line. Without this,
// wrapped beats return data from the next sequential line — corrupting
// the cache and causing post-mret instruction fetches to return data from
// the wrong line (issue #57).

module axi_mem_model #(
  parameter int unsigned MEM_WORDS        = 524288,        // 2 MiB
  parameter int unsigned INSTR_LAT        = 1,
  parameter int unsigned DATA_LAT         = 1,
  parameter logic [31:0] HALT_REGION_BASE = 32'h4000_0000,
  parameter logic [31:0] HALT_REGION_MASK = 32'hC000_0000,
  parameter logic [31:0] CONSOLE_ADDR     = 32'h1000_0000,
  parameter string       HEX_FILE         = ""
) (
  input  logic clk_i,
  input  logic rst_ni,

  // ── Instruction read port ────────────────────────────────────────────
  input  logic        instr_ar_valid_i,
  input  logic [63:0] instr_ar_addr_i,
  input  logic [ 7:0] instr_ar_len_i,
  input  logic [ 1:0] instr_ar_burst_i,
  output logic        instr_ar_ready_o,
  output logic        instr_r_valid_o,
  output logic [63:0] instr_r_data_o,
  output logic        instr_r_last_o,
  input  logic        instr_r_ready_i,

  // ── Data read port ───────────────────────────────────────────────────
  input  logic        data_ar_valid_i,
  input  logic [63:0] data_ar_addr_i,
  input  logic [ 7:0] data_ar_len_i,
  input  logic [ 1:0] data_ar_burst_i,
  output logic        data_ar_ready_o,
  output logic        data_r_valid_o,
  output logic [63:0] data_r_data_o,
  output logic        data_r_last_o,
  input  logic        data_r_ready_i,

  // ── Data write port ──────────────────────────────────────────────────
  input  logic        data_aw_valid_i,
  input  logic [63:0] data_aw_addr_i,
  input  logic [ 7:0] data_aw_len_i,
  input  logic [ 1:0] data_aw_burst_i,
  output logic        data_aw_ready_o,
  input  logic        data_w_valid_i,
  input  logic [63:0] data_w_data_i,
  input  logic [ 7:0] data_w_strb_i,
  input  logic        data_w_last_i,
  output logic        data_w_ready_o,
  output logic        data_b_valid_o,
  output logic [ 1:0] data_b_resp_o,
  input  logic        data_b_ready_i,

  // ── Halt detection ───────────────────────────────────────────────────
  output logic        halt_o,
  output logic [31:0] halt_code_o
);

  // 19-bit word index for a 524288-word backing store.
  localparam int unsigned WI_W = $clog2(MEM_WORDS);  // 19

  logic [31:0] mem [0:MEM_WORDS-1];

  initial begin
    foreach (mem[i]) mem[i] = 32'h0;
    if (HEX_FILE != "") $readmemh(HEX_FILE, mem);
  end

  // Compute the byte address of beat `beat` within burst:
  //   - INCR (0x1): base + beat*8
  //   - WRAP (0x2): wrap within (len+1)*8-byte boundary
  //   - FIXED (0x0) and unknown: treat as INCR
  // beat_addr is a full 64-bit AXI address (we only use the low bits).
  function automatic logic [63:0] beat_addr(
    input logic [63:0] base,
    input logic [ 7:0] len,
    input logic [ 1:0] burst,
    input logic [ 7:0] beat
  );
    logic [63:0] line_size;
    logic [63:0] line_mask;
    logic [63:0] line_base;
    logic [63:0] off;
    line_size = (64'(len) + 64'd1) * 64'd8;
    line_mask = line_size - 64'd1;
    line_base = base & ~line_mask;
    off       = ((base & line_mask) + (64'(beat) * 64'd8)) & line_mask;
    if (burst == 2'b10) begin
      return line_base | off;
    end else begin
      return base + (64'(beat) * 64'd8);
    end
  endfunction

  // ── Instruction read state ───────────────────────────────────────────
  logic            i_pending_q;
  logic [63:0]     i_base_q;
  logic [ 7:0]     i_len_q;
  logic [ 1:0]     i_burst_q;
  logic [ 7:0]     i_beat_q;
  logic [31:0]     i_lat_q;

  logic [63:0]     i_addr;
  logic [WI_W-1:0] i_word_lo;
  logic [WI_W-1:0] i_word_hi;
  assign i_addr    = beat_addr(i_base_q, i_len_q, i_burst_q, i_beat_q);
  assign i_word_lo = i_addr[WI_W+1:2];
  assign i_word_hi = i_word_lo + 1;

  assign instr_ar_ready_o = !i_pending_q;
  assign instr_r_valid_o  = i_pending_q && (i_lat_q == 32'd0);
  assign instr_r_data_o   = {mem[i_word_hi], mem[i_word_lo]};
  assign instr_r_last_o   = i_pending_q && (i_beat_q == i_len_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      i_pending_q <= 1'b0;
      i_base_q    <= 64'h0;
      i_len_q     <= 8'h0;
      i_burst_q   <= 2'b00;
      i_beat_q    <= 8'h0;
      i_lat_q     <= 32'h0;
    end else begin
      if (instr_ar_valid_i && instr_ar_ready_o) begin
        i_pending_q <= 1'b1;
        i_base_q    <= instr_ar_addr_i;
        i_len_q     <= instr_ar_len_i;
        i_burst_q   <= instr_ar_burst_i;
        i_beat_q    <= 8'h0;
        i_lat_q     <= 32'(INSTR_LAT);
      end else if (i_pending_q && (i_lat_q != 32'd0)) begin
        i_lat_q <= i_lat_q - 32'd1;
      end
      if (instr_r_valid_o && instr_r_ready_i) begin
        if (i_beat_q == i_len_q) begin
          i_pending_q <= 1'b0;
          i_beat_q    <= 8'h0;
        end else begin
          i_beat_q <= i_beat_q + 8'h1;
          i_lat_q  <= 32'h0;   // back-to-back beats once first arrives
        end
      end
    end
  end

  // ── Data read state ──────────────────────────────────────────────────
  logic            d_pending_q;
  logic [63:0]     d_base_q;
  logic [ 7:0]     d_len_q;
  logic [ 1:0]     d_burst_q;
  logic [ 7:0]     d_beat_q;
  logic [31:0]     d_lat_q;

  logic [63:0]     d_addr;
  logic [WI_W-1:0] d_word_lo;
  logic [WI_W-1:0] d_word_hi;
  assign d_addr    = beat_addr(d_base_q, d_len_q, d_burst_q, d_beat_q);
  assign d_word_lo = d_addr[WI_W+1:2];
  assign d_word_hi = d_word_lo + 1;

  assign data_ar_ready_o = !d_pending_q;
  assign data_r_valid_o  = d_pending_q && (d_lat_q == 32'd0);
  assign data_r_data_o   = {mem[d_word_hi], mem[d_word_lo]};
  assign data_r_last_o   = d_pending_q && (d_beat_q == d_len_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d_pending_q <= 1'b0;
      d_base_q    <= 64'h0;
      d_len_q     <= 8'h0;
      d_burst_q   <= 2'b00;
      d_beat_q    <= 8'h0;
      d_lat_q     <= 32'h0;
    end else begin
      if (data_ar_valid_i && data_ar_ready_o) begin
        d_pending_q <= 1'b1;
        d_base_q    <= data_ar_addr_i;
        d_len_q     <= data_ar_len_i;
        d_burst_q   <= data_ar_burst_i;
        d_beat_q    <= 8'h0;
        d_lat_q     <= 32'(DATA_LAT);
      end else if (d_pending_q && (d_lat_q != 32'd0)) begin
        d_lat_q <= d_lat_q - 32'd1;
      end
      if (data_r_valid_o && data_r_ready_i) begin
        if (d_beat_q == d_len_q) begin
          d_pending_q <= 1'b0;
          d_beat_q    <= 8'h0;
        end else begin
          d_beat_q <= d_beat_q + 8'h1;
          d_lat_q  <= 32'h0;
        end
      end
    end
  end

  // ── Data write state ─────────────────────────────────────────────────
  logic            d_aw_done_q;
  logic            d_b_pending_q;
  logic [63:0]     d_w_base_q;
  logic [ 7:0]     d_w_beat_q;
  logic            halt_q;
  logic [31:0]     halt_code_q;

  assign data_aw_ready_o = !d_aw_done_q;
  assign data_w_ready_o  = d_aw_done_q;
  assign data_b_valid_o  = d_b_pending_q;
  assign data_b_resp_o   = 2'b00;
  assign halt_o          = halt_q;
  assign halt_code_o     = halt_code_q;

  // Per-byte strobe → 32-bit lane mask
  function automatic logic [31:0] strb_mask_lo(input logic [7:0] strb);
    return {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
  endfunction
  function automatic logic [31:0] strb_mask_hi(input logic [7:0] strb);
    return {{8{strb[7]}}, {8{strb[6]}}, {8{strb[5]}}, {8{strb[4]}}};
  endfunction

  logic [63:0]     waddr_c;
  logic [31:0]     waddr32_c;
  logic [WI_W-1:0] w_lo_c;
  logic [WI_W-1:0] w_hi_c;
  logic [31:0]     wmask_lo_c;
  logic [31:0]     wmask_hi_c;
  always_comb begin
    waddr_c    = d_w_base_q + (64'(d_w_beat_q) << 3);
    waddr32_c  = waddr_c[31:0];
    w_lo_c     = waddr_c[WI_W+1:2];
    w_hi_c     = w_lo_c + 1;
    wmask_lo_c = strb_mask_lo(data_w_strb_i);
    wmask_hi_c = strb_mask_hi(data_w_strb_i);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d_aw_done_q   <= 1'b0;
      d_b_pending_q <= 1'b0;
      d_w_base_q    <= 64'h0;
      d_w_beat_q    <= 8'h0;
      halt_q        <= 1'b0;
      halt_code_q   <= 32'h0;
    end else begin
      // AW handshake
      if (data_aw_valid_i && data_aw_ready_o) begin
        d_w_base_q  <= data_aw_addr_i;
        d_w_beat_q  <= 8'h0;
        d_aw_done_q <= 1'b1;
      end
      // W handshake
      if (d_aw_done_q && data_w_valid_i && data_w_ready_o) begin
        if ((waddr32_c & HALT_REGION_MASK) == HALT_REGION_BASE) begin
          if (!halt_q) begin
            halt_q      <= 1'b1;
            halt_code_q <= data_w_data_i[31:0];
          end
        end else if (waddr32_c == CONSOLE_ADDR) begin
          // Console — silently absorbed
        end else begin
          mem[w_lo_c] <= (mem[w_lo_c] & ~wmask_lo_c)
                        | (data_w_data_i[31: 0] & wmask_lo_c);
          mem[w_hi_c] <= (mem[w_hi_c] & ~wmask_hi_c)
                        | (data_w_data_i[63:32] & wmask_hi_c);
        end
        d_w_beat_q <= d_w_beat_q + 8'h1;
        if (data_w_last_i) begin
          d_aw_done_q   <= 1'b0;
          d_b_pending_q <= 1'b1;
        end
      end
      // B handshake
      if (d_b_pending_q && data_b_ready_i) begin
        d_b_pending_q <= 1'b0;
      end
    end
  end

endmodule
