// fb_core (09): the 08 framebuffer core plus the cs150 instruction and data
// caches and the ScanLineRunner, so every RequestController client used here
// is driven from the UART.
//
//   clk (FCLK0 100 MHz): UART command FSM ->
//       cache_ex (cs150 Cache x2)  -> RequestController inst_* and data_*
//       PixelFeeder (pixel_feeder_rc)        -> pixf_*  (read-only)
//       frame_drawer (08 full-frame paints)  -> fill_*  (write-only, was data_* in 08)
//       slr_rc (ScanLineRunner spans)        -> bpas_*  (write-only)
//     RequestController (cs150, unmodified; priority inst, data, gcmd, pixf,
//     fill, line, bpas) -> rc_axi_fifo_adapter (08 copy + patch 0001:
//     address-conflict check) -> AXI4 master (HP0).
//   pix_clk (40 MHz): vga_timing -> pf_video_sink / test_pattern -> vid_*.
//
// Memory (16 MiB window at BASE, byte offsets; PixelFeeder layout
// {frame[5:0], y[9:0], x[9:0], 2'b00}, 32-bit pixels 0x00RRGGBB):
//   +0 MiB unused (frame 0 = PixelFeeder local pattern), +4 MiB frame 1,
//   +8 MiB frame 2, +12 MiB cache test region (not displayed).
// Cache addresses are window-relative byte addresses (word w of a 32-byte
// block = pixel w, the same view frame_drawer, SLR and PixelFeeder use).
//
// UART 115200 8N1. 08 commands, unchanged (binary argument bytes):
//   'A' a0 a1 a2 a3  base address (LE, [4:0] forced 0)              -> 'K'
//   'S' n            show frame n (0 = PixelFeeder local pattern,
//                    1, 2 = DDR frames at base + n * 4 MiB)          -> 'K' / 'N' / '?'
//   'T' n            draw target frame n (1 or 2, default 1)         -> 'K' / '?'
//   'C'              clear target frame to black                     -> 'D'
//   'F' r g b        fill target frame with 0x00rrggbb               -> 'D'
//   'B' 'H' 'G' 'X'  bars / checkerboard / gradient / grid           -> 'D'
//                    (draw commands: 'N' before 'A'; 'E' on AXI error;
//                     'D' only once every write is in DDR)
//   'P' g            gap: idle cycles after each 32-byte line write  -> 'K'
//   'V'              toggle video source: 'V' = PixelFeeder, 'v' = test pattern
//   'Q'              toggle auto-resync on underflow: 'Q' on, 'q' off
//   'Z'              resync PixelFeeder now                          -> 'K'
//   'U'              "Us RRRR PPPP Wwwwwwwww\n" (W = cycles of the last draw / span)
// 09 commands: ASCII arguments, decimal or 0x hex, separated by spaces or
// commas, ended by '\n', '\r' or ';'. Every reply is one line ending in '\n'.
// Hex in replies: 8 upper-case digits. Errors: "?\n" (syntax / range),
// "N\n" (needs 'A' first), "E\n" (AXI error). h / m = hit / miss.
//   R addr [n]          D-cache read (n words)  n=1: "R dddddddd h|m cccccccc"
//                                               n>1: "R first last H=hits M=misses"
//   J addr [n]          I-cache read, same replies with 'J'
//   W addr data         D-cache write            "W h|m cccccccc"
//   D f addr n data     D-cache fill, word i = data+i      "D P hits misses"
//   D v addr n data     D-cache verify word i == data+i    "D P hits misses" /
//                                                          "D F addr got exp"
//   E addr [data]       write then same-line re-miss (D)
//   E x addr [data]     fill, write hit, 8 KiB conflict miss, re-miss (D)
//   O addr [data]       D-cache write then immediate I-cache fetch
//       all three reply "L P|F got exp cyc_write cyc_read h|m" (L = E, X or O;
//       the last field must be m for a real DDR re-fetch). Default data
//       0xA500nnnn (nnnn = sequence number).
//   M  / M c            "M IH=.. IM=.. IC=.. DH=.. DM=.. DC=.." hits, misses,
//                       stall cycles per cache (M c clears after the dump)
//   Y color             sticky SLR colour: <= 6 hex digits / <= 0xFFFFFF
//                       -> 0xFFrrggbb (fill on); 7-8 hex digits used as is
//                       (high byte 0 = edges only)                  -> "K"
//   L row x0 x1 [color] SLR span on the draw target ('T')             -> "D"
// Whitespace, CR, LF and ';' between commands are ignored.
module fb_core #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200,
    parameter WIN_AW   = 24,              // RC window: 16 MiB at the base
    // video mode (cs150 / proj150: VESA 800x600@60, 40 MHz, positive syncs)
    parameter H_ACT = 800, H_FP = 40, H_SYN = 128, H_BP = 88,
    parameter V_ACT = 600, V_FP = 1,  V_SYN = 4,   V_BP = 23,
    parameter [7:0] GAP_RESET = 8'd128
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          pix_clk,
    input  wire          pix_rst,
    input  wire          pix_locked,
    input  wire          rxd,
    output wire          txd,
    output reg           rx_toggle,
    output wire          pf_running,     // pix domain: sink locked to the stream
    output reg           uf_sticky,

    output wire [7:0]    vid_r, vid_g, vid_b,
    output wire          vid_de, vid_hs, vid_vs,
    output wire          frame_tick,

    output wire [0:0]    m_axi_awid,
    output wire [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output wire [2:0]    m_axi_awsize,
    output wire [1:0]    m_axi_awburst,
    output wire          m_axi_awlock,
    output wire [3:0]    m_axi_awcache,
    output wire [2:0]    m_axi_awprot,
    output wire [3:0]    m_axi_awqos,
    output wire [3:0]    m_axi_awregion,
    output wire          m_axi_awvalid,
    input  wire          m_axi_awready,
    output wire [63:0]   m_axi_wdata,
    output wire [7:0]    m_axi_wstrb,
    output wire          m_axi_wlast,
    output wire          m_axi_wvalid,
    input  wire          m_axi_wready,
    input  wire [0:0]    m_axi_bid,
    input  wire [1:0]    m_axi_bresp,
    input  wire          m_axi_bvalid,
    output wire          m_axi_bready,
    output wire [0:0]    m_axi_arid,
    output wire [31:0]   m_axi_araddr,
    output wire [7:0]    m_axi_arlen,
    output wire [2:0]    m_axi_arsize,
    output wire [1:0]    m_axi_arburst,
    output wire          m_axi_arlock,
    output wire [3:0]    m_axi_arcache,
    output wire [2:0]    m_axi_arprot,
    output wire [3:0]    m_axi_arqos,
    output wire [3:0]    m_axi_arregion,
    output wire          m_axi_arvalid,
    input  wire          m_axi_arready,
    input  wire [0:0]    m_axi_rid,
    input  wire [63:0]   m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready
);

    // ---------------- UART ----------------
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;
    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rxd(rxd), .valid(rx_valid), .data(rx_data));
    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .data_in(tx_data),
        .busy(tx_busy), .txd(txd));

    localparam MSG_LEN = 23;
    localparam MSGN = 80;

    // ---------------- RequestController + clients ----------------
    wire         rcon_caf_full, rcon_caf_wren;
    wire [33:0]  rcon_caf_cadr;
    wire         rcon_wdf_full, rcon_wdf_wren;
    wire [143:0] rcon_wdf_mdat;
    wire         rcon_rdf_rden, rcon_rdf_wren;
    wire [127:0] ALLR_rdf_data;          // read data goes to all readers (as in Memory150.v)

    wire         inst_caf_full, inst_caf_wren, inst_wdf_full, inst_wdf_wren;
    wire [33:0]  inst_caf_cadr;
    wire [143:0] inst_wdf_mdat;
    wire         inst_rdf_rden, inst_rdf_wren, inst_stall;
    wire         data_caf_full, data_caf_wren, data_wdf_full, data_wdf_wren;
    wire [33:0]  data_caf_cadr;
    wire [143:0] data_wdf_mdat;
    wire         data_rdf_rden, data_rdf_wren, data_stall;
    wire         pixf_raf_wren, pixf_raf_full, pixf_rdf_rden, pixf_rdf_wren;
    wire [30:0]  pixf_raf_addr;
    wire         fill_waf_full, fill_waf_wren, fill_wdf_full, fill_wdf_wren;
    wire [33:0]  fill_caf_cadr;
    wire [143:0] fill_wdf_mdat;
    wire         bpas_waf_full, bpas_waf_wren, bpas_wdf_full, bpas_wdf_wren;
    wire [30:0]  bpas_waf_addr;
    wire [143:0] bpas_wdf_mdat;

    reg  [31:0]  base_addr;
    reg          clr_err;
    wire         axi_err, bad_cmd, a_idle;
    wire [3:0]   peak_wr, peak_rd;

    // ---- frame_drawer (08), now on the FrameFiller (fill_*) port
    reg          d_start;
    reg  [2:0]   d_mode;
    reg  [23:0]  d_color;
    reg  [5:0]   d_frame;
    reg  [7:0]   d_gap;
    wire         d_busy, d_done;

    frame_drawer #(.H_ACT(H_ACT), .V_ACT(V_ACT)) u_draw (
        .clk(clk), .rst(rst), .start(d_start), .mode(d_mode), .color(d_color),
        .frame(d_frame), .gap(d_gap), .busy(d_busy), .done(d_done),
        .caf_wren(fill_waf_wren), .caf_cadr(fill_caf_cadr), .caf_full(fill_waf_full),
        .wdf_wren(fill_wdf_wren), .wdf_mdat(fill_wdf_mdat), .wdf_full(fill_wdf_full));

    // ---- ScanLineRunner (bpas_*)
    reg          s_start;
    reg  [9:0]   s_row, s_x0, s_x1;
    reg  [31:0]  s_color;
    wire         s_busy, s_done;
    slr_rc #(.SCREEN_WIDTH(H_ACT), .SCREEN_HEIGHT(V_ACT)) u_slr (
        .clk(clk), .rst(rst), .start(s_start), .row(s_row), .x0(s_x0), .x1(s_x1),
        .color(s_color), .frame(d_frame), .busy(s_busy), .done(s_done),
        .waf_wren(bpas_waf_wren), .waf_addr(bpas_waf_addr),
        .wdf_wren(bpas_wdf_wren), .wdf_mdat(bpas_wdf_mdat),
        .waf_full(bpas_waf_full), .wdf_full(bpas_wdf_full));

    // ---- cs150 ICache + DCache (inst_*, data_*)
    reg          c_start, c_clr;
    reg  [2:0]   c_op;
    reg  [31:0]  c_addr, c_data, c_count;
    wire         c_busy, c_done;
    wire [31:0]  cr_first, cr_last, cr_cyc_first, cr_hits, cr_miss, cr_got, cr_exp, cr_faddr,
                 cr_cyc_a, cr_cyc_b;
    wire         cr_hit_first, cr_pass, cr_final_miss;
    wire [31:0]  cnt_ih, cnt_im, cnt_ic, cnt_dh, cnt_dm, cnt_dc;
    cache_ex u_cache (
        .clk(clk), .rst(rst), .start(c_start), .op(c_op), .addr(c_addr), .data(c_data),
        .count(c_count), .clr_cnt(c_clr), .busy(c_busy), .done(c_done),
        .r_first(cr_first), .r_last(cr_last), .r_hit_first(cr_hit_first), .r_cyc_first(cr_cyc_first),
        .r_hits(cr_hits), .r_miss(cr_miss), .r_pass(cr_pass), .r_got(cr_got), .r_exp(cr_exp),
        .r_faddr(cr_faddr), .r_cyc_a(cr_cyc_a), .r_cyc_b(cr_cyc_b), .r_final_miss(cr_final_miss),
        .cnt_ih(cnt_ih), .cnt_im(cnt_im), .cnt_ic(cnt_ic),
        .cnt_dh(cnt_dh), .cnt_dm(cnt_dm), .cnt_dc(cnt_dc),
        .inst_caf_wren(inst_caf_wren), .inst_caf_cadr(inst_caf_cadr), .inst_wdf_wren(inst_wdf_wren),
        .inst_wdf_mdat(inst_wdf_mdat), .inst_rdf_rden(inst_rdf_rden), .inst_stall(inst_stall),
        .inst_caf_full(inst_caf_full), .inst_wdf_full(inst_wdf_full), .inst_rdf_wren(inst_rdf_wren),
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr), .data_wdf_wren(data_wdf_wren),
        .data_wdf_mdat(data_wdf_mdat), .data_rdf_rden(data_rdf_rden), .data_stall(data_stall),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full), .data_rdf_wren(data_rdf_wren),
        .rdf_data(ALLR_rdf_data));

    // ---- PixelFeeder (pixf_*)
    reg          resync;
    reg  [5:0]   show_frame;
    wire         pf_rst, pf_rst_pix;
    wire [15:0]  pf_status;
    wire         video_ready, video_valid;
    wire [31:0]  video;

    pixel_feeder_rc #(.SCREEN_WIDTH(H_ACT), .SCREEN_HEIGHT(V_ACT)) u_pf (
        .clk(clk), .rst(rst), .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(pix_locked),
        .resync(resync), .pf_rst(pf_rst), .pf_rst_pix(pf_rst_pix),
        .frame(show_frame), .pf_status(pf_status),
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_raf_full(pixf_raf_full),
        .pixf_rdf_rden(pixf_rdf_rden), .pixf_rdf_wren(pixf_rdf_wren), .rdf_data(ALLR_rdf_data),
        .video_ready(video_ready), .video_valid(video_valid), .video(video));

    RequestController req_con (
        .clk(clk), .rst(rst),
        .caf_full(rcon_caf_full), .wdf_full(rcon_wdf_full), .rdf_wren(rcon_rdf_wren),
        // Inst-cache
        .inst_caf_wren(inst_caf_wren), .inst_caf_cadr(inst_caf_cadr), .inst_wdf_wren(inst_wdf_wren),
        .inst_wdf_mdat(inst_wdf_mdat), .inst_rdf_rden(inst_rdf_rden), .inst_stall(inst_stall),
        // Data-cache
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr),
        .data_wdf_wren(data_wdf_wren), .data_wdf_mdat(data_wdf_mdat),
        .data_rdf_rden(data_rdf_rden), .data_stall(data_stall),
        .gcmd_raf_wren(1'b0), .gcmd_raf_addr(31'd0), .gcmd_rdf_rden(1'b0),
        // PixelFeeder (read-only)
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_rdf_rden(pixf_rdf_rden),
        // FrameFiller port: the 08 frame drawer (write-only)
        .fill_waf_wren(fill_waf_wren), .fill_waf_addr(fill_caf_cadr[30:0]),
        .fill_wdf_wren(fill_wdf_wren), .fill_wdf_mdat(fill_wdf_mdat),
        .line_waf_wren(1'b0), .line_waf_addr(31'd0), .line_wdf_wren(1'b0), .line_wdf_mdat(144'd0),
        // Bypass port: ScanLineRunner (write-only, as proj150's GPU uses it)
        .bpas_waf_wren(bpas_waf_wren), .bpas_waf_addr(bpas_waf_addr),
        .bpas_wdf_wren(bpas_wdf_wren), .bpas_wdf_mdat(bpas_wdf_mdat),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .rdf_rden(rcon_rdf_rden),
        .inst_caf_full(inst_caf_full), .inst_wdf_full(inst_wdf_full), .inst_rdf_wren(inst_rdf_wren),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full), .data_rdf_wren(data_rdf_wren),
        .gcmd_raf_full(), .gcmd_rdf_wren(),
        .pixf_raf_full(pixf_raf_full), .pixf_rdf_wren(pixf_rdf_wren),
        .fill_waf_full(fill_waf_full), .fill_wdf_full(fill_wdf_full),
        .line_waf_full(), .line_wdf_full(),
        .bpas_waf_full(bpas_waf_full), .bpas_wdf_full(bpas_wdf_full));

    rc_axi_fifo_adapter #(.WIN_AW(WIN_AW)) u_adapter (
        .clk(clk), .rst(rst), .base_addr(base_addr), .clr_err(clr_err),
        .axi_err(axi_err), .bad_cmd(bad_cmd), .peak_wr(peak_wr), .peak_rd(peak_rd), .idle(a_idle),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr), .caf_full(rcon_caf_full),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .wdf_full(rcon_wdf_full),
        .rdf_wren(rcon_rdf_wren), .rdf_data(ALLR_rdf_data), .rdf_rden(rcon_rdf_rden),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
        .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
        .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready));

    // ---------------- video (pix_clk) ----------------
    wire [11:0] x, y;
    wire        t_de, t_hs, t_vs;
    vga_timing #(
        .H_ACT(H_ACT), .H_FP(H_FP), .H_SYN(H_SYN), .H_BP(H_BP),
        .V_ACT(V_ACT), .V_FP(V_FP), .V_SYN(V_SYN), .V_BP(V_BP),
        .HS_NEG(0), .VS_NEG(0)
    ) u_timing (
        .clk(pix_clk), .rst_n(!pix_rst),
        .x(x), .y(y), .de(t_de), .hs(t_hs), .vs(t_vs), .frame_tick(frame_tick));

    wire [7:0] p_r, p_g, p_b, s_r, s_g, s_b;
    wire       p_de, p_hs, p_vs, s_de, s_hs, s_vs;
    test_pattern #(
        .H_ACT(800), .V_ACT(600), .BAR_H(450), .BOX(40), .STEP_X(4), .STEP_Y(3),
        .BAR_MUL(41), .BAR_SH(12), .RAMP_MUL(327), .RAMP_SH(10)
    ) u_pat (
        .clk(pix_clk), .rst_n(!pix_rst),
        .x(x), .y(y), .de_in(t_de), .hs_in(t_hs), .vs_in(t_vs), .frame_tick(frame_tick),
        .r(p_r), .g(p_g), .b(p_b), .de(p_de), .hs(p_hs), .vs(p_vs));

    wire uf_tog;
    pf_video_sink u_sink (
        .clk(pix_clk), .rst(pf_rst_pix),
        .x(x), .y(y), .de_in(t_de), .hs_in(t_hs), .vs_in(t_vs),
        .video_valid(video_valid), .video(video), .video_ready(video_ready),
        .r(s_r), .g(s_g), .b(s_b), .de(s_de), .hs(s_hs), .vs(s_vs),
        .running(pf_running), .uf_tog(uf_tog));

    reg src_pf;                              // clk domain: 1 = PixelFeeder
    (* ASYNC_REG = "TRUE" *) reg [1:0] src_s;
    always @(posedge pix_clk) src_s <= {src_s[0], src_pf};
    assign vid_r  = src_s[1] ? s_r  : p_r;
    assign vid_g  = src_s[1] ? s_g  : p_g;
    assign vid_b  = src_s[1] ? s_b  : p_b;
    assign vid_de = src_s[1] ? s_de : p_de;
    assign vid_hs = src_s[1] ? s_hs : p_hs;
    assign vid_vs = src_s[1] ? s_vs : p_vs;

    // ---------------- underflow events into clk ----------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] uf_s;
    always @(posedge clk) uf_s <= {uf_s[1:0], uf_tog};
    wire uf_event = uf_s[2] ^ uf_s[1];

    // ---------------- command FSM ----------------
    localparam ST_IDLE = 4'd0, ST_ARG = 4'd1, ST_DRAW = 4'd2, ST_TX = 4'd3,
               ST_ASC = 4'd4, ST_AEXEC = 4'd5, ST_CACHE = 4'd6, ST_SLR = 4'd7;
    localparam OP_DR = 3'd0, OP_JR = 3'd1, OP_DW = 3'd2, OP_FILL = 3'd3,
               OP_VER = 3'd4, OP_E = 3'd5, OP_EX = 3'd6, OP_O = 3'd7;
    reg [3:0]  state;
    reg [7:0]  cmd;
    reg [1:0]  arg_idx;
    reg [31:0] arg;
    reg        addr_set, auto_rs;
    reg [15:0] resyncs;
    reg [31:0] cyc, dcyc;
    reg        dfin;
    reg [7:0]  msg [0:MSGN-1];
    reg [6:0]  tx_len, tx_idx;

    // ASCII argument parser
    reg [31:0] acc;
    reg        in_num, hexm, zonly, perr;
    reg [3:0]  ndig;                 // hex digits after 0x / decimal digits
    reg [2:0]  nn;                   // numbers stored
    reg [31:0] nv0, nv1, nv2, nv3;
    reg [3:0]  wide;                 // number k was "32-bit" (see Y)
    reg [7:0]  sub;                  // optional sub-command letter (D f/v, E x, M c)
    reg [31:0] ycolor;               // sticky SLR colour
    reg [15:0] seq;                  // default data for E / O
    reg [7:0]  ccmd, csub;           // cache command being run (for the reply)

    function [7:0] tohex;
        input [3:0] n;
        begin
            tohex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    // number of argument bytes per 08 command
    function [2:0] nargs;
        input [7:0] c;
        begin
            case (c)
            "A": nargs = 3'd4;
            "F": nargs = 3'd3;
            "S", "T", "P": nargs = 3'd1;
            default: nargs = 3'd0;
            endcase
        end
    endfunction

    function is_ascii_cmd;
        input [7:0] c;
        begin
            case (c)
            "R", "J", "W", "D", "E", "O", "M", "Y", "L": is_ascii_cmd = 1'b1;
            default: is_ascii_cmd = 1'b0;
            endcase
        end
    endfunction

    function is_ws;   input [7:0] c; is_ws  = (c == " " || c == 8'h09 || c == ","); endfunction
    function is_term; input [7:0] c; is_term = (c == 8'h0A || c == 8'h0D || c == ";"); endfunction
    function is_dig;  input [7:0] c; is_dig = (c >= "0" && c <= "9"); endfunction
    function is_hexl; input [7:0] c; is_hexl = ((c >= "a" && c <= "f") || (c >= "A" && c <= "F")); endfunction
    function is_let;  input [7:0] c; is_let = ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z")); endfunction
    function [3:0] hexv;
        input [7:0] c;
        begin
            if (c >= "0" && c <= "9")      hexv = c[3:0];
            else                           hexv = c[3:0] + 4'd9;   // 'a'/'A' = 0x61/0x41 -> 1+9
        end
    endfunction
    // Y / L colour: <= 24-bit -> fill on (0xFF high byte); "wide" -> as given
    function [31:0] col32;
        input [31:0] v;
        input        w;
        begin
            col32 = w ? v : {8'hFF, v[23:0]};
        end
    endfunction

    integer k;

    task reply1;
        input [7:0] c;
        begin
            msg[0] <= c;
            tx_len <= 7'd1;
            tx_idx <= 7'd0;
            state  <= ST_TX;
        end
    endtask

    task reply_ln;                   // one char + '\n' (ASCII commands)
        input [7:0] c;
        begin
            msg[0] <= c;
            msg[1] <= 8'h0A;
            tx_len <= 7'd2;
            tx_idx <= 7'd0;
            state  <= ST_TX;
        end
    endtask

    task put_hex;                    // 8 hex digits at msg[p]
        input integer p;
        input [31:0] v;
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) msg[p+q] <= tohex(v[31-4*q -: 4]);
        end
    endtask

    task start_draw;
        input [2:0]  md;
        input [23:0] c;
        begin
            if (!addr_set) reply1("N");
            else begin
                d_mode  <= md;
                d_color <= c;
                d_start <= 1'b1;
                clr_err <= 1'b1;
                cyc     <= 32'd0;
                dfin    <= 1'b0;
                state   <= ST_DRAW;
            end
        end
    endtask

    task start_cache;
        input [2:0]  op;
        input [31:0] a;
        input [31:0] d;
        input [31:0] n;
        begin
            c_op    <= op;
            c_addr  <= a;
            c_data  <= d;
            c_count <= n;
            c_start <= 1'b1;
            clr_err <= 1'b1;
            ccmd    <= cmd;
            csub    <= sub;
            dfin    <= 1'b0;
            state   <= ST_CACHE;
        end
    endtask

    // 08 command execution, after all argument bytes are in (arg = little-endian)
    task exec;
        input [7:0]  c;
        input [31:0] a;
        begin
            case (c)
            "A": begin
                base_addr <= {a[31:5], 5'b00000};
                addr_set  <= 1'b1;
                reply1("K");
            end
            "S": begin
                if (a[7:0] > 8'd2) reply1("?");
                else if (a[7:0] != 8'd0 && !addr_set) reply1("N");
                else begin show_frame <= a[5:0]; reply1("K"); end
            end
            "T": begin
                if (a[7:0] == 8'd1 || a[7:0] == 8'd2) begin d_frame <= a[5:0]; reply1("K"); end
                else reply1("?");
            end
            "P": begin d_gap <= a[7:0]; reply1("K"); end
            "C": start_draw(3'd0, 24'h000000);
            "F": start_draw(3'd0, {a[7:0], a[15:8], a[23:16]});
            "B": start_draw(3'd1, 24'd0);
            "H": start_draw(3'd2, 24'd0);
            "G": start_draw(3'd3, 24'd0);
            "X": start_draw(3'd4, 24'd0);
            "V": begin src_pf <= ~src_pf; reply1(src_pf ? "v" : "V"); end
            "Q": begin auto_rs <= ~auto_rs; reply1(auto_rs ? "q" : "Q"); end
            "Z": begin resync <= 1'b1; resyncs <= resyncs + 16'd1; reply1("K"); end
            "U": begin
                msg[0] <= "U";
                msg[1] <= uf_sticky ? "1" : "0";
                msg[2] <= " ";
                for (k = 0; k < 4; k = k + 1) msg[3+k]  <= tohex(resyncs[15-4*k -: 4]);
                msg[7] <= " ";
                for (k = 0; k < 4; k = k + 1) msg[8+k]  <= tohex(pf_status[15-4*k -: 4]);
                msg[12] <= " "; msg[13] <= "W";
                for (k = 0; k < 8; k = k + 1) msg[14+k] <= tohex(dcyc[31-4*k -: 4]);
                msg[22] <= 8'h0A;
                // 23 chars; the sticky flag is cleared after the snapshot
                uf_sticky <= 1'b0;
                tx_len <= MSG_LEN[6:0];
                tx_idx <= 7'd0;
                state  <= ST_TX;
            end
            default: reply1("?");
            endcase
        end
    endtask

    // 09 ASCII command execution (nv0..nv3, nn, sub, wide are complete)
    wire [31:0] dflt = {16'hA500, seq};
    task exec_ascii;
        begin
            if (perr) reply_ln("?");
            else case (cmd)
            "R", "J": begin
                if (sub != 8'd0 || nn < 3'd1 || nn > 3'd2 || (nn == 3'd2 && nv1 == 32'd0)) reply_ln("?");
                else if (!addr_set) reply_ln("N");
                else start_cache((cmd == "R") ? OP_DR : OP_JR, nv0, 32'd0, (nn == 3'd2) ? nv1 : 32'd1);
            end
            "W": begin
                if (sub != 8'd0 || nn != 3'd2) reply_ln("?");
                else if (!addr_set) reply_ln("N");
                else start_cache(OP_DW, nv0, nv1, 32'd1);
            end
            "D": begin
                if ((sub != "f" && sub != "v") || nn != 3'd3 || nv1 == 32'd0) reply_ln("?");
                else if (!addr_set) reply_ln("N");
                else start_cache((sub == "f") ? OP_FILL : OP_VER, nv0, nv2, nv1);
            end
            "E", "O": begin
                if ((sub != 8'd0 && !(cmd == "E" && sub == "x")) || nn < 3'd1 || nn > 3'd2) reply_ln("?");
                else if (!addr_set) reply_ln("N");
                else begin
                    seq <= seq + 16'd1;
                    start_cache((cmd == "O") ? OP_O : ((sub == "x") ? OP_EX : OP_E),
                                nv0, (nn == 3'd2) ? nv1 : dflt, 32'd1);
                end
            end
            "M": begin
                if ((sub != 8'd0 && sub != "c") || nn != 3'd0) reply_ln("?");
                else begin
                    msg[0] <= "M";
                    msg[1]  <= " "; msg[2]  <= "I"; msg[3]  <= "H"; msg[4]  <= "="; put_hex(5,  cnt_ih);
                    msg[13] <= " "; msg[14] <= "I"; msg[15] <= "M"; msg[16] <= "="; put_hex(17, cnt_im);
                    msg[25] <= " "; msg[26] <= "I"; msg[27] <= "C"; msg[28] <= "="; put_hex(29, cnt_ic);
                    msg[37] <= " "; msg[38] <= "D"; msg[39] <= "H"; msg[40] <= "="; put_hex(41, cnt_dh);
                    msg[49] <= " "; msg[50] <= "D"; msg[51] <= "M"; msg[52] <= "="; put_hex(53, cnt_dm);
                    msg[61] <= " "; msg[62] <= "D"; msg[63] <= "C"; msg[64] <= "="; put_hex(65, cnt_dc);
                    msg[73] <= 8'h0A;
                    if (sub == "c") c_clr <= 1'b1;
                    tx_len <= 7'd74;
                    tx_idx <= 7'd0;
                    state  <= ST_TX;
                end
            end
            "Y": begin
                if (sub != 8'd0 || nn != 3'd1) reply_ln("?");
                else begin ycolor <= col32(nv0, wide[0]); reply_ln("K"); end
            end
            "L": begin
                if (sub != 8'd0 || nn < 3'd3 || nn > 3'd4 ||
                    nv0 >= V_ACT || nv1 >= H_ACT || nv2 >= H_ACT) reply_ln("?");
                else if (!addr_set) reply_ln("N");
                else begin
                    s_row   <= nv0[9:0];
                    s_x0    <= nv1[9:0];
                    s_x1    <= nv2[9:0];
                    s_color <= (nn == 3'd4) ? col32(nv3, wide[3]) : ycolor;
                    s_start <= 1'b1;
                    clr_err <= 1'b1;
                    cyc     <= 32'd0;
                    dfin    <= 1'b0;
                    state   <= ST_SLR;
                end
            end
            default: reply_ln("?");
            endcase
        end
    endtask

    // reply line for a finished cache command
    task cache_reply;
        begin
            tx_idx <= 7'd0;
            state  <= ST_TX;
            case (ccmd)
            "R", "J": begin
                msg[0] <= ccmd; msg[1] <= " ";
                if (c_count == 32'd1) begin
                    put_hex(2, cr_first); msg[10] <= " ";
                    msg[11] <= cr_hit_first ? "h" : "m"; msg[12] <= " ";
                    put_hex(13, cr_cyc_first); msg[21] <= 8'h0A;
                    tx_len <= 7'd22;
                end else begin
                    put_hex(2, cr_first); msg[10] <= " "; put_hex(11, cr_last);
                    msg[19] <= " "; msg[20] <= "H"; msg[21] <= "="; put_hex(22, cr_hits);
                    msg[30] <= " "; msg[31] <= "M"; msg[32] <= "="; put_hex(33, cr_miss);
                    msg[41] <= 8'h0A;
                    tx_len <= 7'd42;
                end
            end
            "W": begin
                msg[0] <= "W"; msg[1] <= " "; msg[2] <= cr_hit_first ? "h" : "m"; msg[3] <= " ";
                put_hex(4, cr_cyc_first); msg[12] <= 8'h0A;
                tx_len <= 7'd13;
            end
            "D": begin
                msg[0] <= "D"; msg[1] <= " ";
                if (cr_pass) begin
                    msg[2] <= "P"; msg[3] <= " "; put_hex(4, cr_hits); msg[12] <= " ";
                    put_hex(13, cr_miss); msg[21] <= 8'h0A;
                    tx_len <= 7'd22;
                end else begin
                    msg[2] <= "F"; msg[3] <= " "; put_hex(4, cr_faddr); msg[12] <= " ";
                    put_hex(13, cr_got); msg[21] <= " "; put_hex(22, cr_exp); msg[30] <= 8'h0A;
                    tx_len <= 7'd31;
                end
            end
            default: begin           // E, E x (X), O
                msg[0] <= (ccmd == "O") ? "O" : ((csub == "x") ? "X" : "E");
                msg[1] <= " "; msg[2] <= cr_pass ? "P" : "F"; msg[3] <= " ";
                put_hex(4, cr_got);    msg[12] <= " ";
                put_hex(13, cr_exp);   msg[21] <= " ";
                put_hex(22, cr_cyc_a); msg[30] <= " ";
                put_hex(31, cr_cyc_b); msg[39] <= " ";
                msg[40] <= cr_final_miss ? "m" : "h"; msg[41] <= 8'h0A;
                tx_len <= 7'd42;
            end
            endcase
        end
    endtask

    // finish the number being typed (if any)
    task end_num;
        begin
            if (in_num) begin
                if (hexm && ndig == 4'd0) perr <= 1'b1;
                else if (nn == 3'd4) perr <= 1'b1;
                else begin
                    case (nn)
                    3'd0: nv0 <= acc;
                    3'd1: nv1 <= acc;
                    3'd2: nv2 <= acc;
                    default: nv3 <= acc;
                    endcase
                    wide[nn[1:0]] <= hexm ? (ndig > 4'd6) : (acc > 32'h00FF_FFFF);
                    nn <= nn + 3'd1;
                end
                in_num <= 1'b0;
            end
        end
    endtask

    wire [35:0] dec_next = {4'd0, acc} * 36'd10 + {32'd0, rx_data[3:0]};

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; cmd <= 8'd0; arg_idx <= 2'd0; arg <= 32'd0;
            addr_set <= 1'b0; base_addr <= 32'd0; auto_rs <= 1'b1;
            resyncs <= 16'd0; cyc <= 32'd0; dcyc <= 32'd0; dfin <= 1'b0;
            tx_len <= 7'd0; tx_idx <= 7'd0; tx_start <= 1'b0; tx_data <= 8'd0;
            rx_toggle <= 1'b0; uf_sticky <= 1'b0;
            d_start <= 1'b0; d_mode <= 3'd0; d_color <= 24'd0; d_frame <= 6'd1; d_gap <= GAP_RESET;
            show_frame <= 6'd0; src_pf <= 1'b1; resync <= 1'b0; clr_err <= 1'b0;
            acc <= 32'd0; in_num <= 1'b0; hexm <= 1'b0; zonly <= 1'b0; perr <= 1'b0; ndig <= 4'd0;
            nn <= 3'd0; nv0 <= 32'd0; nv1 <= 32'd0; nv2 <= 32'd0; nv3 <= 32'd0; wide <= 4'd0;
            sub <= 8'd0; ycolor <= 32'hFF00_FF00; seq <= 16'd0; ccmd <= 8'd0; csub <= 8'd0;
            s_start <= 1'b0; s_row <= 10'd0; s_x0 <= 10'd0; s_x1 <= 10'd0; s_color <= 32'd0;
            c_start <= 1'b0; c_clr <= 1'b0; c_op <= 3'd0; c_addr <= 32'd0; c_data <= 32'd0;
            c_count <= 32'd1;
        end else begin
            tx_start <= 1'b0;
            d_start  <= 1'b0;
            s_start  <= 1'b0;
            c_start  <= 1'b0;
            c_clr    <= 1'b0;
            clr_err  <= 1'b0;
            resync   <= 1'b0;
            if (rx_valid) rx_toggle <= ~rx_toggle;

            // underflow: sticky flag, and (auto) restart PixelFeeder
            if (uf_event) begin
                uf_sticky <= 1'b1;
                if (auto_rs) begin
                    resync  <= 1'b1;
                    resyncs <= resyncs + 16'd1;
                end
            end

            case (state)
            ST_IDLE: if (rx_valid) begin
                cmd <= rx_data;
                arg <= 32'd0;
                arg_idx <= 2'd0;
                if (is_ws(rx_data) || is_term(rx_data)) ;            // ignored between commands
                else if (is_ascii_cmd(rx_data)) begin
                    acc <= 32'd0; in_num <= 1'b0; hexm <= 1'b0; zonly <= 1'b0; perr <= 1'b0;
                    ndig <= 4'd0; nn <= 3'd0; wide <= 4'd0; sub <= 8'd0;
                    state <= ST_ASC;
                end
                else if (nargs(rx_data) == 3'd0) exec(rx_data, 32'd0);
                else state <= ST_ARG;
            end
            ST_ARG: if (rx_valid) begin
                arg <= arg | ({24'd0, rx_data} << (8 * arg_idx));
                arg_idx <= arg_idx + 2'd1;
                if ({1'b0, arg_idx} + 3'd1 == nargs(cmd))
                    exec(cmd, arg | ({24'd0, rx_data} << (8 * arg_idx)));
            end
            ST_ASC: if (rx_valid) begin
                if (is_term(rx_data)) begin
                    end_num;
                    state <= ST_AEXEC;
                end else if (is_ws(rx_data)) begin
                    end_num;
                end else if (is_dig(rx_data)) begin
                    if (!in_num) begin
                        in_num <= 1'b1; hexm <= 1'b0; acc <= {28'd0, rx_data[3:0]};
                        zonly <= (rx_data == "0"); ndig <= 4'd1;
                    end else if (hexm) begin
                        if (acc[31:28] != 4'd0) perr <= 1'b1;
                        acc <= {acc[27:0], rx_data[3:0]};
                        if (ndig != 4'd15) ndig <= ndig + 4'd1;
                    end else begin
                        if (dec_next[35:32] != 4'd0) perr <= 1'b1;
                        acc <= dec_next[31:0];
                        zonly <= 1'b0;
                        if (ndig != 4'd15) ndig <= ndig + 4'd1;
                    end
                end else if ((rx_data == "x" || rx_data == "X") && in_num && zonly && !hexm) begin
                    hexm <= 1'b1; ndig <= 4'd0; zonly <= 1'b0;
                end else if (is_hexl(rx_data) && in_num && hexm) begin
                    if (acc[31:28] != 4'd0) perr <= 1'b1;
                    acc <= {acc[27:0], hexv(rx_data)};
                    if (ndig != 4'd15) ndig <= ndig + 4'd1;
                end else if (is_let(rx_data) && !in_num && nn == 3'd0 && sub == 8'd0) begin
                    sub <= rx_data | 8'h20;                          // lower case
                end else
                    perr <= 1'b1;
            end
            ST_AEXEC: exec_ascii;
            ST_DRAW: begin
                cyc <= cyc + 32'd1;
                if (d_done) dfin <= 1'b1;
                if ((d_done || dfin) && a_idle) begin
                    dfin <= 1'b0;
                    dcyc <= cyc;
                    reply1((axi_err || bad_cmd) ? "E" : "D");
                end
            end
            ST_SLR: begin
                cyc <= cyc + 32'd1;
                if (s_done) dfin <= 1'b1;
                if ((s_done || dfin) && a_idle) begin
                    dfin <= 1'b0;
                    dcyc <= cyc;
                    reply_ln((axi_err || bad_cmd) ? "E" : "D");
                end
            end
            ST_CACHE: begin
                if (c_done) dfin <= 1'b1;
                if ((c_done || dfin) && a_idle) begin
                    dfin <= 1'b0;
                    if (axi_err || bad_cmd) reply_ln("E");
                    else cache_reply;
                end
            end
            ST_TX: if (!tx_busy && !tx_start) begin
                if (tx_idx == tx_len) state <= ST_IDLE;
                else begin
                    tx_data  <= msg[tx_idx];
                    tx_start <= 1'b1;
                    tx_idx   <= tx_idx + 7'd1;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
