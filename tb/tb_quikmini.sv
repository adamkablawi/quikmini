// QuikMini top-level testbench
//
// Drives QuikMini over its bus the way a host CPU would. Checks the CSRs and
// error handling, then for each vector from scripts/gen_vectors.py: loads A
// and B, runs the multiply, checks all 64 C words against the golden model,
// and checks the CYCLES and MACS counters against the latency model.
//   build: make sim
//   args:  +vectors=<file>   (default build/vectors.txt)

module tb_quikmini;
    localparam int N = 8, KMAX = 256;
    localparam int NW = $clog2(N), KW = $clog2(KMAX), AW = KW + NW + 2;
    localparam int RGN = KW + NW;                       // region field starts here
    localparam int CSR_BASE = 0 << RGN, C_BASE = 1 << RGN,
                   A_BASE   = 2 << RGN, B_BASE = 3 << RGN;
    localparam int CTRL = 0, STATUS = 1, KREG = 2, CYCLES = 3, MACS = 4, ID = 5, CONFIG = 6;
    localparam int LATENCY = 2*N - 1;                   // busy cycles = K + 2N - 1

    logic clk = 0, rst = 1, re = 0, we = 0;
    logic [AW-1:0] addr = '0;
    logic [31:0] wdata = '0, rdata;
    logic busy, done;

    quikmini #(.N(N), .KMAX(KMAX)) dut (.*);

    always #5 clk = ~clk;   // 100 MHz

    int errors = 0;

    // Bus helpers: drive on the falling edge, DUT samples on the rising edge
    task automatic busWrite(input int a, input int d);
        @(negedge clk);
        we = 1'b1; addr = AW'(a); wdata = d;
        @(negedge clk);
        we = 1'b0;
    endtask

    task automatic busRead(input int a, output int d);
        @(negedge clk);
        re = 1'b1; addr = AW'(a);
        @(negedge clk);
        re = 1'b0;
        d = rdata;
    endtask

    task automatic check(input bit ok, input string msg);
        if (!ok) begin
            errors++;
            $display("  FAIL: %s", msg);
        end
    endtask

    task automatic waitDone(input string name);
        int s;
        for (int t = 0; t < 4 * KMAX; t++) begin
            busRead(CSR_BASE + STATUS, s);
            if (s[1]) return;
        end
        $fatal(1, "%s: timed out waiting for DONE", name);
    endtask

    initial begin
        string path, name;
        int fd, numTests, k, accum, v, s, cyc, macs, want, got, bad;
        int badK [2];

        if (!$value$plusargs("vectors=%s", path)) path = "build/vectors.txt";

        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- CSRs and error handling ----
        busRead(CSR_BASE + ID, v);
        check(v == 32'h514D0001, $sformatf("ID = %08h", v));
        busRead(CSR_BASE + CONFIG, v);
        check(v == {16'(KMAX), 16'(N)}, $sformatf("CONFIG = %08h", v));

        badK = '{0, KMAX + 1};
        foreach (badK[i]) begin
            busWrite(CSR_BASE + KREG, badK[i]);
            busWrite(CSR_BASE + CTRL, 1);
            busRead(CSR_BASE + STATUS, s);
            check(s == 32'b100, $sformatf("START with K=%0d: STATUS=%03b, want ERR only", badK[i], s));
        end
        $display("CSR and error checks: %s", errors == 0 ? "ok" : "FAIL");

        // ---- Vector tests ----
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s (run: make vectors)", path);
        void'($fscanf(fd, "%d", numTests));

        $display("");
        $display("%-18s %5s %7s %7s %7s", "test", "K", "cycles", "MACs", "util");
        for (int t = 0; t < numTests; t++) begin
            void'($fscanf(fd, "%s %d %d", name, k, accum));

            for (int i = 0; i < N; i++)
                for (int kk = 0; kk < k; kk++) begin
                    void'($fscanf(fd, "%d", v));
                    busWrite(A_BASE + i*KMAX + kk, v);
                end
            for (int kk = 0; kk < k; kk++)
                for (int j = 0; j < N; j++) begin
                    void'($fscanf(fd, "%d", v));
                    busWrite(B_BASE + kk*N + j, v);
                end

            busWrite(CSR_BASE + KREG, k);
            busWrite(CSR_BASE + CTRL, 1 | (accum << 1));
            busRead(CSR_BASE + STATUS, s);
            check(s[0] == 1'b1, $sformatf("%s: BUSY not set after START", name));
            waitDone(name);

            bad = 0;
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++) begin
                    void'($fscanf(fd, "%d", want));
                    busRead(C_BASE + i*N + j, got);
                    if (got != want) begin
                        if (bad < 4) $display("  %s: C[%0d][%0d] = %0d, want %0d", name, i, j, got, want);
                        bad++;
                    end
                end
            errors += bad;

            busRead(CSR_BASE + CYCLES, cyc);
            busRead(CSR_BASE + MACS, macs);
            check(macs == N*N*k, $sformatf("%s: MACS = %0d, want %0d", name, macs, N*N*k));
            check(cyc == k + LATENCY, $sformatf("%s: CYCLES = %0d, want %0d", name, cyc, k + LATENCY));

            $display("%-18s %5d %7d %7d %6.1f%%  %s", name, k, cyc, macs,
                     100.0 * real'(macs) / real'(N*N*cyc), bad == 0 ? "ok" : "FAIL");
        end
        $fclose(fd);

        $display("");
        if (errors != 0) $fatal(1, "tb_quikmini: %0d errors", errors);
        $display("tb_quikmini: ALL %0d TESTS PASSED", numTests);
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "tb_quikmini: TIMEOUT");
    end

`ifdef TRACE
    initial begin
        $dumpfile("build/quikmini.vcd");
        $dumpvars(0, tb_quikmini);
    end
`endif

endmodule: tb_quikmini
