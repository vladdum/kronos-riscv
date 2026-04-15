// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — RecFNToRecFN (recoded FP precision conversion)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (RecFNToRecFN.scala)
// BSD-3-Clause license — see LICENSE.

module RecFNToRecFN #(
  parameter inExpWidth  = 8,
  parameter inSigWidth  = 24,
  parameter outExpWidth = 11,
  parameter outSigWidth = 53
) (
  input  wire [inExpWidth+inSigWidth    :0] in,
  input  wire [2:0]                         roundingMode,
  input  wire                               detectTininess,
  output wire [outExpWidth+outSigWidth   :0] out,
  output wire [4:0]                         exceptionFlags
);
  // For upconvert (f32->f64): expand exponent bias and extend fraction.
  // For downconvert (f64->f32): truncate (no round-to-nearest in stub).

  localparam IN_SIG_BITS  = inSigWidth  - 1;
  localparam OUT_SIG_BITS = outSigWidth - 1;

  wire                     sign    = in[inExpWidth+inSigWidth];
  wire [inExpWidth:0]      rec_exp_in = in[inExpWidth+inSigWidth-1 : IN_SIG_BITS];
  wire [IN_SIG_BITS-1:0]   frac_in    = in[IN_SIG_BITS-1:0];

  wire [2:0] top3 = rec_exp_in[inExpWidth : inExpWidth-2];
  wire is_zero    = (top3 == 3'b000);
  wire is_subnorm = (top3 == 3'b001);
  wire is_inf     = (top3 == 3'b110);
  wire is_nan     = (top3 == 3'b111);

  // Re-bias: subtract in-bias, add out-bias (both in recoded = IEEE_bias+1)
  localparam IN_BIAS  = (1 << (inExpWidth-1));
  localparam OUT_BIAS = (1 << (outExpWidth-1));
  wire signed [outExpWidth+1:0] rebias =
    $signed({1'b0, rec_exp_in}) - IN_BIAS + OUT_BIAS;
  wire [outExpWidth:0] rec_exp_out_normal = rebias[outExpWidth:0];

  wire [outExpWidth:0] rec_exp_inf = {3'b110, {(outExpWidth-2){1'b0}}};
  wire [outExpWidth:0] rec_exp_nan = {3'b111, {(outExpWidth-2){1'b0}}};
  wire [outExpWidth:0] rec_exp_zero= '0;

  wire [outExpWidth:0] rec_exp_out =
    is_zero ? rec_exp_zero :
    is_inf  ? rec_exp_inf  :
    is_nan  ? rec_exp_nan  :
              rec_exp_out_normal;

  // Extend or truncate fraction
  wire [OUT_SIG_BITS-1:0] frac_out;
  generate
    if (OUT_SIG_BITS >= IN_SIG_BITS)
      assign frac_out = {frac_in, {(OUT_SIG_BITS-IN_SIG_BITS){1'b0}}};
    else
      assign frac_out = frac_in[IN_SIG_BITS-1 : IN_SIG_BITS-OUT_SIG_BITS];
  endgenerate

  assign out            = {sign, rec_exp_out, frac_out};
  assign exceptionFlags = 5'b0;

endmodule
