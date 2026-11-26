// frame_drawer: draws a whole frame into the framebuffer through the cs150
// RequestController's dcache ("data_*") port, using exactly the write
// handshake of cs150 Cache.v (WRITE1 / WRITE2, as 06's dcache_tester):
//   WRITE1  caf_wren, caf_cadr={3'b000, addr}, wdf_wren, wdf_mdat={mask, line[255:128]}
//   WRITE2  wdf_wren, wdf_mdat={mask, line[127:0]}
// One 32-byte line = 8 pixels. Pixel k (0..7) of the line is line[255-32k -: 32]
// (lowest address in the most significant word, as the cs150 big-endian
// cache does; PixelFeeder's 128->32 pixel FIFO reads the MSB word first, so
// this is the order it displays). Pixels are 32-bit 0x00RRGGBB.
// Framebuffer layout (PixelFeeder's): byte = {frame, y[9:0], x[9:0], 2'b00},
// i.e. 4096-byte line stride; RC address = byte >> 3.
//
// After each line write the drawer idles `gap` cycles, leaving RequestController
// slots for PixelFeeder (which has LOWER priority than the dcache port).
//
// Modes: 0 fill (color)   1 colour bars (8, white..black)   2 checkerboard
//        (32 px, white / dark grey)   3 gradient (R = x, G = y, B = 255 - x)
//        4 grid (black, white lines every 64 px, red border, green crosshair)
module frame_drawer #(
    parameter H_ACT = 800,
    parameter V_ACT = 600
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [2:0]    mode,
    input  wire [23:0]   color,
    input  wire [5:0]    frame,
    input  wire [7:0]    gap,
    output wire          busy,
    output reg           done,

    output wire          caf_wren,
    output wire [33:0]   caf_cadr,
    input  wire          caf_full,
    output wire          wdf_wren,
    output wire [143:0]  wdf_mdat,
    input  wire          wdf_full
);
    localparam IDLE = 3'd0, CALC = 3'd1, WRITE1 = 3'd2, WRITE2 = 3'd3, GAP = 3'd4;
    localparam CHUNKS = H_ACT / 8;
    // gradient scale: v * MUL >> 10 maps 0..N-1 onto 0..255
    localparam integer GX_MUL = 262143 / (H_ACT - 1);
    localparam integer GY_MUL = 262143 / (V_ACT - 1);

    reg [2:0]   cs;
    reg [6:0]   cx;
    reg [9:0]   y;
    reg [7:0]   gcnt;
    reg [255:0] line;
    reg [2:0]   m;
    reg [23:0]  col;
    reg [5:0]   fr;

    function [23:0] pix;
        input [2:0]  md;
        input [23:0] c;
        input [10:0] px;
        input [9:0]  py;
        reg   [2:0]  bar;
        reg   [7:0]  gx, gy;
        reg   [31:0] tx, ty;
        integer i;
        begin
            bar = 3'd0;
            for (i = 1; i < 8; i = i + 1)
                if (px >= (i * H_ACT) / 8) bar = i[2:0];
            tx = px * GX_MUL;  gx = tx[17:10];
            ty = py * GY_MUL;  gy = ty[17:10];
            case (md)
            3'd0: pix = c;
            3'd1: case (bar)
                      3'd0: pix = 24'hFFFFFF;  3'd1: pix = 24'hFFFF00;
                      3'd2: pix = 24'h00FFFF;  3'd3: pix = 24'h00FF00;
                      3'd4: pix = 24'hFF00FF;  3'd5: pix = 24'hFF0000;
                      3'd6: pix = 24'h0000FF;  default: pix = 24'h000000;
                  endcase
            3'd2: pix = (px[5] ^ py[5]) ? 24'h202020 : 24'hFFFFFF;
            3'd3: pix = {gx, gy, ~gx};
            3'd4: begin
                if (px == 0 || px == H_ACT - 1 || py == 0 || py == V_ACT - 1 ||
                    px == 1 || px == H_ACT - 2 || py == 1 || py == V_ACT - 2)
                    pix = 24'hFF0000;
                else if (px == H_ACT/2 - 1 || px == H_ACT/2 || py == V_ACT/2 - 1 || py == V_ACT/2)
                    pix = 24'h00FF00;
                else if (px[5:0] == 6'd0 || py[5:0] == 6'd0)
                    pix = 24'hFFFFFF;
                else
                    pix = 24'h000000;
            end
            default: pix = 24'h000000;
            endcase
        end
    endfunction

    integer k;
    reg [255:0] nl;
    always @(*) begin
        for (k = 0; k < 8; k = k + 1)
            nl[255 - 32*k -: 32] = {8'h00, pix(m, col, {cx, 3'b000} + k[10:0], y)};
    end

    wire [30:0] f_addr = {6'd0, fr, y, cx, 2'b00};   // byte >> 3
    wire        last   = (cx == CHUNKS - 1) && (y == V_ACT - 1);

    assign busy     = (cs != IDLE);
    assign caf_wren = (cs == WRITE1);
    assign caf_cadr = {3'b000, f_addr};
    assign wdf_wren = (cs == WRITE1) || (cs == WRITE2);
    assign wdf_mdat = (cs == WRITE1) ? {16'h0000, line[255:128]} : {16'h0000, line[127:0]};

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            cs <= IDLE; cx <= 7'd0; y <= 10'd0; gcnt <= 8'd0;
            m <= 3'd0; col <= 24'd0; fr <= 6'd1; line <= 256'd0;
        end else begin
            case (cs)
            IDLE: if (start) begin
                m <= mode; col <= color; fr <= frame;
                cx <= 7'd0; y <= 10'd0;
                cs <= CALC;
            end
            CALC: begin
                line <= nl;
                cs   <= WRITE1;
            end
            WRITE1: if (!wdf_full && !caf_full) cs <= WRITE2;
            WRITE2: if (!wdf_full) begin
                if (last) begin
                    cs   <= IDLE;
                    done <= 1'b1;
                end else begin
                    if (cx == CHUNKS - 1) begin cx <= 7'd0; y <= y + 10'd1; end
                    else                         cx <= cx + 7'd1;
                    gcnt <= gap;
                    cs   <= (gap == 8'd0) ? CALC : GAP;
                end
            end
            GAP: begin
                gcnt <= gcnt - 8'd1;
                if (gcnt == 8'd1) cs <= CALC;
            end
            default: cs <= IDLE;
            endcase
        end
    end
endmodule
