// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — isSigNaNRecFN
// Source: https://github.com/ucb-bar/berkeley-hardfloat (common.scala)
// BSD-3-Clause license — see LICENSE.
//
// Returns 1 if the recoded value is a signalling NaN.
// A sNaN has recoded exp top3 == 3'b111 and the MSB of the fraction = 0.

module isSigNaNRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [expWidth+sigWidth:0] in,
  output wire                       out
);
  localparam SIG_BITS = sigWidth - 1;
  wire [2:0] top3 = in[expWidth+sigWidth-1 : expWidth+sigWidth-3];
  wire       is_nan = (top3 == 3'b111);
  // quiet bit is MSB of fraction; sNaN has quiet=0
  wire       quiet  = in[SIG_BITS-1];
  assign out = is_nan && !quiet;
endmodule
