// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_lsu.sv (stage3) — load/store unit with AXI4 master FSM.
// Replaces the stage1 OBI FSM with a 7-state AXI4 FSM.
// Pipeline interface is unchanged (req/we/addr/wdata/funct3/rdata/valid/mem_stall).
module kronos_lsu
  import kronos_pkg::*;
(
  input  logic             clk_i,
  input  logic             rst_ni,
  // Pipeline interface
  input  logic             req_i,
  input  logic             we_i,
  input  logic [31:0]      addr_i,
  input  logic [31:0]      wdata_i,
  input  logic [2:0]       funct3_i,
  output logic [31:0]      rdata_o,
  output logic             valid_o,
  output logic             mem_stall_o,
  // AXI4 data port
  output kronos_axi_req_t  axi_req_o,
  input  kronos_axi_resp_t axi_rsp_i
);

  // -------------------------------------------------------------------------
  // FSM state
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE       = 3'd0,
    LOAD_ADDR  = 3'd1,
    LOAD_DATA  = 3'd2,
    LOAD_DONE  = 3'd3,
    STORE_SEND = 3'd4,
    STORE_RESP = 3'd5,
    STORE_DONE = 3'd6
  } lsu_state_e;

  lsu_state_e state_q;

  // -------------------------------------------------------------------------
  // Registered operands (captured at IDLE→non-IDLE transition)
  // -------------------------------------------------------------------------
  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic [2:0]  funct3_q;
  logic [31:0] rdata_q;
  logic        aw_acked_q;
  logic        w_acked_q;

  // -------------------------------------------------------------------------
  // Byte-enable and store-data replication
  // -------------------------------------------------------------------------
  logic [ 3:0] be;
  logic [31:0] wdata_rep;

  always_comb begin
    be = 4'b1111;
    unique case (funct3_q[1:0])
      2'b00:   be = 4'b0001 << addr_q[1:0];
      2'b01:   be = 4'b0011 << addr_q[1:0];
      2'b10:   be = 4'b1111;
      default: be = 4'b1111;
    endcase
  end

  always_comb begin
    wdata_rep = wdata_q;
    unique case (funct3_q[1:0])
      2'b00:   wdata_rep = {4{wdata_q[7:0]}};
      2'b01:   wdata_rep = {2{wdata_q[15:0]}};
      2'b10:   wdata_rep = wdata_q;
      default: wdata_rep = wdata_q;
    endcase
  end

  // -------------------------------------------------------------------------
  // Load-data extraction and sign extension
  // -------------------------------------------------------------------------
  logic [1:0]  byte_off;
  logic [31:0] rdata_shifted;
  logic [7:0]  raw_byte;
  logic [15:0] raw_half;

  assign byte_off      = addr_q[1:0];
  assign rdata_shifted = rdata_q >> ({3'b0, byte_off} * 4'd8);
  assign raw_byte      = rdata_shifted[7:0];
  assign raw_half      = rdata_shifted[15:0];

  always_comb begin
    rdata_o = rdata_q;
    unique case (funct3_q)
      3'b000:  rdata_o = {{24{raw_byte[7]}},  raw_byte};
      3'b001:  rdata_o = {{16{raw_half[15]}}, raw_half};
      3'b010:  rdata_o = rdata_q;
      3'b100:  rdata_o = {24'b0, raw_byte};
      3'b101:  rdata_o = {16'b0, raw_half};
      default: rdata_o = rdata_q;
    endcase
  end

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= IDLE;
      addr_q     <= '0;
      wdata_q    <= '0;
      funct3_q   <= '0;
      rdata_q    <= '0;
      aw_acked_q <= 1'b0;
      w_acked_q  <= 1'b0;
    end else begin
      unique case (state_q)

        IDLE: begin
          if (req_i) begin
            addr_q   <= addr_i;
            wdata_q  <= wdata_i;
            funct3_q <= funct3_i;
            if (we_i) begin
              state_q    <= STORE_SEND;
              aw_acked_q <= 1'b0;
              w_acked_q  <= 1'b0;
            end else begin
              state_q <= LOAD_ADDR;
            end
          end
        end

        LOAD_ADDR: begin
          if (axi_rsp_i.ar_ready) state_q <= LOAD_DATA;
        end

        LOAD_DATA: begin
          if (axi_rsp_i.r_valid) begin
            rdata_q <= axi_rsp_i.r.data;
            state_q <= LOAD_DONE;
          end
        end

        LOAD_DONE: begin
          state_q <= IDLE;  // unconditional — valid_o is a 1-cycle pulse
        end

        STORE_SEND: begin
          if (axi_rsp_i.aw_ready) aw_acked_q <= 1'b1;
          if (axi_rsp_i.w_ready)  w_acked_q  <= 1'b1;
          if ((aw_acked_q | axi_rsp_i.aw_ready) &
              (w_acked_q  | axi_rsp_i.w_ready)) begin
            state_q    <= STORE_RESP;
            aw_acked_q <= 1'b0;
            w_acked_q  <= 1'b0;
          end
        end

        STORE_RESP: begin
          if (axi_rsp_i.b_valid) state_q <= STORE_DONE;
        end

        STORE_DONE: begin
          state_q <= IDLE;  // unconditional — valid_o is a 1-cycle pulse
        end

        default: state_q <= IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // AXI4 request outputs
  // -------------------------------------------------------------------------
  always_comb begin
    axi_req_o = '0;
    unique case (state_q)
      LOAD_ADDR: begin
        axi_req_o.ar_valid = 1'b1;
        axi_req_o.ar.addr  = {addr_q[31:2], 2'b00};
        axi_req_o.ar.size  = 3'b010;
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      end
      LOAD_DATA: begin
        axi_req_o.r_ready  = 1'b1;
      end
      STORE_SEND: begin
        axi_req_o.aw_valid = ~aw_acked_q;
        axi_req_o.aw.addr  = {addr_q[31:2], 2'b00};
        axi_req_o.aw.size  = 3'b010;
        axi_req_o.aw.burst = axi_pkg::BURST_INCR;
        axi_req_o.w_valid  = ~w_acked_q;
        axi_req_o.w.data   = wdata_rep;
        axi_req_o.w.strb   = be;
        axi_req_o.w.last   = 1'b1;
      end
      STORE_RESP: begin
        axi_req_o.b_ready  = 1'b1;
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Pipeline stall and valid
  // -------------------------------------------------------------------------
  assign mem_stall_o = req_i & (state_q != LOAD_DONE) & (state_q != STORE_DONE);
  assign valid_o     = (state_q == LOAD_DONE) | (state_q == STORE_DONE);

endmodule
