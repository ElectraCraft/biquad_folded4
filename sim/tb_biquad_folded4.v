// =============================================================================
// Testbench: biquad_folded4  (with CSHIFT=8 descaling)
// =============================================================================
`timescale 1ns/1ps
module tb_biquad_folded4;
    parameter DW     = 16;
    parameter CW     = 16;
    parameter AW     = 36;
    parameter CSHIFT = 8;
    reg clk, rst_n;
    always #5 clk = ~clk;
    reg signed [CW-1:0] b0, b1, b2, a1, a2;
    reg                 x_valid;
    reg signed [DW-1:0] x_in;
    wire                y_valid;
    wire signed [DW-1:0] y_out;
    biquad_folded4 #(
        .DW(DW), .CW(CW), .AW(AW), .CSHIFT(CSHIFT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .b0(b0), .b1(b1), .b2(b2),
        .a1(a1), .a2(a2),
        .x_valid(x_valid), .x_in(x_in),
        .y_valid(y_valid), .y_out(y_out)
    );
    // -----------------------------------------------------------------------
    // Butterworth LPF  Fc/Fs=0.1, coefficients scaled by 2^8 = 256
    //   b0 = b2 =  17  (0.0675*256)
    //   b1      =  34  (0.1349*256)
    //   a1      = -293 (-1.1430*256)   stored negative; design uses -a1
    //   a2      =  106 ( 0.4128*256)
    //
    // With CSHIFT=8 descaling:
    //   y[0] expected = (b0 * x[0]) >> 8 = (17*256) >> 8 = 17
    //   DC gain = (b0+b1+b2)/(1+a1+a2) in float
    //           = 68 / (1 + (-293)/256 + 106/256) = 68 / (256-293+106)*256
    //           = 68 / 69 * 256 / 256 ≈ 0.985  (nearly unity gain LPF)
    //   Step steady state ≈ 0.985 * 256 ≈ 252 (actual fixed-point result will
    //   land a few counts lower, ~249, because the design truncates rather
    //   than rounds after each >>CSHIFT -- expected, not a bug)
    // -----------------------------------------------------------------------
    initial begin
        b0 =  17;
        b1 =  34;
        b2 =  17;
        a1 = -293;
        a2 =  106;
    end
    // -----------------------------------------------------------------------
    // send_sample: drive x_in at negedge so it's stable at next posedge
    // One call = exactly 4 clock cycles (one folded frame).
    //
    // FIX: original task had FIVE @(negedge clk) waits (1 to assert x_valid,
    // 1 to deassert, then THREE more), i.e. a 5-cycle frame, while the DUT's
    // `slot` counter wraps every 4 cycles. That mismatch meant every call
    // after the first landed x_valid one slot phase later than the call
    // before it, so only the very first sample was reliably captured at
    // slot==0. Reduced to two trailing waits so the task is 4 cycles total,
    // matching the DUT's frame period.
    // -----------------------------------------------------------------------
    task send_sample;
        input signed [DW-1:0] sample;
        begin
            @(negedge clk);
            x_in    = sample;
            x_valid = 1'b1;
            @(negedge clk);
            x_valid = 1'b0;
            x_in    = {DW{1'b0}};
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Whitebox check: x_valid should only ever assert while the DUT is in
    // slot 0. If this fires, the testbench and DUT have drifted out of sync
    // again -- this is what would have caught the original 5-cycle bug.
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && x_valid && dut.slot != 2'd0) begin
            $display("ERROR: x_valid asserted outside slot 0 at time %0t (slot=%0d)",
                      $time, dut.slot);
        end
    end

    integer i;
    integer out_count;
    initial begin
        clk       = 0;
        rst_n     = 0;
        x_valid   = 0;
        x_in      = 0;
        out_count = 0;
        repeat(8) @(negedge clk);
        rst_n = 1;
        // -------------------------------------------------------------------
        // Test 1: Impulse response
        // y[0] should = 17  (b0*256 >> 8 = 17)
        // -------------------------------------------------------------------
        $display("--- Impulse Response (expect y[0]=17) ---");
        send_sample(16'd256);
        for (i = 1; i < 20; i = i+1)
            send_sample(16'd0);
        // -------------------------------------------------------------------
        // Test 2: Step response
        // Steady state expected ~249 in fixed point (see note above)
        // -------------------------------------------------------------------
        $display("\n--- Step Response (expect steady state ~249) ---");
        rst_n = 0;
        repeat(8) @(negedge clk);
        out_count = 0;
        rst_n = 1;
        for (i = 0; i < 40; i = i+1)
            send_sample(16'd256);
        $display("Simulation complete.");
        $finish;
    end
    always @(posedge clk) begin
        if (y_valid) begin
            $display("y[%0d] = %0d", out_count, $signed(y_out));
            out_count = out_count + 1;
        end
    end
    initial begin
        $dumpfile("biquad_folded4.vcd");
        $dumpvars(0, tb_biquad_folded4);
    end
endmodule
