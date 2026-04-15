// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — RecFNToIN (recoded FP -> integer)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (RecFNToIN.scala)
// BSD-3-Clause license — see LICENSE.
//
// Note: Chisel generates the module name RecFNToIN_e${expWidth}_s${sigWidth}_i${intWidth}
// but this stub uses the generic name for simplicity.

module RecFNToIN #(
  parameter expWidth = 8,
  parameter sigWidth = 24,
  parameter intWidth = 32
) (
  input  wire [expWidth+sigWidth:0] in,
  input  wire [2:0]                 roundingMode,
  input  wire                       signedOut,
  output wire [intWidth-1:0]        out,
  output wire [2:0]                 intExceptionFlags
);
  localparam SIG_BITS  = sigWidth - 1;
  localparam BIAS_REC  = (1 << (expWidth-1));  // recoded bias = IEEE_BIAS + 1

  wire                sign    = in[expWidth+sigWidth];
  wire [expWidth:0]   rec_exp = in[expWidth+sigWidth-1 : SIG_BITS];
  wire [SIG_BITS-1:0] frac    = in[SIG_BITS-1:0];

  wire [2:0] top3 = rec_exp[expWidth : expWidth-2];
  wire is_zero = (top3 == 3'b000);
  wire is_inf  = (top3 == 3'b110);
  wire is_nan  = (top3 == 3'b111);

  // Unbiased exponent = rec_exp - BIAS_REC
  wire signed [expWidth:0] unbiased = $signed(rec_exp) - $signed(BIAS_REC[expWidth:0]);

  // Reconstruct magnitude: {1, frac} >> (SIG_BITS - unbiased)
  wire [intWidth+SIG_BITS:0] sig_full = {{intWidth{1'b0}}, 1'b1, frac};
  wire [5:0] rsh;
  assign rsh = (unbiased >= SIG_BITS) ? 0 :
               ($signed(unbiased) < 0)  ? (SIG_BITS + 1) :
                                          (SIG_BITS - unbiased);
  wire [intWidth-1:0] magnitude = sig_full >> rsh;

  wire [intWidth-1:0] result_unsigned = magnitude;
  wire [intWidth-1:0] result_signed   = sign ? (-magnitude) : magnitude;

  assign out              = signedOut ? result_signed : result_unsigned;
  assign intExceptionFlags = (is_nan || is_inf) ? 3'b101 : 3'b000;

endmodule
