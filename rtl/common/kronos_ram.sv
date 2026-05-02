// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// kronos_ram — Parameterised SDP RAM with 1-cycle registered read.
//
// Two backends behind `KRONOS_RAM_FPGA`:
//   - FPGA: xpm_memory_sdpram (Xilinx Parameterized Macros). Vivado infers
//     RAMB36E1/RAMB18E1 deterministically.
//   - ASIC / Verilator default: behavioural SDP. Synthesises as FFs on tools
//     without XPM. Functionally identical (same 1-cycle read, same byte-write
//     semantics).
//
// No reset on the data array — the consumer's external valid_q is the source
// of truth for "is this address readable". Same-cycle write+read collision
// behaviour is undefined; consumers must serialise via FSM.

module kronos_ram
#(
  parameter int unsigned DEPTH        = 64,
  parameter int unsigned WIDTH        = 64,
  parameter int unsigned BYTE_WIDTH   = 8,
  // Port-B write-then-read collision behaviour. Forwarded to xpm.
  //
  // **Vivado SDP block-RAM limitation:** RAMB36/RAMB18 in Simple-Dual-Port
  // mode only supports `"no_change"` (or `"read_first"`) on port B — XPM
  // rejects `"write_first"` at synth with `[XPM_MEMORY 40-50] WRITE_MODE_B
  // (0) specifies write-first mode, but Simple Dual port block RAM
  // configurations must use read-first mode for port B`.
  //
  // Consumers that need write-first / RAW forwarding semantics must
  // implement a same-cycle bypass mux outside the wrapper (the dcache
  // does this with a 1-deep prev-write register; see kronos_dcache.sv).
  //
  // Parameter is intentionally untyped — xpm_memory_sdpram does mixed-
  // type internal comparisons (`WRITE_MODE_B == 0 || WRITE_MODE_B ==
  // "no_change"`) that Vivado synth rejects when the value is a strict
  // `string` type.
  parameter              WRITE_MODE_B = "no_change"
) (
  input  logic                                clk_i,

  // Port A — write
  input  logic                                we_i,
  input  logic [$clog2(DEPTH)-1:0]            waddr_i,
  input  logic [WIDTH-1:0]                    wdata_i,
  input  logic [(WIDTH/BYTE_WIDTH)-1:0]       wmask_i,

  // Port B — read (1-cycle registered)
  input  logic                                re_i,
  input  logic [$clog2(DEPTH)-1:0]            raddr_i,
  output logic [WIDTH-1:0]                    rdata_o
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);
  localparam int unsigned NB     = WIDTH / BYTE_WIDTH;

`ifdef KRONOS_RAM_FPGA
  // ----------------------------------------------------------------------
  // FPGA backend — xpm_memory_sdpram
  // ----------------------------------------------------------------------
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A         (ADDR_W),
    .ADDR_WIDTH_B         (ADDR_W),
    .AUTO_SLEEP_TIME      (0),
    .BYTE_WRITE_WIDTH_A   (BYTE_WIDTH),
    .CASCADE_HEIGHT       (0),
    .CLOCKING_MODE        ("common_clock"),
    .ECC_MODE             ("no_ecc"),
    .MEMORY_INIT_FILE     ("none"),
    .MEMORY_INIT_PARAM    ("0"),
    .MEMORY_OPTIMIZATION  ("true"),
    .MEMORY_PRIMITIVE     ("block"),
    .MEMORY_SIZE          (DEPTH * WIDTH),
    .MESSAGE_CONTROL      (0),
    .READ_DATA_WIDTH_B    (WIDTH),
    .READ_LATENCY_B       (1),
    .READ_RESET_VALUE_B   ("0"),
    .RST_MODE_A           ("SYNC"),
    .RST_MODE_B           ("SYNC"),
    .SIM_ASSERT_CHK       (0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT         (1),
    .USE_MEM_INIT_MMI     (0),
    .WAKEUP_TIME          ("disable_sleep"),
    .WRITE_DATA_WIDTH_A   (WIDTH),
    .WRITE_MODE_B         (WRITE_MODE_B),
    .WRITE_PROTECT        (1)
  ) u_xpm (
    .dbiterrb     (),
    .doutb        (rdata_o),
    .sbiterrb     (),
    .addra        (waddr_i),
    .addrb        (raddr_i),
    .clka         (clk_i),
    .clkb         (clk_i),
    .dina         (wdata_i),
    .ena          (we_i),
    .enb          (re_i),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb       (1'b1),
    .rstb         (1'b0),
    .sleep        (1'b0),
    .wea          (wmask_i)
  );

`else
  // ----------------------------------------------------------------------
  // ASIC / Verilator default — behavioural SDP
  //
  // TODO: replace with vendor SRAM compiler macro (e.g., sram_64x4096_1r1w)
  // for ASIC tape-out. Behavioural model exists for build-survival only.
  // ----------------------------------------------------------------------
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] rdata_q;

  // Behavioural SDP — matches the xpm `"no_change"` / `"read_first"`
  // semantics: a same-cycle write+read at the same address makes port B
  // hold the OLD value (or unchanged). Same-cycle store→load forwarding
  // is the consumer's responsibility (see kronos_dcache.sv RAW bypass).
  always_ff @(posedge clk_i) begin
    if (we_i) begin
      for (int unsigned i = 0; i < NB; i++) begin
        if (wmask_i[i]) begin
          mem[waddr_i][i*BYTE_WIDTH +: BYTE_WIDTH] <=
            wdata_i[i*BYTE_WIDTH +: BYTE_WIDTH];
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (re_i) rdata_q <= mem[raddr_i];
  end

  assign rdata_o = rdata_q;

`endif

endmodule
