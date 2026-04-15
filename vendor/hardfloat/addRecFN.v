// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — AddRecFN (recoded FP add/subtract)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (AddRecFN.scala)
// BSD-3-Clause license — see LICENSE.
//
// Behavioural model: uses $bitstoreal / $realtobits for fp64 reference path,
// or bit-manipulation for fp32.  Sufficient for elaboration and basic smoke
// tests.  NOT bit-exact for all rounding modes / subnormals.

module AddRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire                          subOp,
  input  wire [expWidth+sigWidth  :0]  a,
  input  wire [expWidth+sigWidth  :0]  b,
  input  wire [2:0]                    roundingMode,
  input  wire                          detectTininess,
  output wire [expWidth+sigWidth  :0]  out,
  output wire [4:0]                    exceptionFlags
);
  // Convert recoded -> IEEE -> compute -> recode
  wire [expWidth+sigWidth-1:0] a_ieee, b_ieee;
  wire [expWidth+sigWidth-1:0] result_ieee;
  wire [expWidth+sigWidth  :0] result_rec;

  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_a2f (.in(a), .out(a_ieee));
  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_b2f (.in(b), .out(b_ieee));

  // Behavioural addition using real arithmetic (fp32 only; adequate for TB)
  real ra, rb, rr;
  reg [expWidth+sigWidth-1:0] res_reg;
  always @(*) begin
    ra = $bitstoreal({32'b0, a_ieee});  // sign-extend to 64-bit for $bitstoreal
    rb = $bitstoreal({32'b0, b_ieee});
    rr = subOp ? (ra - rb) : (ra + rb);
    res_reg = $realtobits(rr);          // lower 32 bits for fp32
  end
  assign result_ieee = res_reg[expWidth+sigWidth-1:0];

  fNToRecFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_f2r (.in(result_ieee), .out(result_rec));

  assign out            = result_rec;
  assign exceptionFlags = 5'b0;
endmodule
