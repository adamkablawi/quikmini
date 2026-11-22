// N x N output-stationary systolic array
//
// A (with its control flags) flows east along each row, B flows south down
// each column, and PE(i,j) accumulates C[i][j] in place:
//
//            bNorth[0]  bNorth[1]       bNorth[N-1]
//               │          │                │
//   aWest[0] ─▶ PE(0,0) ─▶ PE(0,1) ─▶ ... ─▶ PE(0,N-1)
//               │          │                │
//   aWest[1] ─▶ PE(1,0) ─▶ PE(1,1) ─▶ ... ─▶ PE(1,N-1)
//               ...
//
// Inputs must already be skewed (see qm_skew).

module qm_array
  #(parameter int N = 8)
  (input  logic clk, rst,
   input  logic signed [7:0]  aWest [N],
   input  logic               validWest [N], firstWest [N], lastWest [N],
   input  logic signed [7:0]  bNorth [N],
   output logic signed [31:0] result [N][N],   // result[i][j] = C[i][j]
   output logic [N*N-1:0]     macActive,       // bit i*N+j: PE(i,j) does a MAC this cycle
   output logic               tileDone);       // last PE does its last MAC this cycle

    // aH[i][j] / flags enter PE(i,j) from the west; bV[i][j] enters from the north.
    // The extra column/row past the edge of the array is left unconnected.
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [7:0] aH [N][N+1];
    logic              vH [N][N+1];
    logic              fH [N][N+1];
    logic              lH [N][N+1];
    logic signed [7:0] bV [N+1][N];
    /* verilator lint_on UNUSEDSIGNAL */

    for (genvar i = 0; i < N; i++) begin: g_west
        assign aH[i][0] = aWest[i];
        assign vH[i][0] = validWest[i];
        assign fH[i][0] = firstWest[i];
        assign lH[i][0] = lastWest[i];
    end

    for (genvar j = 0; j < N; j++) begin: g_north
        assign bV[0][j] = bNorth[j];
    end

    for (genvar i = 0; i < N; i++) begin: g_row
        for (genvar j = 0; j < N; j++) begin: g_col
            qm_pe u_pe (.clk, .rst,
                        .aIn(aH[i][j]), .bIn(bV[i][j]),
                        .validIn(vH[i][j]), .firstIn(fH[i][j]), .lastIn(lH[i][j]),
                        .aOut(aH[i][j+1]), .bOut(bV[i+1][j]),
                        .validOut(vH[i][j+1]), .firstOut(fH[i][j+1]), .lastOut(lH[i][j+1]),
                        .result(result[i][j]));

            assign macActive[i*N + j] = vH[i][j];
        end
    end

    assign tileDone = vH[N-1][N-1] && lH[N-1][N-1];

endmodule: qm_array
