// pixel_feeder_rc: the proj150 PixelFeeder (rtl/proj150/PixelFeeder.v, copied
// verbatim) as the "pixf" read-only client of the UNMODIFIED cs150
// RequestController. Nothing in PixelFeeder is edited; this wrapper only:
//
//  1. Address units. proj150's PixelFeeder drives a 28-bit raf_addr in
//     16-bit units (byte >> 1, for the Arty DDR3 MIG UI). cs150's
//     RequestController / Cache.v / our rc_axi_fifo_adapter use 31-bit
//     addresses in 8-byte units (byte >> 3, ML505 DDR2 MIG). Every
//     PixelFeeder request is 32-byte aligned, so  rc = raf_addr >> 2  is exact.
//     Byte address inside the RC window:
//         {frame[5:0], y[9:0], x[9:0], 2'b00}   (frame N at N * 4 MiB,
//          4096-byte line stride, 32-bit pixels 0x00RRGGBB)
//  2. Resync. PixelFeeder streams pixels with no frame marker, so after an
//     underflow the stream and the display are out of step for good. On
//     `resync` (or MMCM unlock) this wrapper holds PixelFeeder in reset
//     (cpu_rst_g and dvi_rst_g) for RST_CYC cycles AND until every pixf read
//     it already issued has come back from the RequestController, so no stale
//     beat lands in the freshly reset pixel FIFO. pf_rst_pix tells the video
//     sink to wait for a new start of frame.
//  3. Counts outstanding pixf beats (2 per request, as PixelFeeder does).
module pixel_feeder_rc #(
    parameter SCREEN_WIDTH  = 800,
    parameter SCREEN_HEIGHT = 600,
    parameter RST_CYC       = 256        // >= FIFO Generator reset requirement
) (
    input  wire          clk,            // memory side (FCLK0, 100 MHz)
    input  wire          rst,
    input  wire          pix_clk,        // video side (40 MHz)
    input  wire          pix_rst,
    input  wire          pix_locked,     // MMCM locked (async)
    input  wire          resync,         // pulse (clk): restart the feeder
    output reg           pf_rst,         // feeder held in reset (clk)
    output wire          pf_rst_pix,     // same, in the pix domain
    // frame select (clk)
    input  wire [5:0]    frame,          // 0 = PixelFeeder local pattern, 1.. = DDR frame
    output wire [15:0]   pf_status,
    // RequestController pixf_* port
    output wire          pixf_raf_wren,
    output wire [30:0]   pixf_raf_addr,
    input  wire          pixf_raf_full,
    output wire          pixf_rdf_rden,
    input  wire          pixf_rdf_wren,
    input  wire [127:0]  rdf_data,
    // video (pix_clk)
    input  wire          video_ready,
    output wire          video_valid,
    output wire [31:0]   video
);
    // ---- MMCM lock into clk
    (* ASYNC_REG = "TRUE" *) reg [1:0] lk_s;
    always @(posedge clk) lk_s <= {lk_s[0], pix_locked};

    // ---- reset sequencer (clk)
    reg  [8:0]  rcnt;
    reg  [7:0]  outst;                   // pixf beats requested, not yet returned
    wire        raf_wren28;
    wire [27:0] raf_addr28;
    wire        acc = pixf_raf_wren && !pixf_raf_full;

    always @(posedge clk) begin
        if (rst) begin
            pf_rst <= 1'b1;
            rcnt   <= 9'd0;
            outst  <= 8'd0;
        end else begin
            outst <= outst + (acc ? 8'd2 : 8'd0) - (pixf_rdf_wren ? 8'd1 : 8'd0);
            if (resync || !lk_s[1]) begin
                pf_rst <= 1'b1;
                rcnt   <= 9'd0;
            end else if (pf_rst) begin
                if (rcnt != RST_CYC[8:0]) rcnt <= rcnt + 9'd1;
                else if (outst == 8'd0)   pf_rst <= 1'b0;
            end
        end
    end

    // ---- PixelFeeder's own reset (also the pixel FIFO's async reset) is
    // asserted 16 cycles AFTER pf_rst, so the video sink (pf_rst_pix, ~3 pixel
    // clocks) has already stopped pulling when the FIFO empties; otherwise the
    // reset itself would look like an underflow. Released together with pf_rst.
    reg [15:0] pf_rst_d;
    always @(posedge clk) pf_rst_d <= rst ? 16'hFFFF : {pf_rst_d[14:0], pf_rst};
    wire feeder_rst = pf_rst & pf_rst_d[15];

    // ---- reset into the pix domain
    (* ASYNC_REG = "TRUE" *) reg [2:0] pr_s;
    always @(posedge pix_clk) pr_s <= {pr_s[1:0], pf_rst};
    assign pf_rst_pix = pr_s[2] | pix_rst;

    // ---- address: 16-bit units (proj150) -> 8-byte units (cs150 RC)
    assign pixf_raf_wren = raf_wren28;
    assign pixf_raf_addr = {5'd0, raf_addr28[27:2]};

    PixelFeeder #(
        .DVI_CLOCK_HZ(40_000_000),
        .SCREEN_WIDTH(SCREEN_WIDTH), .SCREEN_HEIGHT(SCREEN_HEIGHT),
        .COLT45_TESTPAT(0)
    ) pixfeed (
        .cpu_clk_g(clk),     .cpu_rst_g(feeder_rst),
        .dvi_clk_g(pix_clk), .dvi_rst_g(pf_rst_pix),
        .raf_full(pixf_raf_full), .raf_wren(raf_wren28), .raf_addr(raf_addr28),
        .rdf_rden(pixf_rdf_rden), .rdf_wren(pixf_rdf_wren), .rdf_data(rdf_data),
        .video_ready(video_ready), .video_valid(video_valid), .video(video),
        .pf_vframe(1'b1), .pf_wframe({26'd0, frame}),
        .pf_status(pf_status), .irq_frame()
    );
endmodule
