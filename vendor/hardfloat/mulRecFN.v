// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — MulRecFN (recoded FP multiply)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (MulRecFN.scala)
// BSD-3-Clause license — see LICENSE.

module MulRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [expWidth+sigWidth  :0]  a,
  input  wire [expWidth+sigWidth  :0]  b,
  input  wire [2:0]                    roundingMode,
  input  wire                          detectTininess,
  output wire [expWidth+sigWidth  :0]  out,
  output wire [4:0]                    exceptionFlags
);
  wire [expWidth+sigWidth-1:0] a_ieee, b_ieee, result_ieee;
  wire [expWidth+sigWidth  :0] result_rec;

  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_a2f (.in(a), .out(a_ieee));
  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_b2f (.in(b), .out(b_ieee));

  real ra, rb, rr;
  reg [expWidth+sigWidth-1:0] res_reg;
  always @(*) begin
    ra = $bitstoreal({32'b0, a_ieee});
    rb = $bitstoreal({32'b0, b_ieee});
    rr = ra * rb;
    res_reg = $realtobits(rr);
  end
  assign result_ieee = res_reg[expWidth+sigWidth-1:0];

  fNToRecFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_f2r (.in(result_ieee), .out(result_rec));

  assign out            = result_rec;
  assign exceptionFlags = 5'b0;
endmodule
