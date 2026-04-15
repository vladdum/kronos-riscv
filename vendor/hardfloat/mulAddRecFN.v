// STUB - replace with real HardFloat generated Verilog
// Berkeley HardFloat — MulAddRecFN (recoded FP fused multiply-add)
// Source: https://github.com/ucb-bar/berkeley-hardfloat (MulAddRecFN.scala)
// BSD-3-Clause license — see LICENSE.
//
// op[1:0]:
//   00 = a*b + c
//   01 = a*b - c
//   10 = -(a*b) + c   (= c - a*b)
//   11 = -(a*b) - c

module MulAddRecFN #(
  parameter expWidth = 8,
  parameter sigWidth = 24
) (
  input  wire [1:0]                    op,
  input  wire [expWidth+sigWidth  :0]  a,
  input  wire [expWidth+sigWidth  :0]  b,
  input  wire [expWidth+sigWidth  :0]  c,
  input  wire [2:0]                    roundingMode,
  input  wire                          detectTininess,
  output wire [expWidth+sigWidth  :0]  out,
  output wire [4:0]                    exceptionFlags
);
  wire [expWidth+sigWidth-1:0] a_ieee, b_ieee, c_ieee, result_ieee;
  wire [expWidth+sigWidth  :0] result_rec;

  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_a2f (.in(a), .out(a_ieee));
  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_b2f (.in(b), .out(b_ieee));
  recFNToFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_c2f (.in(c), .out(c_ieee));

  real ra, rb, rc, rprod, rr;
  reg [expWidth+sigWidth-1:0] res_reg;
  always @(*) begin
    ra    = $bitstoreal({32'b0, a_ieee});
    rb    = $bitstoreal({32'b0, b_ieee});
    rc    = $bitstoreal({32'b0, c_ieee});
    rprod = ra * rb;
    case (op)
      2'b00: rr =  rprod + rc;
      2'b01: rr =  rprod - rc;
      2'b10: rr = -rprod + rc;
      2'b11: rr = -rprod - rc;
    endcase
    res_reg = $realtobits(rr);
  end
  assign result_ieee = res_reg[expWidth+sigWidth-1:0];

  fNToRecFN #(.expWidth(expWidth), .sigWidth(sigWidth)) u_f2r (.in(result_ieee), .out(result_rec));

  assign out            = result_rec;
  assign exceptionFlags = 5'b0;
endmodule
