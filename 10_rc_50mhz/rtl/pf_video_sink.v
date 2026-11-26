// pf_video_sink: takes PixelFeeder's pixel stream (video/valid/ready, pix_clk)
// onto the free-running 800x600 raster from vga_timing.
// PixelFeeder holds video_valid low until its pixel FIFO reaches the start
// level, and the first pixel it then offers is pixel (0,0) of a frame. The
// sink waits for the next active pixel (0,0) of the raster with valid high
// and from then on pulls exactly one pixel per active (DE) clock, like
// proj150's VGAFramer (which instead holds its counters until valid).
// If valid is low on an active pixel while running, the stream has slipped:
// running drops, the pixel is black, and uf_tog flips (an underflow event
// for the clk domain, which restarts PixelFeeder). Pixel format 0x00RRGGBB.
// Output is registered (1 clock, like test_pattern).
module pf_video_sink (
    input  wire        clk,
    input  wire        rst,           // also "resync": stop and wait
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        video_valid,
    input  wire [31:0] video,
    output wire        video_ready,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hs,
    output reg         vs,
    output reg         running,
    output reg         uf_tog
);
    wire start = !running && de_in && (x == 12'd0) && (y == 12'd0) && video_valid;
    assign video_ready = !rst && de_in && (running || start);
    wire take = video_ready && video_valid;

    always @(posedge clk) begin
        if (rst) begin
            running <= 1'b0;
        end else if (start) begin
            running <= 1'b1;
        end else if (running && de_in && !video_valid) begin
            running <= 1'b0;
            uf_tog  <= ~uf_tog;
        end
        {r, g, b} <= take ? video[23:0] : 24'd0;
        de <= de_in;
        hs <= hs_in;
        vs <= vs_in;
    end
    initial uf_tog = 1'b0;
endmodule
