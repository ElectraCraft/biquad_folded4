// =============================================================================
// 4-Folded Biquad IIR Filter - Register Minimization Technique
// Verilog-2001 compliant (Vivado compatible)
// =============================================================================
// Transfer Function:
//   H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
//
// Direct Form II:
//   w[n] = x[n] - a1*w[n-1] - a2*w[n-2]
//   y[n] = b0*w[n] + b1*w[n-1] + b2*w[n-2]
//
// Coefficient Scaling:
//   All coefficients are pre-scaled by CSCALE = 2^CSHIFT (default 256 = 2^8).
//   After each multiply-accumulate, the result is right-shifted by CSHIFT
//   to bring it back to the same Q-format as the input data.
//   This keeps w[n] and y[n] in the same numeric range as x[n].
//
// Folded Schedule (4 slots per sample):
//   Slot 0: snapshot S1=w[n-1], S2=w[n-2]
//           R_P0 = (-a1_sc * w[n-1]) >> CSHIFT
//   Slot 1: R_fb = ((-a2_sc * S2) >> CSHIFT) + R_P0
//   Slot 2: w[n] = sat(R_fb + x[n]); update state
//           R_P1 = (b1_sc * S1) >> CSHIFT
//   Slot 3: y[n] = sat((b2_sc*S2 >> CSHIFT) + R_P1 + (b0_sc*w[n] >> CSHIFT))
//
// Register count (minimized): S1,S2,R_P0,R_fb,R_P1,R_wn,R_w1,R_w2 = 8
//
// -----------------------------------------------------------------------------
// FIX (see review): R_fb previously summed two already-saturated DW-bit MAC
// outputs directly into a DW-bit register with no guard bit, unlike wn_full/
// wn_sat and yn_full/yn_sat which both correctly widen before saturating.
// For high-Q coefficient sets this could silently wrap instead of saturate.
// R_fb now goes through the same widen-then-saturate pattern as wn_full/yn_full.
// -----------------------------------------------------------------------------
// =============================================================================

module biquad_folded4 #(
    parameter DW     = 16,        // data width
    parameter CW     = 16,        // coefficient width
    parameter AW     = 36,        // accumulator: DW + CW + guard bits
    parameter CSHIFT = 8          // coefficient scale = 2^CSHIFT (must match TB)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Coefficients pre-scaled by 2^CSHIFT (signed integers)
    input  wire signed [CW-1:0]  b0, b1, b2,
    input  wire signed [CW-1:0]  a1, a2,

    // x_valid pulses for 1 cycle at slot==0
    input  wire                  x_valid,
    input  wire signed [DW-1:0]  x_in,

    output reg                   y_valid,
    output reg  signed [DW-1:0]  y_out
);

    // -------------------------------------------------------------------------
    // Pre-negate a1, a2 as named wires (bit-indexing on expressions is illegal)
    // -------------------------------------------------------------------------
    wire signed [CW-1:0] neg_a1 = -a1;
    wire signed [CW-1:0] neg_a2 = -a2;

    // -------------------------------------------------------------------------
    // Slot counter  0->1->2->3->0->...
    // -------------------------------------------------------------------------
    reg [1:0] slot;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) slot <= 2'd0;
        else        slot <= slot + 2'd1;
    end

    // -------------------------------------------------------------------------
    // IIR state + snapshot registers  (all in data Q-format, no scale factor)
    // -------------------------------------------------------------------------
    reg signed [DW-1:0] R_w1, R_w2;   // w[n-1], w[n-2]
    reg signed [DW-1:0] S1,   S2;     // snapshots taken at slot 0

    // -------------------------------------------------------------------------
    // Pipeline registers (in data Q-format after descaling)
    // -------------------------------------------------------------------------
    reg signed [DW-1:0] R_P0;   // (-a1*w[n-1]) >> CSHIFT
    reg signed [DW-1:0] R_fb;   // R_P0 + (-a2*w[n-2]) >> CSHIFT
    reg signed [DW-1:0] R_P1;   // (b1*w[n-1]) >> CSHIFT
    reg signed [DW-1:0] R_wn;   // w[n]

    // -------------------------------------------------------------------------
    // x[n] latch
    // -------------------------------------------------------------------------
    reg signed [DW-1:0] R_xn;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) R_xn <= {DW{1'b0}};
        else if (x_valid) R_xn <= x_in;
    end

    // -------------------------------------------------------------------------
    // Shared MAC unit (AW-wide to hold full product before descaling)
    // mac_result = (mac_a * mac_b) >> CSHIFT  - descaled output
    // -------------------------------------------------------------------------
    reg  signed [AW-1:0] mac_a, mac_b;
    wire signed [AW-1:0] mac_product;
    wire signed [AW-CSHIFT-1:0] mac_descaled;
    wire signed [DW-1:0] mac_sat;

    assign mac_product  = mac_a * mac_b;
    // Arithmetic right-shift by CSHIFT to descale
    assign mac_descaled = mac_product[AW-1:CSHIFT];   // AW-CSHIFT bits, take DW LSBs
    // Saturate descaled result to DW bits
    assign mac_sat = (mac_product[AW-1:DW+CSHIFT-1] == {(AW-DW-CSHIFT+1){mac_product[AW-1]}})
                   ? mac_descaled[DW-1:0]
                   : (mac_product[AW-1] ? {1'b1, {(DW-1){1'b0}}}
                                        : {1'b0, {(DW-1){1'b1}}});

    // -------------------------------------------------------------------------
    // MAC input mux (combinatorial)
    // -------------------------------------------------------------------------
    always @(*) begin
        mac_a = {AW{1'b0}};
        mac_b = {AW{1'b0}};
        case (slot)
            2'd0: begin   // (-a1) * w[n-1]
                mac_a = {{(AW-CW){neg_a1[CW-1]}}, neg_a1};
                mac_b = {{(AW-DW){R_w1[DW-1]}},   R_w1};
            end
            2'd1: begin   // (-a2) * S2
                mac_a = {{(AW-CW){neg_a2[CW-1]}}, neg_a2};
                mac_b = {{(AW-DW){S2[DW-1]}},     S2};
            end
            2'd2: begin   // b1 * S1
                mac_a = {{(AW-CW){b1[CW-1]}}, b1};
                mac_b = {{(AW-DW){S1[DW-1]}}, S1};
            end
            2'd3: begin   // b2 * S2
                mac_a = {{(AW-CW){b2[CW-1]}}, b2};
                mac_b = {{(AW-DW){S2[DW-1]}}, S2};
            end
            default: begin
                mac_a = {AW{1'b0}};
                mac_b = {AW{1'b0}};
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // FIX: R_fb = R_P0 + (-a2*S2 descaled)   -- widen by 1 guard bit, then
    // saturate, exactly like wn_full/wn_sat below. Previously this summed two
    // DW-bit saturated values straight into a DW-bit register with no guard
    // bit, so it could wrap silently for large-magnitude a1/a2 coefficients.
    // -------------------------------------------------------------------------
    wire signed [DW:0]   rfb_full;
    wire signed [DW-1:0] rfb_sat;
    assign rfb_full = {R_P0[DW-1], R_P0} + {mac_sat[DW-1], mac_sat};
    assign rfb_sat  = (rfb_full[DW] == rfb_full[DW-1])
                     ? rfb_full[DW-1:0]
                     : (rfb_full[DW] ? {1'b1, {(DW-1){1'b0}}}
                                     : {1'b0, {(DW-1){1'b1}}});

    // -------------------------------------------------------------------------
    // w[n] = R_fb + x[n]   with saturation
    // Both operands are in data Q-format - simple DW addition
    // -------------------------------------------------------------------------
    wire signed [DW:0]   wn_full;   // DW+1 to detect overflow
    wire signed [DW-1:0] wn_sat;
    assign wn_full = {R_fb[DW-1], R_fb} + {R_xn[DW-1], R_xn};
    assign wn_sat  = (wn_full[DW] == wn_full[DW-1])
                   ? wn_full[DW-1:0]
                   : (wn_full[DW] ? {1'b1, {(DW-1){1'b0}}}
                                  : {1'b0, {(DW-1){1'b1}}});

    // -------------------------------------------------------------------------
    // y[n] = (b2*S2 >> CSHIFT) + R_P1 + (b0*w[n] >> CSHIFT)
    //      = mac_sat(slot3) + R_P1 + b0_term
    // b0_term computed combinatorially from R_wn
    // -------------------------------------------------------------------------
    wire signed [AW-1:0] b0_prod;
    wire signed [AW-CSHIFT-1:0] b0_term;
    wire signed [DW-1:0] b0_sat;
    assign b0_prod = {{(AW-CW){b0[CW-1]}}, b0} * {{(AW-DW){R_wn[DW-1]}}, R_wn};
    assign b0_term = b0_prod[AW-1:CSHIFT];
    assign b0_sat  = (b0_prod[AW-1:DW+CSHIFT-1] == {(AW-DW-CSHIFT+1){b0_prod[AW-1]}})
                   ? b0_term[DW-1:0]
                   : (b0_prod[AW-1] ? {1'b1, {(DW-1){1'b0}}}
                                    : {1'b0, {(DW-1){1'b1}}});

    // Sum b2*S2_descaled + R_P1 + b0_term - use DW+2 bits for safety
    wire signed [DW+1:0] yn_full;
    wire signed [DW-1:0] yn_sat;
    assign yn_full = {{2{mac_sat[DW-1]}}, mac_sat}
                   + {{2{R_P1[DW-1]}},   R_P1}
                   + {{2{b0_sat[DW-1]}}, b0_sat};
    assign yn_sat  = (yn_full[DW+1:DW-1] == {3{yn_full[DW+1]}})
                   ? yn_full[DW-1:0]
                   : (yn_full[DW+1] ? {1'b1, {(DW-1){1'b0}}}
                                    : {1'b0, {(DW-1){1'b1}}});

    // -------------------------------------------------------------------------
    // Sequential datapath
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            R_w1    <= {DW{1'b0}};
            R_w2    <= {DW{1'b0}};
            S1      <= {DW{1'b0}};
            S2      <= {DW{1'b0}};
            R_P0    <= {DW{1'b0}};
            R_fb    <= {DW{1'b0}};
            R_P1    <= {DW{1'b0}};
            R_wn    <= {DW{1'b0}};
            y_valid <= 1'b0;
            y_out   <= {DW{1'b0}};
        end else begin
            y_valid <= 1'b0;
            case (slot)
                // Slot 0: snapshot; R_P0 = (-a1*w[n-1]) >> CSHIFT
                2'd0: begin
                    S1   <= R_w1;
                    S2   <= R_w2;
                    R_P0 <= mac_sat;
                end
                // Slot 1: R_fb = R_P0 + (-a2*S2) >> CSHIFT   (now saturated)
                2'd1: begin
                    R_fb <= rfb_sat;
                end
                // Slot 2: w[n] = sat(R_fb + x[n]); R_P1 = (b1*S1) >> CSHIFT
                2'd2: begin
                    R_wn <= wn_sat;
                    R_w1 <= wn_sat;
                    R_w2 <= R_w1;
                    R_P1 <= mac_sat;
                end
                // Slot 3: y[n] = b0*w[n] + b1*w[n-1] + b2*w[n-2]  (all descaled)
                2'd3: begin
                    y_out   <= yn_sat;
                    y_valid <= 1'b1;
                end
            endcase
        end
    end

endmodule
