// Test pattern, one pixel per clock, 1 clock of latency.
//   y <  BAR_H : 8 colour bars (white yellow cyan green magenta red blue black)
//   y >= BAR_H : horizontal grey ramp
//   2-pixel mid-grey border at the edge of the active area
//   32x32 box that bounces around (position steps once per frame_tick);
//   it is drawn as the inverse of the pixel underneath.
// Output pixel is {r,g,b} 8 bits each; rgb2dvi wants {r,b,g}, see the top.
module test_pattern #(
    parameter H_ACT = 640, V_ACT = 480, BAR_H = 360,
    parameter BOX = 32, STEP_X = 3, STEP_Y = 2
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
    // bar index = x/80, exact for x in 0..639 (checked in the testbench)
    wire [23:0] xm  = x * 24'd205;
    wire [2:0]  bar = xm[16:14];
    wire [7:0]  ramp = xm[16:9];     // x*205/512, 0..255

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
            bx <= 12'd100; by <= 12'd60; dx <= 1'b0; dy <= 1'b0;
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
