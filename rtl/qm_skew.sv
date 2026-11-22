// Triangular input skew
//
// Lane i comes out i cycles after it goes in, so row i of A (and column j of
// B) enters the array one cycle behind its neighbor. That lines the operands
// up so PE(i,j) sees a[i][k] and b[k][j] on the same cycle, k + i + j cycles
// after the first operands enter.
//
//   lane 0  ──────────────────▶
//   lane 1  ──[d]─────────────▶
//   lane 2  ──[d]──[d]────────▶
//   ...

module qm_skew
  #(parameter int N = 8,
    parameter int W = 8)
  (input  logic clk, rst,
   input  logic [W-1:0] din  [N],
   output logic [W-1:0] dout [N]);

    assign dout[0] = din[0];

    for (genvar i = 1; i < N; i++) begin: g_lane
        logic [W-1:0] pipe [i];

        always_ff @(posedge clk) begin
            if (rst) begin
                for (int s = 0; s < i; s++) pipe[s] <= '0;
            end else begin
                pipe[0] <= din[i];
                for (int s = 1; s < i; s++) pipe[s] <= pipe[s-1];
            end
        end

        assign dout[i] = pipe[i-1];
    end

endmodule: qm_skew
