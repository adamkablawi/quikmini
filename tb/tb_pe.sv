// QuikMini PE unit test
//
// Random dot products (length 1..64) with random bubbles where valid is low
// and the other inputs are garbage. Checks the result register against a
// model, checks that a/b/valid are forwarded one cycle later, and checks that
// a run without `first` keeps accumulating (accumulate mode).
//   build: make pe

module tb_pe;
    logic clk = 0, rst = 1;
    logic signed [7:0]  aIn = '0, bIn = '0;
    logic               validIn = 0, firstIn = 0, lastIn = 0;
    logic signed [7:0]  aOut, bOut;
    logic               validOut, firstOut, lastOut;
    logic signed [31:0] result;

    qm_pe dut (.*);

    always #5 clk = ~clk;

    int errors = 0;

    // Forwarding check: outputs equal the inputs from one cycle earlier
    logic signed [7:0] aPrev, bPrev;
    logic vPrev;
    always @(posedge clk) begin
        aPrev <= aIn;
        bPrev <= bIn;
        vPrev <= validIn;
    end
    always @(negedge clk) begin
        if (!rst && (aOut !== aPrev || bOut !== bPrev || validOut !== vPrev)) begin
            errors++;
            $display("FAIL forward: aOut=%0d (want %0d) bOut=%0d (want %0d)", aOut, aPrev, bOut, bPrev);
        end
    end

    // Drives one dot product of `len` terms; returns its exact sum
    task automatic dot(input int len, input bit useFirst, output longint sum);
        sum = 0;
        for (int k = 0; k < len; k++) begin
            // Random bubbles: garbage operands and flags with valid low
            while ($urandom_range(0, 3) == 0) begin
                @(negedge clk);
                validIn = 1'b0;
                aIn = 8'($urandom); bIn = 8'($urandom);
                firstIn = 1'($urandom); lastIn = 1'($urandom);
            end
            @(negedge clk);
            aIn = 8'($urandom); bIn = 8'($urandom);
            validIn = 1'b1;
            firstIn = useFirst && (k == 0);
            lastIn  = (k == len - 1);
            sum += longint'(aIn) * longint'(bIn);
        end
        @(negedge clk);
        validIn = 1'b0; firstIn = 1'b0; lastIn = 1'b0;
    endtask

    initial begin
        longint s1, s2;

        repeat (2) @(negedge clk);
        rst = 1'b0;

        // Random dot products
        for (int t = 0; t < 500; t++) begin
            dot($urandom_range(1, 64), 1'b1, s1);
            if (result !== 32'(s1)) begin
                errors++;
                $display("FAIL dot %0d: result=%0d want %0d", t, result, s1);
            end
        end

        // Extremes: 64 terms of (-128)(-128) and of (127)(-128)
        for (int pass = 0; pass < 2; pass++) begin
            for (int k = 0; k < 64; k++) begin
                @(negedge clk);
                aIn = (pass != 0) ? 8'sd127 : -8'sd128; bIn = -8'sd128;
                validIn = 1'b1; firstIn = (k == 0); lastIn = (k == 63);
            end
            @(negedge clk);
            validIn = 1'b0; firstIn = 1'b0; lastIn = 1'b0;
            s1 = (pass != 0) ? -64 * 127 * 128 : 64 * 128 * 128;
            if (result !== 32'(s1)) begin
                errors++;
                $display("FAIL extreme %0d: result=%0d want %0d", pass, result, s1);
            end
        end

        // Accumulate: a second dot product without `first` adds on
        dot(20, 1'b1, s1);
        dot(30, 1'b0, s2);
        if (result !== 32'(s1 + s2)) begin
            errors++;
            $display("FAIL accumulate: result=%0d want %0d", result, s1 + s2);
        end

        if (errors != 0) $fatal(1, "tb_pe: %0d errors", errors);
        $display("tb_pe: PASS (500 random dot products, extremes, accumulate)");
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "tb_pe: TIMEOUT");
    end

endmodule: tb_pe
