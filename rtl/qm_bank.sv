// Operand buffer bank: one write port, one registered read port
//
// QuikMini keeps one bank per row of A and one per column of B. During a run
// every bank reads the same address k each cycle, so banks never conflict.
// Read data appears the cycle after `re`, like block RAM.

module qm_bank
  #(parameter int DEPTH = 256,
    parameter int W = 8,
    localparam int AW = $clog2(DEPTH))
  (input  logic clk,
   input  logic we,
   input  logic [AW-1:0] waddr,
   input  logic [W-1:0] wdata,
   input  logic re,
   input  logic [AW-1:0] raddr,
   output logic [W-1:0] rdata);

    logic [W-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end

endmodule: qm_bank
