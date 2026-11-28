// sys_core (11_mips_gpu): the cs150 system on the PYNQ-Z2, organised like cs150 Memory150.v +
// ml505top.v, with the ML505 MIG replaced by 10's rc_axi_fifo_adapter (HP0, 100 MHz) and the
// Chrontel DVI by 08's pf_video_sink -> rgb2dvi path.
//
//   clk (FCLK1 50 MHz): MIPS150 (CPU + MemBank: BIOS/ISR/X5/X6 BRAMs, MemMapIO, UARTRVA),
//       cs150 I$/D$ (Cache.v), cs150 RequestController, cs150 GPU (GraphicsProcessor on gcmd_*,
//       ScanLineRunner on bpas_*; fill_*/line_* unused exactly as in Memory150.v),
//       proj150 PixelFeeder (pixel_feeder_rc wrapper) on pixf_*, adapter command side.
//   axi_clk (FCLK0 100 MHz): adapter AXI side.   pix_clk (40 MHz): video.
//
// Memory: the adapter window is 2**WIN_AW = 256 MiB at BASE = 0x10000000, so CPU DRAM address
// 0x1xxxxxxx is physical 0x1xxxxxxx (identity; nothing else uses the upper 256 MiB in JTAG boot).
//
// Resets (cs150-style staging): rst_in (BTN0 / FCLK resets, from the top) -> rst_bus held until
// the adapter FIFOs are ready -> rst_cpu released CPU_RST_DLY cycles after rst_bus, so the CPU
// starts last, after the memory system and GPU.
module sys_core #(
    parameter CPU_FREQ = 50_000_000,      // MIPS150 / UARTRVA baud divider (sim: 16*115200)
    parameter [31:0] BASE = 32'h1000_0000,
    parameter WIN_AW   = 28,
    parameter CPU_RST_DLY = 256,
    parameter H_ACT = 800, H_FP = 40, H_SYN = 128, H_BP = 88,
    parameter V_ACT = 600, V_FP = 1,  V_SYN = 4,   V_BP = 23
) (
    input  wire          clk,
    input  wire          rst_in,
    input  wire          axi_clk,
    input  wire          axi_rst,
    input  wire          pix_clk,
    input  wire          pix_rst,
    input  wire          pix_locked,
    input  wire          rxd,
    output wire          txd,
    output reg           rx_toggle,      // toggles on every UART RX falling edge (LED)
    output wire          pf_running,     // pix domain: sink locked to the stream
    output reg           uf_sticky,      // a PixelFeeder underflow happened (cleared by reset)
    output wire          cpu_running,    // rst_cpu released

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

    // ---------------- reset staging ----------------
    wire a_ready;
    wire rst_bus = rst_in | ~a_ready;
    reg  [15:0] rcnt;
    reg         rst_cpu;
    always @(posedge clk) begin
        if (rst_bus) begin rcnt <= 16'd0; rst_cpu <= 1'b1; end
        else if (rcnt != CPU_RST_DLY[15:0]) rcnt <= rcnt + 16'd1;
        else rst_cpu <= 1'b0;
    end
    assign cpu_running = ~rst_cpu;

    // ---------------- UART pins (IOB registers, as ArtyA7top) ----------------
    wire cpu_tx, cpu_rx;
    (* IOB = "true" *) reg txd_q = 1'b1;
    (* IOB = "true" *) reg rxd_q = 1'b1;
    reg rxd_q2 = 1'b1, rxd_q3 = 1'b1;
    always @(posedge clk) begin
        txd_q  <= cpu_tx;
        rxd_q  <= rxd;
        rxd_q2 <= rxd_q;
        rxd_q3 <= rxd_q2;
    end
    assign txd    = txd_q;
    assign cpu_rx = rxd_q2;
    always @(posedge clk) if (rst_bus) rx_toggle <= 1'b0; else if (rxd_q3 && !rxd_q2) rx_toggle <= ~rx_toggle;

    // ---------------- CPU <-> caches / GPU wires ----------------
    wire [31:0] dcache_addr, icache_addr, dcache_din, icache_din, dcache_dout, icache_dout;
    wire [3:0]  dcache_we, icache_we;
    wire        dcache_re, icache_re, d_stall, i_stall;
    wire        pf_vframe, gp_vcode, gp_vframe;
    wire [31:0] pf_wframe, gp_wcode, gp_wframe, gp_rcode;
    wire [15:0] pf_status, gp_status;
    wire        irq_pf_frame, irq_gp_done;

    MIPS150 #(
        .CPU_FREQ(CPU_FREQ), .PC_BOOT(32'h4000_0000), .CPU_CORE("MIPS")
    ) CPU (
        .clk(clk), .rst(rst_cpu), .stall(d_stall || i_stall),
        .FPGA_SERIAL_RX(cpu_rx), .FPGA_SERIAL_TX(cpu_tx),
        .dcache_addr(dcache_addr), .icache_addr(icache_addr),
        .dcache_we(dcache_we),     .icache_we(icache_we),
        .dcache_re(dcache_re),     .icache_re(icache_re),
        .dcache_din(dcache_din),   .icache_din(icache_din),
        .dcache_dout(dcache_dout), .icache_dout(icache_dout),
        .pf_vframe(pf_vframe), .gp_vcode(gp_vcode), .gp_vframe(gp_vframe),
        .pf_wframe(pf_wframe), .gp_wcode(gp_wcode), .gp_wframe(gp_wframe),
        .gp_rcode(gp_rcode),
        .pf_status(pf_status), .gp_status(gp_status),
        .irq_pf_frame(irq_pf_frame), .irq_gp_done(irq_gp_done)
    );

    // ---------------- RequestController + clients (Memory150.v) ----------------
    wire         rcon_caf_full, rcon_caf_wren, rcon_caf_backlog;
    wire [33:0]  rcon_caf_cadr;
    wire         rcon_wdf_full, rcon_wdf_wren;
    wire [143:0] rcon_wdf_mdat;
    wire         rcon_rdf_rden, rcon_rdf_wren;
    wire [127:0] ALLR_rdf_data;

    wire         inst_caf_full, inst_caf_wren, inst_wdf_full, inst_wdf_wren, inst_rdf_rden, inst_rdf_wren;
    wire [33:0]  inst_caf_cadr;
    wire [143:0] inst_wdf_mdat;
    wire         data_caf_full, data_caf_wren, data_wdf_full, data_wdf_wren, data_rdf_rden, data_rdf_wren;
    wire [33:0]  data_caf_cadr;
    wire [143:0] data_wdf_mdat;
    wire         gcmd_raf_full, gcmd_raf_wren, gcmd_rdf_rden, gcmd_rdf_wren;
    wire [30:0]  gcmd_raf_addr;
    wire         pixf_raf_full, pixf_raf_wren, pixf_rdf_rden, pixf_rdf_wren;
    wire [30:0]  pixf_raf_addr;
    wire         bpas_waf_full, bpas_waf_wren, bpas_wdf_full, bpas_wdf_wren;
    wire [30:0]  bpas_waf_addr;
    wire [15:0]  bpas_wdf_mask;
    wire [127:0] bpas_wdf_data;

    Cache #(.LITTLEWORDIAN(1)) icache (
        .clk(clk), .rst(rst_bus),
        .addr(icache_addr), .din(icache_din), .we(icache_we), .re(icache_re),
        .caf_full(inst_caf_full), .wdf_full(inst_wdf_full), .rdf_wren(inst_rdf_wren), .rdf_data(ALLR_rdf_data),
        .stall(i_stall), .dout(icache_dout),
        .rdf_rden(inst_rdf_rden), .caf_cadr(inst_caf_cadr), .caf_wren(inst_caf_wren),
        .wdf_mdat(inst_wdf_mdat), .wdf_wren(inst_wdf_wren),
        .tag_hit(), .tag_valid(), .state());

    Cache #(.LITTLEWORDIAN(1)) dcache (
        .clk(clk), .rst(rst_bus),
        .addr(dcache_addr), .din(dcache_din), .we(dcache_we), .re(dcache_re),
        .caf_full(data_caf_full), .wdf_full(data_wdf_full), .rdf_wren(data_rdf_wren), .rdf_data(ALLR_rdf_data),
        .stall(d_stall), .dout(dcache_dout),
        .rdf_rden(data_rdf_rden), .caf_cadr(data_caf_cadr), .caf_wren(data_caf_wren),
        .wdf_mdat(data_wdf_mdat), .wdf_wren(data_wdf_wren),
        .tag_hit(), .tag_valid(), .state());

    GPU #(
        .SCREEN_WIDTH(H_ACT), .SCREEN_HEIGHT(V_ACT), .LITTLEWORDIAN(1)
    ) gpu (
        .clk(clk), .rst(rst_bus),
        .gp_vcode(gp_vcode), .gp_vframe(gp_vframe), .gp_wcode(gp_wcode), .gp_wframe(gp_wframe),
        .gp_rcode(gp_rcode), .gp_status(gp_status), .irq_gp_done(irq_gp_done),
        .gcmd_raf_full(gcmd_raf_full), .gcmd_raf_wren(gcmd_raf_wren), .gcmd_raf_addr(gcmd_raf_addr),
        .gcmd_rdf_rden(gcmd_rdf_rden), .gcmd_rdf_wren(gcmd_rdf_wren), .gcmd_rdf_data(ALLR_rdf_data),
        .slr_waf_full(bpas_waf_full), .slr_waf_wren(bpas_waf_wren), .slr_waf_addr(bpas_waf_addr),
        .slr_wdf_full(bpas_wdf_full), .slr_wdf_wren(bpas_wdf_wren),
        .slr_wdf_mask(bpas_wdf_mask), .slr_wdf_data(bpas_wdf_data));

    // PixelFeeder (proj150) with 10's wrapper; auto-resync on underflow as in 08-10
    wire        pf_rst, pf_rst_pix, video_ready, video_valid;
    wire [31:0] video;
    reg         resync;
    pixel_feeder_rc #(.SCREEN_WIDTH(H_ACT), .SCREEN_HEIGHT(V_ACT)) u_pf (
        .clk(clk), .rst(rst_bus), .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(pix_locked),
        .resync(resync), .pf_rst(pf_rst), .pf_rst_pix(pf_rst_pix),
        .pf_vframe(pf_vframe), .pf_wframe(pf_wframe), .irq_frame(irq_pf_frame), .pf_status(pf_status),
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_raf_full(pixf_raf_full),
        .pixf_rdf_rden(pixf_rdf_rden), .pixf_rdf_wren(pixf_rdf_wren), .rdf_data(ALLR_rdf_data),
        .video_ready(video_ready), .video_valid(video_valid), .video(video));

    RequestController req_con (
        .clk(clk), .rst(rst_bus),
        .caf_full(rcon_caf_full), .wdf_full(rcon_wdf_full), .caf_backlog(rcon_caf_backlog),
        .rdf_wren(rcon_rdf_wren),
        .inst_caf_wren(inst_caf_wren), .inst_caf_cadr(inst_caf_cadr), .inst_wdf_wren(inst_wdf_wren),
        .inst_wdf_mdat(inst_wdf_mdat), .inst_rdf_rden(inst_rdf_rden), .inst_stall(i_stall),
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr), .data_wdf_wren(data_wdf_wren),
        .data_wdf_mdat(data_wdf_mdat), .data_rdf_rden(data_rdf_rden), .data_stall(d_stall),
        .gcmd_raf_wren(gcmd_raf_wren), .gcmd_raf_addr(gcmd_raf_addr), .gcmd_rdf_rden(gcmd_rdf_rden),
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_rdf_rden(pixf_rdf_rden),
        .fill_waf_wren(1'b0), .fill_waf_addr(31'd0), .fill_wdf_wren(1'b0), .fill_wdf_mdat(144'd0),
        .line_waf_wren(1'b0), .line_waf_addr(31'd0), .line_wdf_wren(1'b0), .line_wdf_mdat(144'd0),
        .bpas_waf_wren(bpas_waf_wren), .bpas_waf_addr(bpas_waf_addr),
        .bpas_wdf_wren(bpas_wdf_wren), .bpas_wdf_mdat({bpas_wdf_mask, bpas_wdf_data}),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .rdf_rden(rcon_rdf_rden),
        .inst_caf_full(inst_caf_full), .inst_wdf_full(inst_wdf_full), .inst_rdf_wren(inst_rdf_wren),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full), .data_rdf_wren(data_rdf_wren),
        .gcmd_raf_full(gcmd_raf_full), .gcmd_rdf_wren(gcmd_rdf_wren),
        .pixf_raf_full(pixf_raf_full), .pixf_rdf_wren(pixf_rdf_wren),
        .fill_waf_full(), .fill_wdf_full(), .line_waf_full(), .line_wdf_full(),
        .bpas_waf_full(bpas_waf_full), .bpas_wdf_full(bpas_wdf_full));

    wire axi_err, bad_cmd, a_idle;
    wire [3:0] peak_wr, peak_rd;
    rc_axi_fifo_adapter #(.WIN_AW(WIN_AW)) u_adapter (
        .clk(clk), .rst(rst_in), .axi_clk(axi_clk), .axi_rst(axi_rst), .ready(a_ready),
        .base_addr(BASE), .clr_err(1'b0),
        .axi_err(axi_err), .bad_cmd(bad_cmd), .peak_wr(peak_wr), .peak_rd(peak_rd), .idle(a_idle),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr), .caf_full(rcon_caf_full),
        .caf_backlog(rcon_caf_backlog),
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

    wire uf_tog;
    pf_video_sink u_sink (
        .clk(pix_clk), .rst(pf_rst_pix),
        .x(x), .y(y), .de_in(t_de), .hs_in(t_hs), .vs_in(t_vs),
        .video_valid(video_valid), .video(video), .video_ready(video_ready),
        .r(vid_r), .g(vid_g), .b(vid_b), .de(vid_de), .hs(vid_hs), .vs(vid_vs),
        .running(pf_running), .uf_tog(uf_tog));

    // underflow -> sticky flag + PixelFeeder resync (08-10 auto-resync)
    (* ASYNC_REG = "TRUE" *) reg [2:0] uf_s;
    always @(posedge clk) uf_s <= {uf_s[1:0], uf_tog};
    wire uf_event = uf_s[2] ^ uf_s[1];
    always @(posedge clk) begin
        if (rst_bus) begin uf_sticky <= 1'b0; resync <= 1'b0; end
        else begin
            resync <= 1'b0;
            if (uf_event && !pf_rst) begin uf_sticky <= 1'b1; resync <= 1'b1; end
        end
    end
endmodule
