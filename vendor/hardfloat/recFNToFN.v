// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — recFNToFN (recoded FP -> IEEE FP)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (fNFromRecFN.scala)
// BSD-3-Clause license — see LICENSE.

module recFNToFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [expWidth+sigWidth  :0] in,
  output wire [expWidth+sigWidth-1:0] out
);
  localparam SIG_BITS = sigWidth - 1;   // fraction bits in IEEE format

  wire                sign     = in[expWidth+sigWidth];
  wire [expWidth:0]   rec_exp  = in[expWidth+sigWidth-1 : SIG_BITS];
  wire [SIG_BITS-1:0] frac     = in[SIG_BITS-1:0];

  // Top 3 bits of recoded exponent determine the special case
  wire [2:0] top3 = rec_exp[expWidth : expWidth-2];

  wire is_zero    = (top3 == 3'b000);
  wire is_subnorm = (top3 == 3'b001);
  wire is_inf     = (top3 == 3'b110);
  wire is_nan     = (top3 == 3'b111);
  wire is_normal  = !is_zero && !is_subnorm && !is_inf && !is_nan;

  // Recover IEEE biased exponent from recoded (remove +1 offset for normals)
  wire [expWidth-1:0] ieee_exp_normal  = rec_exp[expWidth-1:0] - 1;
  wire [expWidth-1:0] ieee_exp_zero    = '0;
  wire [expWidth-1:0] ieee_exp_subnorm = '0;
  wire [expWidth-1:0] ieee_exp_inf     = '1;
  wire [expWidth-1:0] ieee_exp_nan     = '1;

  wire [expWidth-1:0] ieee_exp =
    is_zero    ? ieee_exp_zero    :
    is_subnorm ? ieee_exp_subnorm :
    is_inf     ? ieee_exp_inf     :
    is_nan     ? ieee_exp_nan     :
                 ieee_exp_normal;

  // NaN payload: set quiet bit; preserve rest of frac
  wire [SIG_BITS-1:0] frac_out =
    is_nan ? {1'b1, frac[SIG_BITS-2:0]} : frac;

  assign out = {sign, ieee_exp, frac_out};

endmodule
