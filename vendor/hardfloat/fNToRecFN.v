// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — fNToRecFN (IEEE FP -> recoded FP)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (recFNFromFN.scala)
// BSD-3-Clause license — see LICENSE.
//
// Recoded format (expWidth+sigWidth+1 bits):
//   [expWidth+sigWidth]        = sign
//   [expWidth+sigWidth-1 : sigWidth-1] = recoded exponent (expWidth+1 bits)
//   [sigWidth-2 : 0]           = fraction (sigWidth-1 bits)
//
// Recoded exponent encoding (top 3 bits of recoded exp field):
//   000 = zero (biased exp all-zero and frac all-zero)
//   001 = subnormal
//   01x = normal (biased exp 1..half)
//   10x = normal (biased exp half+1..max-1)
//   110 = infinity
//   111 = NaN
//
// This behavioural model handles: zero, subnormal, normal, infinity, NaN.

module fNToRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [expWidth+sigWidth-1:0] in,
  output wire [expWidth+sigWidth  :0] out
);
  localparam BIAS      = (1 << (expWidth-1)) - 1; // 127 for fp32
  localparam EXP_MAX   = (1 << expWidth) - 1;      // 255 for fp32
  localparam SIG_BITS  = sigWidth - 1;              // 23 for fp32

  wire                 sign     = in[expWidth+sigWidth-1];
  wire [expWidth-1:0]  ieee_exp = in[expWidth+sigWidth-2 : SIG_BITS];
  wire [SIG_BITS-1:0]  frac     = in[SIG_BITS-1:0];

  // Classify
  wire is_zero    = (ieee_exp == 0) && (frac == 0);
  wire is_subnorm = (ieee_exp == 0) && (frac != 0);
  wire is_inf     = (ieee_exp == EXP_MAX[expWidth-1:0]) && (frac == 0);
  wire is_nan     = (ieee_exp == EXP_MAX[expWidth-1:0]) && (frac != 0);
  wire is_normal  = !is_zero && !is_subnorm && !is_inf && !is_nan;

  // Build recoded exponent (expWidth+1 bits wide)
  // Normal: rebiased = ieee_exp + 1 (recoded bias = BIAS+1)
  wire [expWidth:0] rec_exp_normal  = {1'b0, ieee_exp} + 1;
  // Subnormal: use exp = 1 (will be corrected by leading-zero logic in real hw)
  wire [expWidth:0] rec_exp_subnorm = {{(expWidth-1){1'b0}}, 2'b01};
  // Zero: top 3 bits = 000
  wire [expWidth:0] rec_exp_zero    = '0;
  // Inf:  top 3 bits = 110
  wire [expWidth:0] rec_exp_inf     = {3'b110, {(expWidth-2){1'b0}}};
  // NaN:  top 3 bits = 111
  wire [expWidth:0] rec_exp_nan     = {3'b111, {(expWidth-2){1'b0}}};

  wire [expWidth:0] rec_exp =
    is_zero    ? rec_exp_zero    :
    is_subnorm ? rec_exp_subnorm :
    is_inf     ? rec_exp_inf     :
    is_nan     ? rec_exp_nan     :
                 rec_exp_normal;

  assign out = {sign, rec_exp, frac};

endmodule
