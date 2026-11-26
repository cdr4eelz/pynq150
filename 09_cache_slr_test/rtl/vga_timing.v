// Video timing generator. Defaults: VESA 800x600 @ 60 Hz (the cs150/proj150 mode),
// 1056x628 total at a 40 MHz pixel clock, positive sync polarity (HS_NEG=VS_NEG=0).
// 640x480@60 (07): 640/16/96/48, 480/10/2/33, both NEG=1.
// One pixel per clock. All outputs are registered.
//   x,y        active-area coordinates, valid while de=1
//   de         data enable (active video)
//   hs,vs      sync signals, polarity set by HS_NEG/VS_NEG (1 = active low)
//   frame_tick one-clock pulse once per frame (first clock after the active area)
module vga_timing #(
    parameter H_ACT = 800, H_FP = 40, H_SYN = 128, H_BP = 88,
    parameter V_ACT = 600, V_FP = 1,  V_SYN = 4,   V_BP = 23,
    parameter HS_NEG = 0, VS_NEG = 0
) (
    input  wire        clk,
    input  wire        rst_n,       // synchronous to clk
    output reg  [11:0] x,
    output reg  [11:0] y,
    output reg         de,
    output reg         hs,
    output reg         vs,
    output reg         frame_tick
);
    localparam H_TOT = H_ACT + H_FP + H_SYN + H_BP;
    localparam V_TOT = V_ACT + V_FP + V_SYN + V_BP;

    reg [11:0] hc, vc;   // full-frame counters

    wire h_last = (hc == H_TOT - 1);
    wire v_last = (vc == V_TOT - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            hc <= 0; vc <= 0;
            x <= 0; y <= 0;
            de <= 0; hs <= (HS_NEG != 0); vs <= (VS_NEG != 0);
            frame_tick <= 0;
        end else begin
            hc <= h_last ? 12'd0 : hc + 12'd1;
            if (h_last) vc <= v_last ? 12'd0 : vc + 12'd1;

            // outputs describe the position hc,vc (one register stage later)
            x  <= hc;
            y  <= vc;
            de <= (hc < H_ACT) && (vc < V_ACT);
            hs <= ((hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SYN)) ? (HS_NEG == 0) : (HS_NEG != 0);
            vs <= ((vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SYN)) ? (VS_NEG == 0) : (VS_NEG != 0);
            frame_tick <= (hc == 0) && (vc == V_ACT);
        end
    end
endmodule
