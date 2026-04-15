// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// kronos_lsu.sv (stage5) — 64-bit load/store unit with AXI4 master FSM.
// Widens the stage3 32-bit LSU to support LD/SD/LWU using two 32-bit AXI
// beats for the doubleword cases. Sub-word loads/stores (B/H/W) reuse the
// stage3 byte-enable / replication / address-low-bit mux logic unchanged.
//
// A-extension ports (LR/SC/AMO) are accepted but inert in this stage.
// `sc_success_o` is tied to 0 so downstream logic sees a consistent value
// until Tasks 12 and 13 wire up the real behaviour.
module kronos_lsu
  import kronos_pkg::*;
(
  input  logic             clk_i,
  input  logic             rst_ni,
  // Pipeline interface (64-bit data)
  input  logic             req_i,
  input  logic             we_i,
  input  logic [31:0]      addr_i,
  input  logic [63:0]      wdata_i,
  input  logic [2:0]       funct3_i,
  output logic [63:0]      rdata_o,
  output logic             valid_o,
  output logic             mem_stall_o,
  // FP load/store extensions (Stage 5)
  input  logic             fp_dest_req_i,    // this is a FP load/store
  input  logic [63:0]      fp_store_data_i,  // FP register data for FSW/FSD
  output logic             fp_dest_rsp_o,    // load response targets FP regfile
  output logic [63:0]      fp_rdata_o,       // NaN-boxed FP load data
  // A-extension (stubs for Tasks 12-13)
  input  logic             is_lr_i,
  input  logic             is_sc_i,
  input  logic             is_amo_i,
  input  logic [4:0]       amo_funct5_i,
  input  logic [63:0]      amo_src_i,
  output logic             sc_success_o,
  // AXI4 master
  output kronos_axi_req_t  axi_req_o,
  input  kronos_axi_resp_t axi_rsp_i
);

  // -------------------------------------------------------------------------
  // FSM state (widened to 4 bits to reserve room for AMO/SC_FAIL states)
  // -------------------------------------------------------------------------
  typedef enum logic [3:0] {
    IDLE          = 4'd0,
    LOAD_ADDR     = 4'd1,
    LOAD_DATA     = 4'd2,
    LOAD_DONE     = 4'd3,
    STORE_SEND    = 4'd4,
    STORE_RESP    = 4'd5,
    STORE_DONE    = 4'd6,
    LOAD_ADDR_HI  = 4'd7,
    LOAD_DATA_HI  = 4'd8,
    STORE_SEND_HI = 4'd9,
    STORE_RESP_HI = 4'd10,
    AMO_COMPUTE   = 4'd11,  // reserved for Task 13 (AMO)
    SC_FAIL       = 4'd12   // reserved for Task 12 (SC failure)
  } lsu_state_e;

  lsu_state_e state_q;

  // -------------------------------------------------------------------------
  // Registered operands (captured at IDLE→non-IDLE transition)
  // -------------------------------------------------------------------------
  logic [31:0] addr_q;
  logic [63:0] wdata_q;
  logic [2:0]  funct3_q;
  logic [31:0] rdata_q;
  logic [31:0] rdata_hi_q;
  logic        is_dword_q;
  logic        fp_dest_q;
  logic        aw_acked_q;
  logic        w_acked_q;
  logic        is_lr_q;
  logic        is_sc_q;
  logic        is_amo_q;
  logic [4:0]  amo_funct5_q;
  logic [63:0] amo_src_q;
  logic        reservation_valid_q;
  logic [31:0] reservation_addr_q;
  logic        sc_result_q;  // 0 = success, 1 = fail; presented in rdata_o on SC

  // -------------------------------------------------------------------------
  // Byte-enable and store-data replication (sub-word stores reuse stage3
  // logic unchanged; for SD each 32-bit beat uses strb=1111 and the raw
  // upper/lower half of wdata_q).
  // -------------------------------------------------------------------------
  logic [ 3:0] be;
  logic [31:0] wdata_rep;

  always_comb begin
    be = 4'b1111;
    unique case (funct3_q[1:0])
      2'b00:   be = 4'b0001 << addr_q[1:0];
      2'b01:   be = 4'b0011 << addr_q[1:0];
      2'b10:   be = 4'b1111;
      2'b11:   be = 4'b1111;  // SD: both beats cover a full word
      default: be = 4'b1111;
    endcase
  end

  always_comb begin
    wdata_rep = wdata_q[31:0];
    unique case (funct3_q[1:0])
      2'b00:   wdata_rep = {4{wdata_q[7:0]}};
      2'b01:   wdata_rep = {2{wdata_q[15:0]}};
      2'b10:   wdata_rep = wdata_q[31:0];
      2'b11:   wdata_rep = wdata_q[31:0];  // SD low beat
      default: wdata_rep = wdata_q[31:0];
    endcase
  end

  // -------------------------------------------------------------------------
  // AMO compute: given the loaded value (rdata_q / rdata_hi_q) and the
  // register-file source (amo_src_q), produce the value to be written back.
  // Word vs doubleword is selected from funct3_q (W=010, D=011).
  // -------------------------------------------------------------------------
  logic        amo_is_word;
  logic [63:0] amo_new_val;
  logic [31:0] amo_a32;
  logic [31:0] amo_b32;
  logic [31:0] amo_r32;
  logic [63:0] amo_a64;
  logic [63:0] amo_b64;

  assign amo_is_word = (funct3_q[1:0] == 2'b10);
  assign amo_a32     = rdata_q;
  assign amo_b32     = amo_src_q[31:0];
  assign amo_a64     = {rdata_hi_q, rdata_q};
  assign amo_b64     = amo_src_q;

  always_comb begin
    amo_r32 = '0;
    unique case (amo_funct5_q)
      5'b00001: amo_r32 = amo_b32;                                              // AMOSWAP
      5'b00000: amo_r32 = amo_a32 + amo_b32;                                    // AMOADD
      5'b00100: amo_r32 = amo_a32 ^ amo_b32;                                    // AMOXOR
      5'b01100: amo_r32 = amo_a32 & amo_b32;                                    // AMOAND
      5'b01000: amo_r32 = amo_a32 | amo_b32;                                    // AMOOR
      5'b10000: amo_r32 = ($signed(amo_a32) <  $signed(amo_b32)) ? amo_a32
                                                                 : amo_b32;     // AMOMIN
      5'b10100: amo_r32 = ($signed(amo_a32) >= $signed(amo_b32)) ? amo_a32
                                                                 : amo_b32;     // AMOMAX
      5'b11000: amo_r32 = (amo_a32 <  amo_b32) ? amo_a32 : amo_b32;             // AMOMINU
      5'b11100: amo_r32 = (amo_a32 >= amo_b32) ? amo_a32 : amo_b32;             // AMOMAXU
      default:  amo_r32 = '0;
    endcase
  end

  always_comb begin
    amo_new_val = '0;
    if (amo_is_word) begin
      amo_new_val = {32'b0, amo_r32};
    end else begin
      unique case (amo_funct5_q)
        5'b00001: amo_new_val = amo_b64;
        5'b00000: amo_new_val = amo_a64 + amo_b64;
        5'b00100: amo_new_val = amo_a64 ^ amo_b64;
        5'b01100: amo_new_val = amo_a64 & amo_b64;
        5'b01000: amo_new_val = amo_a64 | amo_b64;
        5'b10000: amo_new_val = ($signed(amo_a64) <  $signed(amo_b64)) ? amo_a64
                                                                       : amo_b64;
        5'b10100: amo_new_val = ($signed(amo_a64) >= $signed(amo_b64)) ? amo_a64
                                                                       : amo_b64;
        5'b11000: amo_new_val = (amo_a64 <  amo_b64) ? amo_a64 : amo_b64;
        5'b11100: amo_new_val = (amo_a64 >= amo_b64) ? amo_a64 : amo_b64;
        default:  amo_new_val = '0;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Load-data extraction and sign extension (64-bit result)
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
    rdata_o = '0;
    if (is_sc_q) begin
      // SC returns 0 on success, 1 on failure in the destination register.
      rdata_o = {63'b0, sc_result_q};
    end else begin
      unique case (funct3_q)
        3'b000:  rdata_o = {{56{raw_byte[7]}},  raw_byte};        // LB
        3'b001:  rdata_o = {{48{raw_half[15]}}, raw_half};        // LH
        3'b010:  rdata_o = {{32{rdata_q[31]}},  rdata_q};         // LW (sign-ext)
        3'b011:  rdata_o = {rdata_hi_q, rdata_q};                 // LD
        3'b100:  rdata_o = {56'b0, raw_byte};                     // LBU
        3'b101:  rdata_o = {48'b0, raw_half};                     // LHU
        3'b110:  rdata_o = {32'b0, rdata_q};                      // LWU
        default: rdata_o = '0;
      endcase
    end
  end

  // FP load data: NaN-box FLW (funct3=010), pass through FLD (funct3=011).
  // fp_dest_rsp_o fires alongside valid_o for FP loads; the top-level pipeline
  // routes the result to the FP regfile instead of the integer regfile.
  always_comb begin
    fp_rdata_o = '0;
    unique case (funct3_q)
      3'b010: fp_rdata_o = {FP_NANBOX_UPPER, rdata_q};  // FLW: NaN-box
      3'b011: fp_rdata_o = {rdata_hi_q, rdata_q};       // FLD: full 64-bit
      default: fp_rdata_o = '0;
    endcase
  end

  // Only FP loads produce an FP writeback — stores have no destination.
  assign fp_dest_rsp_o = (state_q == LOAD_DONE) & fp_dest_q & ~is_amo_q;

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q             <= IDLE;
      addr_q              <= '0;
      wdata_q             <= '0;
      funct3_q            <= '0;
      rdata_q             <= '0;
      rdata_hi_q          <= '0;
      is_dword_q          <= 1'b0;
      fp_dest_q           <= 1'b0;
      aw_acked_q          <= 1'b0;
      w_acked_q           <= 1'b0;
      is_lr_q             <= 1'b0;
      is_sc_q             <= 1'b0;
      is_amo_q            <= 1'b0;
      amo_funct5_q        <= '0;
      amo_src_q           <= '0;
      reservation_valid_q <= 1'b0;
      reservation_addr_q  <= '0;
      sc_result_q         <= 1'b0;
    end else begin
      unique case (state_q)

        IDLE: begin
          if (req_i) begin
            addr_q       <= addr_i;
            wdata_q      <= fp_dest_req_i ? fp_store_data_i : wdata_i;
            funct3_q     <= funct3_i;
            is_dword_q   <= (funct3_i[1:0] == 2'b11);
            fp_dest_q    <= fp_dest_req_i;
            is_lr_q      <= is_lr_i;
            is_sc_q      <= is_sc_i;
            is_amo_q     <= is_amo_i;
            amo_funct5_q <= amo_funct5_i;
            amo_src_q    <= amo_src_i;
            if (is_amo_i) begin
              // AMO: read-modify-write. Go through the load path first; after
              // LOAD_DONE we divert to AMO_COMPUTE and then STORE_SEND. AMO
              // does not touch the LR/SC reservation state.
              state_q <= LOAD_ADDR;
            end else if (is_sc_i) begin
              // SC always clears the reservation, regardless of outcome.
              reservation_valid_q <= 1'b0;
              if (reservation_valid_q && (reservation_addr_q == addr_i)) begin
                // Reservation hit: perform the store and report success.
                sc_result_q <= 1'b0;
                state_q     <= STORE_SEND;
                aw_acked_q  <= 1'b0;
                w_acked_q   <= 1'b0;
              end else begin
                // Reservation miss: skip the AXI store and report failure.
                sc_result_q <= 1'b1;
                state_q     <= SC_FAIL;
              end
            end else if (we_i) begin
              // Any non-SC store invalidates an outstanding reservation
              // (simplified single-reservation model).
              reservation_valid_q <= 1'b0;
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
            if (is_dword_q) begin
              state_q <= LOAD_ADDR_HI;
            end else begin
              state_q <= LOAD_DONE;
              // LR.W installs a word-granular reservation on the captured
              // address (always word-sized, so the single-beat path applies).
              if (is_lr_q) begin
                reservation_valid_q <= 1'b1;
                reservation_addr_q  <= addr_q;
              end
            end
          end
        end

        LOAD_ADDR_HI: begin
          if (axi_rsp_i.ar_ready) state_q <= LOAD_DATA_HI;
        end

        LOAD_DATA_HI: begin
          if (axi_rsp_i.r_valid) begin
            rdata_hi_q <= axi_rsp_i.r.data;
            state_q    <= LOAD_DONE;
          end
        end

        LOAD_DONE: begin
          if (is_amo_q) begin
            // AMO: feed loaded value into the compute stage; do NOT pulse
            // valid_o here (see valid_o assignment below).
            state_q <= AMO_COMPUTE;
          end else begin
            state_q <= IDLE;  // unconditional — valid_o is a 1-cycle pulse
          end
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
          if (axi_rsp_i.b_valid) begin
            if (is_dword_q) state_q <= STORE_SEND_HI;
            else            state_q <= STORE_DONE;
          end
        end

        STORE_SEND_HI: begin
          if (axi_rsp_i.aw_ready) aw_acked_q <= 1'b1;
          if (axi_rsp_i.w_ready)  w_acked_q  <= 1'b1;
          if ((aw_acked_q | axi_rsp_i.aw_ready) &
              (w_acked_q  | axi_rsp_i.w_ready)) begin
            state_q    <= STORE_RESP_HI;
            aw_acked_q <= 1'b0;
            w_acked_q  <= 1'b0;
          end
        end

        STORE_RESP_HI: begin
          if (axi_rsp_i.b_valid) state_q <= STORE_DONE;
        end

        STORE_DONE: begin
          // Clear the AMO flag so rdata_o returns to the normal load mux path
          // on the next operation.
          is_amo_q <= 1'b0;
          state_q  <= IDLE;  // unconditional — valid_o is a 1-cycle pulse
        end

        SC_FAIL: begin
          // One-cycle valid pulse carrying sc_result_q=1 in rdata_o.
          state_q <= IDLE;
        end

        AMO_COMPUTE: begin
          // Single-cycle compute: latch the ALU result into wdata_q so the
          // existing STORE_SEND path writes it back. addr_q/funct3_q/rdata_q
          // must remain untouched so the final valid_o pulse returns the
          // ORIGINAL loaded value through the normal load-mux path.
          wdata_q    <= amo_new_val;
          aw_acked_q <= 1'b0;
          w_acked_q  <= 1'b0;
          state_q    <= STORE_SEND;
        end

        default: state_q <= IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // AXI4 request outputs
  // -------------------------------------------------------------------------
  logic [31:0] addr_lo_aligned;
  logic [31:0] addr_hi_aligned;

  assign addr_lo_aligned = {addr_q[31:2], 2'b00};
  assign addr_hi_aligned = {addr_q[31:2], 2'b00} + 32'd4;

  always_comb begin
    axi_req_o = '0;
    unique case (state_q)
      LOAD_ADDR: begin
        axi_req_o.ar_valid = 1'b1;
        axi_req_o.ar.addr  = addr_lo_aligned;
        axi_req_o.ar.size  = 3'b010;
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      end
      LOAD_DATA: begin
        axi_req_o.r_ready  = 1'b1;
      end
      LOAD_ADDR_HI: begin
        axi_req_o.ar_valid = 1'b1;
        axi_req_o.ar.addr  = addr_hi_aligned;
        axi_req_o.ar.size  = 3'b010;
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      end
      LOAD_DATA_HI: begin
        axi_req_o.r_ready  = 1'b1;
      end
      STORE_SEND: begin
        axi_req_o.aw_valid = ~aw_acked_q;
        axi_req_o.aw.addr  = addr_lo_aligned;
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
      STORE_SEND_HI: begin
        axi_req_o.aw_valid = ~aw_acked_q;
        axi_req_o.aw.addr  = addr_hi_aligned;
        axi_req_o.aw.size  = 3'b010;
        axi_req_o.aw.burst = axi_pkg::BURST_INCR;
        axi_req_o.w_valid  = ~w_acked_q;
        axi_req_o.w.data   = wdata_q[63:32];
        axi_req_o.w.strb   = 4'b1111;
        axi_req_o.w.last   = 1'b1;
      end
      STORE_RESP_HI: begin
        axi_req_o.b_ready  = 1'b1;
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Pipeline stall and valid
  // -------------------------------------------------------------------------
  // AMO suppresses the LOAD_DONE valid pulse — the instruction completes only
  // on STORE_DONE, after the write-back beat returns. mem_stall_o stays
  // asserted through AMO_COMPUTE/STORE_SEND/STORE_RESP/STORE_DONE for the
  // same reason.
  assign mem_stall_o = req_i & (state_q != LOAD_DONE || is_amo_q) &
                              (state_q != STORE_DONE) &
                              (state_q != SC_FAIL);
  assign valid_o     = ((state_q == LOAD_DONE) & ~is_amo_q) |
                       (state_q == STORE_DONE) |
                       (state_q == SC_FAIL);

  // -------------------------------------------------------------------------
  // A-extension: LR/SC (Task 12) and AMO (Task 13) are fully wired. No lint
  // stubs remain — all A-extension ports drive live logic.
  // -------------------------------------------------------------------------
  // sc_success_o mirrors the inverted failure flag so downstream logic can
  // read 1=success / 0=fail without inspecting rdata_o.
  assign sc_success_o = ~sc_result_q;

endmodule
