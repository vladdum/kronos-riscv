// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — INToRecFN (integer -> recoded FP)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (INToRecFN.scala)
// BSD-3-Clause license — see LICENSE.
//
// Ports match the Chisel-generated interface:
//   signedIn   : treat `in` as a signed integer when 1
//   in         : integer input (intWidth bits)
//   roundingMode   : 3-bit rounding mode
//   detectTininess : 1-bit (unused in stubs)
//   out        : recoded FP result
//   exceptionFlags : 5-bit IEEE exception flags

module INToRecFN #(
  parameter intWidth  = 32,
  parameter expWidth  = 8,
  parameter sigWidth  = 24
) (
  input  wire                    signedIn,
  input  wire [intWidth-1:0]     in,
  input  wire [2:0]              roundingMode,
  input  wire                    detectTininess,
  output wire [expWidth+sigWidth:0] out,
  output wire [4:0]              exceptionFlags
);
  // Behavioural model: convert integer to IEEE fp then recode.
  // Uses $bitstoreal for double, not exact for all rounding modes but
  // sufficient for smoke/unit tests.

  wire        sign_bit;
  wire [63:0] magnitude;
  wire [intWidth-1:0] abs_val;

  assign sign_bit  = signedIn && in[intWidth-1];
  assign abs_val   = sign_bit ? (-in) : in;

  // Find leading-one position (priority encoder)
  integer i;
  reg [5:0]  lz;      // leading-zero count
  reg [63:0] mag_r;
  reg [expWidth-1:0] biased_exp_r;
  reg [sigWidth-2:0] frac_r;
  reg [expWidth:0]   rec_exp_r;

  always @(*) begin
    lz = 0;
    mag_r = {{(64-intWidth){1'b0}}, abs_val};
    // count leading zeros in abs_val (up to intWidth bits)
    begin : lz_loop
      integer j;
      lz = intWidth;
      for (j = intWidth-1; j >= 0; j = j - 1) begin
        if (abs_val[j]) lz = intWidth - 1 - j;
      end
    end

    if (abs_val == 0) begin
      // zero
      rec_exp_r   = '0;
      frac_r      = '0;
    end else begin
      // normal: biased exp = (intWidth-1-lz) + BIAS + 1  (recoded adds 1)
      biased_exp_r = (intWidth - 1 - lz) + ((1 << (expWidth-1)));
      rec_exp_r    = {1'b0, biased_exp_r};
      // shift significand so leading 1 is at bit sigWidth-2 of the fraction
      frac_r = (mag_r << (lz + 1)) >> (intWidth - sigWidth + 1);
    end
  end

  assign out            = {sign_bit, rec_exp_r, frac_r};
  assign exceptionFlags = 5'b0;

endmodule
