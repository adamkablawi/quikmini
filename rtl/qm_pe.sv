// QuikMini processing element (PE)
//
// One cell of the output-stationary systolic array. Every cycle the PE:
//   - multiplies the INT8 operands arriving from the west (a) and north (b)
//   - adds the 16-bit product into its own 32-bit accumulator
//   - forwards a east and b south through registers, one hop per cycle
//
// Control flags travel east with a. b needs no flags, because the input skew
// makes the matching b arrive on the same cycle as its a.
//   valid  this cycle's operands are real data, so do a MAC
//   first  start a new dot product: acc <= a*b instead of acc + a*b
//   last   final term: also copy the finished sum into the result register
//
// The result register is separate from the accumulator, so a finished output
// stays readable while the next run computes. The accumulator keeps its value
// after `last`, which is what accumulate mode builds on (no `first` = keep adding).
//
// A 32-bit accumulator can't overflow for K <= 131072 terms: the largest
// product is (-128)(-128) = 2^14, and 2^31 / 2^14 = 2^17.

(* use_dsp = "yes" *)
module qm_pe
  (input  logic clk, rst,
   input  logic signed [7:0]  aIn, bIn,
   input  logic               validIn, firstIn, lastIn,
   output logic signed [7:0]  aOut, bOut,
   output logic               validOut, firstOut, lastOut,
   output logic signed [31:0] result);

    logic signed [15:0] prod;
    logic signed [31:0] acc, accBase, accNext;

    assign prod    = aIn * bIn;
    assign accBase = firstIn ? 32'sd0 : acc;
    assign accNext = accBase + 32'(prod);   // size cast keeps the sign: sign-extends

    // Accumulator, result and flags (reset)
    always_ff @(posedge clk) begin
        if (rst) begin
            acc      <= '0;
            result   <= '0;
            validOut <= 1'b0;
            firstOut <= 1'b0;
            lastOut  <= 1'b0;
        end else begin
            if (validIn)           acc    <= accNext;
            if (validIn && lastIn) result <= accNext;
            validOut <= validIn;
            firstOut <= firstIn;
            lastOut  <= lastIn;
        end
    end

    // Operand forwarding (no reset needed: only used when a valid flag says so)
    always_ff @(posedge clk) begin
        aOut <= aIn;
        bOut <= bIn;
    end

endmodule: qm_pe
