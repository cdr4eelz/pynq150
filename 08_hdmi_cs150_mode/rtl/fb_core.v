// fb_core: 08 framebuffer core (everything except the PS, MMCM and rgb2dvi).
//
//   clk (FCLK0 100 MHz):  UART command FSM -> frame_drawer -> RequestController
//       dcache port; PixelFeeder (proj150, via pixel_feeder_rc) -> RequestController
//       pixf port; RequestController (cs150, unmodified) -> rc_axi_fifo_adapter
//       (proj150 mig_* FIFOs) -> AXI4 master (HP0).
//   pix_clk (40 MHz):     vga_timing (800x600@60) -> pf_video_sink (PixelFeeder
//       pixels) or test_pattern (07/08 fallback) -> vid_* (to rgb2dvi).
//
// UART 115200 8N1, single characters (replies in quotes):
//   'A' a0 a1 a2 a3  base address (LE, [4:0] forced 0)              -> 'K'
//   'S' n            show frame n (0 = PixelFeeder local pattern,
//                    1, 2 = DDR frames at base + n * 4 MiB)          -> 'K' / 'N' / '?'
//   'T' n            draw target frame n (1 or 2, default 1)         -> 'K' / '?'
//   'C'              clear target frame to black                     -> 'D'
//   'F' r g b        fill target frame with 0x00rrggbb               -> 'D'
//   'B'              colour bars                                     -> 'D'
//   'H'              checkerboard (32 px)                            -> 'D'
//   'G'              gradient (R = x, G = y, B = 255 - x)            -> 'D'
//   'X'              grid / border / crosshair                       -> 'D'
//                    (draw commands: 'N' before 'A'; 'E' on AXI error;
//                     'D' only once every write is in DDR)
//   'P' g            gap: idle cycles after each 32-byte line write  -> 'K'
//   'V'              toggle video source: 'V' = PixelFeeder, 'v' = test pattern
//   'Q'              toggle auto-resync on underflow: 'Q' on, 'q' off
//   'Z'              resync PixelFeeder now                          -> 'K'
//   'U'              "Us RRRR PPPP Wwwwwwwww\n": s = underflow seen since the
//                    last 'U' (sticky, cleared by 'U'), RRRR = resyncs, PPPP =
//                    PixelFeeder pf_status, wwwwwwww = cycles of the last draw (hex)
//   anything else -> '?'
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
    localparam MSG_LEN = 23;               // "U" status line
    localparam MSG_MAX = 29;               // "R" probe line

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

    // ---------------- RequestController + clients ----------------
    wire         rcon_caf_full, rcon_caf_wren;
    wire [33:0]  rcon_caf_cadr;
    wire         rcon_wdf_full, rcon_wdf_wren;
    wire [143:0] rcon_wdf_mdat;
    wire         rcon_rdf_rden, rcon_rdf_wren;
    wire [127:0] ALLR_rdf_data;          // read data goes to all readers (as in Memory150.v)

    wire         data_caf_full, data_caf_wren;
    wire [33:0]  data_caf_cadr;
    wire         data_wdf_full, data_wdf_wren;
    wire [143:0] data_wdf_mdat;
    wire         pixf_raf_wren, pixf_raf_full, pixf_rdf_rden, pixf_rdf_wren;
    wire [30:0]  pixf_raf_addr;

    reg  [31:0]  base_addr;
    reg          clr_err;
    wire         axi_err, bad_cmd, a_idle;
    wire [3:0]   peak_wr, peak_rd;

    reg          d_start;
    reg  [2:0]   d_mode;
    reg  [23:0]  d_color;
    reg  [5:0]   d_frame;
    reg  [7:0]   d_gap;
    wire         d_busy, d_done;

    frame_drawer #(.H_ACT(H_ACT), .V_ACT(V_ACT)) u_draw (
        .clk(clk), .rst(rst), .start(d_start), .mode(d_mode), .color(d_color),
        .frame(d_frame), .gap(d_gap), .busy(d_busy), .done(d_done),
        .caf_wren(data_caf_wren), .caf_cadr(data_caf_cadr), .caf_full(data_caf_full),
        .wdf_wren(data_wdf_wren), .wdf_mdat(data_wdf_mdat), .wdf_full(data_wdf_full));

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
        .inst_caf_wren(1'b0), .inst_caf_cadr(34'd0), .inst_wdf_wren(1'b0),
        .inst_wdf_mdat(144'd0), .inst_rdf_rden(1'b0), .inst_stall(1'b0),
        // Data-cache: the frame drawer (write-only use of the port)
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr),
        .data_wdf_wren(data_wdf_wren), .data_wdf_mdat(data_wdf_mdat),
        .data_rdf_rden(1'b0), .data_stall(d_busy),
        .gcmd_raf_wren(1'b0), .gcmd_raf_addr(31'd0), .gcmd_rdf_rden(1'b0),
        // PixelFeeder (read-only)
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_rdf_rden(pixf_rdf_rden),
        .fill_waf_wren(1'b0), .fill_waf_addr(31'd0), .fill_wdf_wren(1'b0), .fill_wdf_mdat(144'd0),
        .line_waf_wren(1'b0), .line_waf_addr(31'd0), .line_wdf_wren(1'b0), .line_wdf_mdat(144'd0),
        .bpas_waf_wren(1'b0), .bpas_waf_addr(31'd0), .bpas_wdf_wren(1'b0), .bpas_wdf_mdat(144'd0),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .rdf_rden(rcon_rdf_rden),
        .inst_caf_full(), .inst_wdf_full(), .inst_rdf_wren(),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full), .data_rdf_wren(),
        .gcmd_raf_full(), .gcmd_rdf_wren(),
        .pixf_raf_full(pixf_raf_full), .pixf_rdf_wren(pixf_rdf_wren),
        .fill_waf_full(), .fill_wdf_full(), .line_waf_full(), .line_wdf_full(),
        .bpas_waf_full(), .bpas_wdf_full());

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

    // ---------------- debug probe ("R" x y) ----------------
    // pix domain: the pixel the sink takes at (probe_x, probe_y) each frame,
    // and the number of pixels taken in the last frame (480000 when locked).
    // clk domain: 2 * accepted pixf requests - pixf beats returned (= beats
    // still outstanding; 0..32 when nothing is lost or duplicated).
    // probe_x/y and the results are quasi-static (host waits a frame).
    reg  [11:0] probe_x, probe_y;            // clk domain
    reg  [31:0] probe_v, tk_cnt, tk_last;    // pix domain
    always @(posedge pix_clk) begin
        if (t_de && x == probe_x && y == probe_y)
            probe_v <= {video_ready && video_valid, video_valid, pf_running, 5'd0, video[23:0]};
        if (frame_tick) begin
            tk_last <= tk_cnt;
            tk_cnt  <= 32'd0;
        end else if (video_ready && video_valid) begin
            tk_cnt <= tk_cnt + 32'd1;
        end
    end
    reg  [31:0] acc_cnt, beat_cnt;
    always @(posedge clk) begin
        if (rst) begin
            acc_cnt <= 32'd0; beat_cnt <= 32'd0;
        end else begin
            if (pixf_raf_wren && !pixf_raf_full) acc_cnt <= acc_cnt + 32'd1;
            if (pixf_rdf_wren) beat_cnt <= beat_cnt + 32'd1;
        end
    end
    wire [31:0] pend_beats = {acc_cnt[30:0], 1'b0} - beat_cnt;

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
    localparam ST_IDLE = 3'd0, ST_ARG = 3'd1, ST_DRAW = 3'd2, ST_TX = 3'd3;
    reg [2:0]  state;
    reg [7:0]  cmd;
    reg [1:0]  arg_idx;
    reg [31:0] arg;
    reg        addr_set, auto_rs;
    reg [15:0] resyncs;
    reg [31:0] cyc, dcyc;
    reg        dfin;
    reg [7:0]  msg [0:MSG_MAX-1];
    reg [4:0]  tx_len, tx_idx;

    function [7:0] tohex;
        input [3:0] n;
        begin
            tohex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    // number of argument bytes per command
    function [2:0] nargs;
        input [7:0] c;
        begin
            case (c)
            "A", "R": nargs = 3'd4;
            "F": nargs = 3'd3;
            "S", "T", "P": nargs = 3'd1;
            default: nargs = 3'd0;
            endcase
        end
    endfunction

    integer k;

    task reply1;
        input [7:0] c;
        begin
            msg[0] <= c;
            tx_len <= 5'd1;
            tx_idx <= 5'd0;
            state  <= ST_TX;
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

    // command execution, after all argument bytes are in (arg = little-endian)
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
            "R": begin
                probe_x <= a[11:0];
                probe_y <= a[27:16];
                msg[0] <= "R"; msg[1] <= " ";
                for (k = 0; k < 8; k = k + 1) msg[2+k]  <= tohex(probe_v[31-4*k -: 4]);
                msg[10] <= " ";
                for (k = 0; k < 8; k = k + 1) msg[11+k] <= tohex(tk_last[31-4*k -: 4]);
                msg[19] <= " ";
                for (k = 0; k < 8; k = k + 1) msg[20+k] <= tohex(pend_beats[31-4*k -: 4]);
                msg[28] <= 8'h0A;
                tx_len <= 5'd29;
                tx_idx <= 5'd0;
                state  <= ST_TX;
            end
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
                tx_len <= MSG_LEN[4:0];
                tx_idx <= 5'd0;
                state  <= ST_TX;
            end
            default: reply1("?");
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; cmd <= 8'd0; arg_idx <= 2'd0; arg <= 32'd0;
            addr_set <= 1'b0; base_addr <= 32'd0; auto_rs <= 1'b1;
            resyncs <= 16'd0; cyc <= 32'd0; dcyc <= 32'd0; dfin <= 1'b0;
            tx_len <= 5'd0; tx_idx <= 5'd0; tx_start <= 1'b0; tx_data <= 8'd0;
            rx_toggle <= 1'b0; uf_sticky <= 1'b0;
            d_start <= 1'b0; d_mode <= 3'd0; d_color <= 24'd0; d_frame <= 6'd1; d_gap <= GAP_RESET;
            probe_x <= 12'd0; probe_y <= 12'd0;
            show_frame <= 6'd0; src_pf <= 1'b1; resync <= 1'b0; clr_err <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            d_start  <= 1'b0;
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
                if (nargs(rx_data) == 3'd0) exec(rx_data, 32'd0);
                else state <= ST_ARG;
            end
            ST_ARG: if (rx_valid) begin
                arg <= arg | ({24'd0, rx_data} << (8 * arg_idx));
                arg_idx <= arg_idx + 2'd1;
                if ({1'b0, arg_idx} + 3'd1 == nargs(cmd))
                    exec(cmd, arg | ({24'd0, rx_data} << (8 * arg_idx)));
            end
            ST_DRAW: begin
                cyc <= cyc + 32'd1;
                if (d_done) dfin <= 1'b1;
                if ((d_done || dfin) && a_idle) begin
                    dfin <= 1'b0;
                    dcyc <= cyc;
                    reply1((axi_err || bad_cmd) ? "E" : "D");
                end
            end
            ST_TX: if (!tx_busy && !tx_start) begin
                if (tx_idx == tx_len) state <= ST_IDLE;
                else begin
                    tx_data  <= msg[tx_idx];
                    tx_start <= 1'b1;
                    tx_idx   <= tx_idx + 5'd1;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
