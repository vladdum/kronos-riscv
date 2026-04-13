// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_lsu.sv (stage1) — load/store unit with two-state OBI FSM
// Adds mem_stall_o so the pipeline can stall when rvalid is delayed.
module kronos_lsu (
  input  logic        clk_i,
  input  logic        rst_ni,
  // Pipeline interface
  input  logic        req_i,
  input  logic        we_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic [2:0]  funct3_i,
  output logic [31:0] rdata_o,
  output logic        valid_o,
  output logic        mem_stall_o,
  // OBI data port
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [ 3:0] data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i
);

  // -------------------------------------------------------------------------
  // OBI FSM
  // -------------------------------------------------------------------------
  typedef enum logic { IDLE = 1'b0, WAIT_RVALID = 1'b1 } lsu_state_e;
  lsu_state_e state_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= IDLE;
    else unique case (state_q)
      IDLE:        if (req_i && data_gnt_i && !data_rvalid_i) state_q <= WAIT_RVALID;
      WAIT_RVALID: if (data_rvalid_i)                         state_q <= IDLE;
      default:     state_q <= IDLE;
    endcase
  end

  assign valid_o     = (state_q == IDLE       && req_i && data_gnt_i && data_rvalid_i) ||
                       (state_q == WAIT_RVALID && data_rvalid_i);
  assign mem_stall_o = req_i && !valid_o;

  // -------------------------------------------------------------------------
  // Byte offset and read-data extraction (identical to stage0)
  // -------------------------------------------------------------------------
  logic [1:0]  byte_off;
  logic [31:0] rdata_shifted;
  logic [7:0]  raw_byte;
  logic [15:0] raw_half;

  assign byte_off      = addr_i[1:0];
  assign rdata_shifted = data_rdata_i >> ({3'b0, byte_off} * 4'd8);
  assign raw_byte      = rdata_shifted[7:0];
  assign raw_half      = rdata_shifted[15:0];

  // Byte-enable generation
  always_comb begin
    data_be_o = 4'b1111;
    unique case (funct3_i[1:0])
      2'b00:   data_be_o = 4'b0001 << byte_off; // byte
      2'b01:   data_be_o = 4'b0011 << byte_off; // halfword
      2'b10:   data_be_o = 4'b1111;             // word
      default: data_be_o = 4'b1111;
    endcase
  end

  // Store data replicated to fill word lanes
  always_comb begin
    data_wdata_o = wdata_i;
    unique case (funct3_i[1:0])
      2'b00:   data_wdata_o = {4{wdata_i[7:0]}};
      2'b01:   data_wdata_o = {2{wdata_i[15:0]}};
      2'b10:   data_wdata_o = wdata_i;
      default: data_wdata_o = wdata_i;
    endcase
  end

  // Load data extraction and sign extension
  always_comb begin
    rdata_o = data_rdata_i;
    unique case (funct3_i)
      3'b000:  rdata_o = {{24{raw_byte[7]}}, raw_byte};  // LB  signed
      3'b001:  rdata_o = {{16{raw_half[15]}}, raw_half}; // LH  signed
      3'b010:  rdata_o = data_rdata_i;                   // LW
      3'b100:  rdata_o = {24'b0, raw_byte};              // LBU unsigned
      3'b101:  rdata_o = {16'b0, raw_half};              // LHU unsigned
      default: rdata_o = data_rdata_i;
    endcase
  end

  assign data_req_o  = req_i;
  assign data_we_o   = we_i;
  assign data_addr_o = {addr_i[31:2], 2'b00}; // word-aligned

endmodule
