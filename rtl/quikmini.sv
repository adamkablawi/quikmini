// QuikMini: INT8 systolic-array matrix multiply unit
//
// Computes C (N x N, INT32) = A (N x K, INT8) * B (K x N, INT8) for
// 1 <= K <= KMAX on an N x N output-stationary array (default 8 x 8).
// N and KMAX must be powers of two.
//
// Built to offload matrix math from the KLW-32: one 32-bit word-addressed bus,
// reads return data the cycle after `re` (same timing as KLW-32's mem.sv), and
// every result is exactly one 32-bit word.
//
// Address map (word addresses; numbers shown for N = 8, KMAX = 256):
//   0x0000  CSRs
//     +0 CTRL    W: bit0 START, bit1 ACCUM (add onto the previous run's C)
//                R: bit1 = ACCUM of the last run
//     +1 STATUS  R: bit0 BUSY, bit1 DONE, bit2 ERR (START with K = 0 or K > KMAX)
//     +2 K       RW: inner dimension, 1..KMAX (writes ignored while BUSY)
//     +3 CYCLES  R: cycles the last run was busy
//     +4 MACS    R: multiply-accumulates the last run did
//     +5 ID      R: 0x514D0001 ("QM", version 1)
//     +6 CONFIG  R: {KMAX[15:0], N[15:0]}
//   0x0800  C   R: C[i][j] at 0x0800 + i*N + j      (signed INT32)
//   0x1000  A   W: A[i][k] at 0x1000 + i*KMAX + k   (wdata[7:0], signed INT8)
//   0x1800  B   W: B[k][j] at 0x1800 + k*N + j      (wdata[7:0], signed INT8)
//
// One INT8 per word keeps the layout identical to what KLW-32 software uses,
// since KLW-32 is word-addressed with no byte loads.
//
// A run: write A, B and K, write CTRL = 1, poll STATUS until DONE, read C.
// Don't write A or B while BUSY. C holds the previous results until DONE.
//
// Timing: a run is busy for K + 2N - 1 cycles (K + 15 for N = 8): K cycles to
// stream operands, 1 cycle of buffer read latency, and 2(N-1) cycles for the
// skew to fill and drain the array. PE utilization is K / (K + 2N - 1).

module quikmini
  #(parameter int N = 8,
    parameter int KMAX = 256,
    localparam int NW = $clog2(N),
    localparam int KW = $clog2(KMAX),
    localparam int AW = KW + NW + 2)
  (input  logic clk, rst,
   input  logic re, we,
   input  logic [AW-1:0] addr,
   input  logic [31:0] wdata,
   output logic [31:0] rdata,
   output logic busy, done);

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    localparam logic [1:0] RGN_CSR = 2'd0, RGN_C = 2'd1, RGN_A = 2'd2, RGN_B = 2'd3;
    localparam logic [2:0] CSR_CTRL   = 3'd0, CSR_STATUS = 3'd1, CSR_K  = 3'd2,
                           CSR_CYCLES = 3'd3, CSR_MACS   = 3'd4, CSR_ID = 3'd5,
                           CSR_CONFIG = 3'd6;
    localparam logic [31:0] ID = 32'h514D_0001;

    logic [1:0]       region;
    logic [KW+NW-1:0] offset;
    logic [2:0]       csrSel;
    logic             csrWe;

    assign region = addr[AW-1 -: 2];
    assign offset = addr[KW+NW-1:0];
    assign csrSel = offset[2:0];
    assign csrWe  = we && (region == RGN_CSR);

    // ------------------------------------------------------------------
    // Controller: IDLE -> RUN (issue k = 0..K-1) -> FLUSH (wait for last PE)
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {IDLE, RUN, FLUSH} state_t;
    state_t state;

    localparam int PCW = $clog2(N*N + 1);

    logic [KW:0]    kLen;           // K, 1..KMAX
    logic           kOk;            // kLen is a legal K
    logic [KW-1:0]  kCnt;           // index being issued
    logic           accumMode, doneQ, errQ;
    logic [31:0]    cycles, macs;
    logic [N*N-1:0] macActive;
    logic           tileDone;

    logic issue, issueFirst, issueLast;
    assign issue      = (state == RUN);
    assign issueFirst = issue && (kCnt == '0) && !accumMode;
    assign issueLast  = issue && ({1'b0, kCnt} == kLen - (KW+1)'(1));

    function automatic logic [PCW-1:0] popcount(input logic [N*N-1:0] v);
        popcount = '0;
        for (int i = 0; i < N*N; i++) popcount = popcount + PCW'(v[i]);
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            kLen      <= '0;
            kOk       <= 1'b0;
            kCnt      <= '0;
            accumMode <= 1'b0;
            doneQ     <= 1'b0;
            errQ      <= 1'b0;
            cycles    <= '0;
            macs      <= '0;
        end else begin
            unique case (state)
                IDLE: begin
                    if (csrWe && csrSel == CSR_K) begin
                        kLen <= wdata[KW:0];
                        kOk  <= (wdata != 0) && (wdata <= KMAX);
                    end
                    if (csrWe && csrSel == CSR_CTRL && wdata[0]) begin
                        doneQ <= 1'b0;
                        errQ  <= !kOk;
                        if (kOk) begin
                            state     <= RUN;
                            kCnt      <= '0;
                            accumMode <= wdata[1];
                            cycles    <= '0;
                            macs      <= '0;
                        end
                    end
                end

                RUN: begin
                    kCnt <= kCnt + KW'(1);
                    if (issueLast) state <= FLUSH;
                end

                FLUSH: begin
                    if (tileDone) begin
                        state <= IDLE;
                        doneQ <= 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase

            // Performance counters: count every busy cycle and every PE that
            // did a MAC in it. Utilization = MACS / (N*N * CYCLES).
            if (state != IDLE) begin
                cycles <= cycles + 32'd1;
                macs   <= macs + 32'(popcount(macActive));
            end
        end
    end

    assign busy = (state != IDLE);
    assign done = doneQ;

    // ------------------------------------------------------------------
    // Operand buffers: one bank per row of A, one per column of B
    // ------------------------------------------------------------------
    logic [7:0] aBankOut [N];
    logic [7:0] bBankOut [N];

    for (genvar i = 0; i < N; i++) begin: g_bank
        qm_bank #(.DEPTH(KMAX), .W(8)) u_a
            (.clk,
             .we(we && region == RGN_A && offset[KW+NW-1:KW] == NW'(i)),
             .waddr(offset[KW-1:0]), .wdata(wdata[7:0]),
             .re(issue), .raddr(kCnt), .rdata(aBankOut[i]));

        qm_bank #(.DEPTH(KMAX), .W(8)) u_b
            (.clk,
             .we(we && region == RGN_B && offset[NW-1:0] == NW'(i)),
             .waddr(offset[KW+NW-1:NW]), .wdata(wdata[7:0]),
             .re(issue), .raddr(kCnt), .rdata(bBankOut[i]));
    end

    // Flags are delayed one cycle to line up with the buffers' read latency
    logic issueQ, firstQ, lastQ;
    always_ff @(posedge clk) begin
        if (rst) {issueQ, firstQ, lastQ} <= '0;
        else     {issueQ, firstQ, lastQ} <= {issue, issueFirst, issueLast};
    end

    // ------------------------------------------------------------------
    // Input skew: row i of A (with its flags) and column j of B are delayed
    // i and j cycles
    // ------------------------------------------------------------------
    logic [10:0]       aSkewIn [N], aSkewOut [N];   // {valid, first, last, a[7:0]}
    logic [7:0]        bSkewIn [N], bSkewOut [N];
    logic signed [7:0] aWest [N], bNorth [N];
    logic              validWest [N], firstWest [N], lastWest [N];

    for (genvar i = 0; i < N; i++) begin: g_lane
        assign aSkewIn[i] = {issueQ, firstQ, lastQ, aBankOut[i]};
        assign bSkewIn[i] = bBankOut[i];
        assign {validWest[i], firstWest[i], lastWest[i], aWest[i]} = aSkewOut[i];
        assign bNorth[i] = bSkewOut[i];
    end

    qm_skew #(.N(N), .W(11)) u_skewA (.clk, .rst, .din(aSkewIn), .dout(aSkewOut));
    qm_skew #(.N(N), .W(8))  u_skewB (.clk, .rst, .din(bSkewIn), .dout(bSkewOut));

    // ------------------------------------------------------------------
    // Systolic array
    // ------------------------------------------------------------------
    logic signed [31:0] result [N][N];

    qm_array #(.N(N)) u_array
        (.clk, .rst, .aWest, .validWest, .firstWest, .lastWest, .bNorth,
         .result, .macActive, .tileDone);

    // ------------------------------------------------------------------
    // Read path (data is valid the cycle after re)
    // ------------------------------------------------------------------
    logic [31:0] csrData;

    always_comb begin
        unique case (csrSel)
            CSR_CTRL:   csrData = {30'b0, accumMode, 1'b0};
            CSR_STATUS: csrData = {29'b0, errQ, doneQ, busy};
            CSR_K:      csrData = 32'(kLen);
            CSR_CYCLES: csrData = cycles;
            CSR_MACS:   csrData = macs;
            CSR_ID:     csrData = ID;
            CSR_CONFIG: csrData = {16'(KMAX), 16'(N)};
            default:    csrData = '0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) rdata <= '0;
        else if (re) begin
            unique case (region)
                RGN_CSR: rdata <= csrData;
                RGN_C:   rdata <= result[offset[2*NW-1:NW]][offset[NW-1:0]];
                default: rdata <= '0;           // A and B are write-only
            endcase
        end
    end

endmodule: quikmini
