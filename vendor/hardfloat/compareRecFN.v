// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — CompareRecFN (recoded FP comparison)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (CompareRecFN.scala)
// BSD-3-Clause license — see LICENSE.

module CompareRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [expWidth+sigWidth:0]  a,
  input  wire [expWidth+sigWidth:0]  b,
  input  wire                        signaling,
  output wire                        lt,
  output wire                        eq,
  output wire                        gt,
  output wire [4:0]                  exceptionFlags
);
  localparam SIG_BITS = sigWidth - 1;

  wire        a_sign    = a[expWidth+sigWidth];
  wire        b_sign    = b[expWidth+sigWidth];
  wire [2:0]  a_top3    = a[expWidth+sigWidth-1 : expWidth+sigWidth-3];
  wire [2:0]  b_top3    = b[expWidth+sigWidth-1 : expWidth+sigWidth-3];

  wire a_is_nan  = (a_top3 == 3'b111);
  wire b_is_nan  = (b_top3 == 3'b111);
  wire a_is_zero = (a_top3 == 3'b000);
  wire b_is_zero = (b_top3 == 3'b000);

  // Both zero: equal regardless of sign
  wire both_zero = a_is_zero && b_is_zero;

  // Magnitude comparison (ignoring sign): compare {rec_exp, frac}
  wire [expWidth+sigWidth-1:0] a_mag = a[expWidth+sigWidth-1:0];
  wire [expWidth+sigWidth-1:0] b_mag = b[expWidth+sigWidth-1:0];

  // IEEE comparison rules:
  //   if either is NaN -> unordered (lt=0, eq=0, gt=0)
  //   both zero -> eq
  //   different signs: negative < positive
  //   same sign, positive: compare magnitudes normally
  //   same sign, negative: compare magnitudes reversed

  wire ordered = !a_is_nan && !b_is_nan;

  wire mag_lt = (a_mag < b_mag);
  wire mag_eq = (a_mag == b_mag);

  wire ord_lt = both_zero ? 1'b0 :
                ( a_sign && !b_sign) ? 1'b1 :
                (!a_sign &&  b_sign) ? 1'b0 :
                a_sign               ? !mag_lt && !mag_eq :  // both neg
                                        mag_lt;              // both pos
  wire ord_eq = both_zero || (!a_sign && !b_sign && mag_eq) ||
                              ( a_sign &&  b_sign && mag_eq);

  assign lt             = ordered &&  ord_lt;
  assign eq             = ordered &&  ord_eq;
  assign gt             = ordered && !ord_lt && !ord_eq;
  assign exceptionFlags = (a_is_nan || b_is_nan) ? 5'b10000 : 5'b0;

endmodule
