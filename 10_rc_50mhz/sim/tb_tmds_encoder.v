// Vivado xsim testbench (the encoder is Digilent VHDL, so Icarus cannot run it).
// Drives the vendored TMDS_Encoder with blanking (control tokens) and active
// video (ramp + pseudo-random bytes), then
//  * decodes every 10-bit word per the DVI 1.0 spec and compares with the input,
//  * checks control tokens match the four DVI tokens,
//  * tracks the running disparity inside each active-video run and requires |cum| <= 10
//    (the TMDS encoder keeps it bounded; a broken counter drifts away).
`timescale 1ns/1ps
module tb_tmds_encoder;
    reg clk = 0;
    always #20 clk = ~clk;

    reg  [7:0] d = 0;
    reg        c0 = 0, c1 = 0, vde = 0;
    wire [9:0] q;
    TMDS_Encoder dut (.PixelClk(clk), .SerialClk(1'b0), .aRst(1'b0),
                      .pDataOutRaw(q), .pDataOut(d), .pC0(c0), .pC1(c1), .pVde(vde));

    // reference pipeline: encoder latency is 3 clocks (3 register stages)
    reg [7:0] d_p [0:3]; reg c0_p [0:3]; reg c1_p [0:3]; reg v_p [0:3];
    integer i;
    always @(posedge clk) begin
        d_p[0] <= d; c0_p[0] <= c0; c1_p[0] <= c1; v_p[0] <= vde;
        for (i = 1; i < 4; i = i + 1) begin
            d_p[i] <= d_p[i-1]; c0_p[i] <= c0_p[i-1]; c1_p[i] <= c1_p[i-1]; v_p[i] <= v_p[i-1];
        end
    end

    function [7:0] decode(input [9:0] w);
        reg [7:0] x; reg [7:0] y;
        begin
            x = w[9] ? ~w[7:0] : w[7:0];
            y[0] = x[0];
            y[1] = w[8] ? (x[1] ^ x[0]) : ~(x[1] ^ x[0]);
            y[2] = w[8] ? (x[2] ^ x[1]) : ~(x[2] ^ x[1]);
            y[3] = w[8] ? (x[3] ^ x[2]) : ~(x[3] ^ x[2]);
            y[4] = w[8] ? (x[4] ^ x[3]) : ~(x[4] ^ x[3]);
            y[5] = w[8] ? (x[5] ^ x[4]) : ~(x[5] ^ x[4]);
            y[6] = w[8] ? (x[6] ^ x[5]) : ~(x[6] ^ x[5]);
            y[7] = w[8] ? (x[7] ^ x[6]) : ~(x[7] ^ x[6]);
            decode = y;
        end
    endfunction

    function integer ones(input [9:0] w);
        integer k; begin ones = 0; for (k = 0; k < 10; k = k + 1) ones = ones + w[k]; end
    endfunction

    integer cum = 0, maxcum = 0, mincum = 0;
    integer n_data = 0, n_ctl = 0, errors = 0, started = 0;
    reg [9:0] tok;
    integer ncount = 0;
    always @(posedge clk) begin
        ncount <= ncount + 1;
        if (ncount > 8) begin   // pipeline filled
            if (v_p[2]) begin
                n_data = n_data + 1;
                if (decode(q) !== d_p[2]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL decode q=%b got=%h exp=%h", q, decode(q), d_p[2]);
                end
                cum = cum + (2 * ones(q) - 10);
                if (cum > maxcum) maxcum = cum;
                if (cum < mincum) mincum = cum;
                if (cum > 10 || cum < -10) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL disparity cum=%0d", cum);
                end
            end else begin
                n_ctl = n_ctl + 1;
                cum = 0;
                case ({c1_p[2], c0_p[2]})
                    2'b00: tok = 10'b1101010100;
                    2'b01: tok = 10'b0010101011;
                    2'b10: tok = 10'b0101010100;
                    2'b11: tok = 10'b1010101011;
                endcase
                if (q !== tok) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL control token q=%b exp=%b", q, tok);
                end
            end
        end
    end

    // stimulus: 3 phases, with blanking gaps carrying all four control codes
    integer n, run;
    reg [31:0] lfsr = 32'hACE1_2468;
    always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    initial begin
        // blanking, control combos
        repeat (20) begin @(negedge clk); vde = 0; c0 = lfsr[3]; c1 = lfsr[5]; d = lfsr[7:0]; end
        // phase 1: all 256 byte values in order, repeated 4 times (one long active run)
        @(negedge clk); vde = 1;
        for (n = 0; n < 1024; n = n + 1) begin d = n[7:0]; @(negedge clk); end
        // phase 2: random data in random-length runs with random control codes between
        for (run = 0; run < 400; run = run + 1) begin
            vde = 0; c0 = lfsr[2]; c1 = lfsr[9];
            repeat (4 + lfsr[3:0]) @(negedge clk);
            vde = 1;
            for (n = 0; n < 50 + lfsr[7:0]; n = n + 1) begin d = lfsr[15:8]; @(negedge clk); end
        end
        // phase 3: worst cases, constant values (heavy imbalance)
        vde = 0; repeat (6) @(negedge clk);
        vde = 1; for (n = 0; n < 300; n = n + 1) begin d = 8'hFF; @(negedge clk); end
        for (n = 0; n < 300; n = n + 1) begin d = 8'h00; @(negedge clk); end
        for (n = 0; n < 300; n = n + 1) begin d = 8'h80; @(negedge clk); end
        for (n = 0; n < 300; n = n + 1) begin d = (n[0]) ? 8'hFF : 8'h00; @(negedge clk); end
        vde = 0; repeat (10) @(negedge clk);
        $display("data words=%0d control words=%0d cum disparity min=%0d max=%0d errors=%0d",
                 n_data, n_ctl, mincum, maxcum, errors);
        if (errors == 0 && n_data > 10000) $display("TB_PASS"); else $display("TB_FAIL");
        $finish;
    end
endmodule
