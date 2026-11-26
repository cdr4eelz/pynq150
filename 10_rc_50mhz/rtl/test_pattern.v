// Test pattern, one pixel per clock, 1 clock of latency.
//   y <  BAR_H : 8 equal-width colour bars (white yellow cyan green magenta red blue black)
//   y >= BAR_H : horizontal grey ramp
//   2-pixel mid-grey border at the edge of the active area
//   BOXxBOX box that bounces around (position steps once per frame_tick);
//   it is drawn as the inverse of the pixel underneath.
// Output pixel is {r,g,b} 8 bits each; rgb2dvi wants {r,b,g}, see the top.
module test_pattern #(
    parameter H_ACT = 800, V_ACT = 600, BAR_H = 450,
    parameter BOX = 40, STEP_X = 4, STEP_Y = 3,
    // bar index = (x*BAR_MUL) >> BAR_SH must equal x/(H_ACT/8) for every x
    // (800: 41,12 -> x/100; 640: 205,14 -> x/80). The ramp is
    // (x*RAMP_MUL) >> RAMP_SH, 0..255 across the line (800: 327,10; 640: 205,9).
    // The testbench checks both for every x.
    parameter BAR_MUL = 41, BAR_SH = 12,
    parameter RAMP_MUL = 327, RAMP_SH = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        frame_tick,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hs,
    output reg         vs
);
    wire [31:0] xb   = x * BAR_MUL;
    wire [31:0] xr   = x * RAMP_MUL;
    wire [31:0] barw = xb >> BAR_SH;
    wire [31:0] rampw = xr >> RAMP_SH;
    wire [2:0]  bar  = barw[2:0];
    wire [7:0]  ramp = rampw[7:0];

    reg [7:0] pr, pg, pb;
    always @* begin
        if (y >= BAR_H) begin
            pr = ramp; pg = ramp; pb = ramp;
        end else begin
            case (bar)
                3'd0: begin pr = 8'hFF; pg = 8'hFF; pb = 8'hFF; end // white
                3'd1: begin pr = 8'hFF; pg = 8'hFF; pb = 8'h00; end // yellow
                3'd2: begin pr = 8'h00; pg = 8'hFF; pb = 8'hFF; end // cyan
                3'd3: begin pr = 8'h00; pg = 8'hFF; pb = 8'h00; end // green
                3'd4: begin pr = 8'hFF; pg = 8'h00; pb = 8'hFF; end // magenta
                3'd5: begin pr = 8'hFF; pg = 8'h00; pb = 8'h00; end // red
                3'd6: begin pr = 8'h00; pg = 8'h00; pb = 8'hFF; end // blue
                default: begin pr = 8'h00; pg = 8'h00; pb = 8'h00; end // black
            endcase
        end
    end

    wire border = (x < 2) || (x >= H_ACT - 2) || (y < 2) || (y >= V_ACT - 2);

    // bouncing box position (top-left), updated once per frame
    reg [11:0] bx, by;
    reg        dx, dy;     // 0 = increasing
    always @(posedge clk) begin
        if (!rst_n) begin
            bx <= 12'd100; by <= 12'd80; dx <= 1'b0; dy <= 1'b0;
        end else if (frame_tick) begin
            if (!dx) begin
                if (bx + BOX + STEP_X >= H_ACT) begin dx <= 1'b1; bx <= bx - STEP_X; end
                else bx <= bx + STEP_X;
            end else begin
                if (bx <= STEP_X) begin dx <= 1'b0; bx <= bx + STEP_X; end
                else bx <= bx - STEP_X;
            end
            if (!dy) begin
                if (by + BOX + STEP_Y >= V_ACT) begin dy <= 1'b1; by <= by - STEP_Y; end
                else by <= by + STEP_Y;
            end else begin
                if (by <= STEP_Y) begin dy <= 1'b0; by <= by + STEP_Y; end
                else by <= by - STEP_Y;
            end
        end
    end

    wire inbox = (x >= bx) && (x < bx + BOX) && (y >= by) && (y < by + BOX);

    always @(posedge clk) begin
        de <= de_in; hs <= hs_in; vs <= vs_in;
        if (!de_in) begin
            r <= 8'h00; g <= 8'h00; b <= 8'h00;
        end else if (border) begin
            r <= 8'h80; g <= 8'h80; b <= 8'h80;
        end else if (inbox) begin
            r <= ~pr; g <= ~pg; b <= ~pb;
        end else begin
            r <= pr; g <= pg; b <= pb;
        end
    end
endmodule
