// slr_rc: the proj150 / cs150 ScanLineRunner (rtl/proj150/gpu/ScanLineRunner.v,
// byte-identical in both trees, copied verbatim) as the write-only bpas_*
// client of the cs150 RequestController. This wrapper only
//   * presents one span command (valid until SLR's ready is seen) and reports
//     busy / done (done = SLR back in IDLE after the span),
//   * passes the frame number in SLR_frame[27:22] (SLR's frame field),
//   * packs {wdf_mask, wdf_data} into the RC's 144-bit mdat.
// No address conversion: SLR's caf_addr = {6'b0, byte[27:3]} is already the
// cs150 RC unit (byte >> 3) and the PixelFeeder layout {frame, y, x, 2'b00}.
// (proj150's MemoryDDR shifts it to byte >> 1 for the Arty MIG; not here.)
// LITTLEWORDIAN=1 (the proj150 default) puts pixel 0 of each 8-pixel chunk in
// the MSB word of the first 128-bit beat, the same order frame_drawer and
// cs150 Cache use, so PixelFeeder shows it in the right place.
// Colours: SLR fills the span interior only if color_fill[31:24] != 0; the
// whole 32-bit value is written to memory (PixelFeeder displays [23:0]).
module slr_rc #(
    parameter SCREEN_WIDTH  = 800,
    parameter SCREEN_HEIGHT = 600
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [9:0]    row,
    input  wire [9:0]    x0,
    input  wire [9:0]    x1,
    input  wire [31:0]   color,          // edge and fill colour
    input  wire [5:0]    frame,
    output wire          busy,
    output reg           done,
    // RequestController bpas_* port (write-only)
    output wire          waf_wren,
    output wire [30:0]   waf_addr,
    output wire          wdf_wren,
    output wire [143:0]  wdf_mdat,
    input  wire          waf_full,
    input  wire          wdf_full
);
    localparam W_IDLE = 2'd0, W_REQ = 2'd1, W_RUN = 2'd2;
    reg [1:0]  ws;
    reg [9:0]  r_row, r_x0, r_x1;
    reg [31:0] r_col;
    reg [5:0]  r_fr;

    wire         slr_ready;
    wire [15:0]  mask;
    wire [127:0] wdata;

    ScanLineRunner #(
        .SCREEN_WIDTH(SCREEN_WIDTH), .SCREEN_HEIGHT(SCREEN_HEIGHT),
        .LITTLEWORDIAN(1), .SLR_COUNT(1)
    ) slr (
        .clk(clk), .rst(rst),
        .caf_full(waf_full), .wdf_full(wdf_full),
        .caf_wren(waf_wren), .caf_addr(waf_addr),
        .wdf_wren(wdf_wren), .wdf_data(wdata), .wdf_mask(mask),
        .SLRs_ready(slr_ready),
        .SLRs_valid(ws == W_REQ),
        .SLRs_frame({4'd0, r_fr, 22'd0}),
        .SLRs_color_edge(r_col),
        .SLRs_color_fill(r_col),
        .SLRs_row(r_row),
        .SLRs_col_start(r_x0),
        .SLRs_col_finish(r_x1));

    assign wdf_mdat = {mask, wdata};
    assign busy = (ws != W_IDLE);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            ws <= W_IDLE; r_row <= 10'd0; r_x0 <= 10'd0; r_x1 <= 10'd0; r_col <= 32'd0; r_fr <= 6'd1;
        end else case (ws)
            W_IDLE: if (start) begin
                r_row <= row; r_x0 <= x0; r_x1 <= x1; r_col <= color; r_fr <= frame;
                ws <= W_REQ;
            end
            W_REQ: if (slr_ready) ws <= W_RUN;           // accepted this cycle
            W_RUN: if (slr_ready) begin ws <= W_IDLE; done <= 1'b1; end
            default: ws <= W_IDLE;
        endcase
    end
endmodule
