// 11 top (from 10): PS7 block design (fb_ps: PS7 + SmartConnect -> S_AXI_HP0, JTAG-to-AXI,
// proc_sys_reset; the PL AXI master enters through the external BD port S_AXI) + MMCM
// (40 / 200 MHz from FCLK0 100 MHz) + sys_core on FCLK1 50 MHz + Digilent rgb2dvi.
// FCLK0 100 MHz clocks HP0 / SmartConnect / the adapter AXI side / the MMCM.
// FCLK1 50 MHz clocks the MIPS150 system: CPU, caches, RequestController, GPU, PixelFeeder
// memory side. The Pmod UART pins go to the CPU's UARTRVA (gios). BTN0 = system reset.
module mips_gpu_top (
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,
    input  wire        btn0,
    input  wire        uart_rxd,
    output wire        uart_txd,
    output wire        hdmi_tx_clk_p,
    output wire        hdmi_tx_clk_n,
    output wire [2:0]  hdmi_tx_d_p,
    output wire [2:0]  hdmi_tx_d_n,
    output wire [3:0]  led
);
    wire       axi_clk;          // FCLK0, 100 MHz
    wire       clk;              // FCLK1, 50 MHz
    wire       fclk_reset0_n, fclk_reset1_n;
    wire [0:0] aresetn;
    wire [0:0] ax_awid;
    wire [31:0] ax_awaddr;
    wire [7:0] ax_awlen;
    wire [2:0] ax_awsize;
    wire [1:0] ax_awburst;
    wire [0:0] ax_awlock;
    wire [3:0] ax_awcache;
    wire [2:0] ax_awprot;
    wire [3:0] ax_awqos;
    wire [0:0] ax_awvalid;
    wire [0:0] ax_awready;
    wire [63:0] ax_wdata;
    wire [7:0] ax_wstrb;
    wire [0:0] ax_wlast;
    wire [0:0] ax_wvalid;
    wire [0:0] ax_wready;
    wire [0:0] ax_bid;
    wire [1:0] ax_bresp;
    wire [0:0] ax_bvalid;
    wire [0:0] ax_bready;
    wire [0:0] ax_arid;
    wire [31:0] ax_araddr;
    wire [7:0] ax_arlen;
    wire [2:0] ax_arsize;
    wire [1:0] ax_arburst;
    wire [0:0] ax_arlock;
    wire [3:0] ax_arcache;
    wire [2:0] ax_arprot;
    wire [3:0] ax_arqos;
    wire [0:0] ax_arvalid;
    wire [0:0] ax_arready;
    wire [0:0] ax_rid;
    wire [63:0] ax_rdata;
    wire [1:0] ax_rresp;
    wire [0:0] ax_rlast;
    wire [0:0] ax_rvalid;
    wire [0:0] ax_rready;

    fb_ps_wrapper u_ps (
        .DDR_addr(DDR_addr), .DDR_ba(DDR_ba), .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n), .DDR_ck_p(DDR_ck_p), .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n), .DDR_dm(DDR_dm), .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n), .DDR_dqs_p(DDR_dqs_p), .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n), .DDR_reset_n(DDR_reset_n), .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn), .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio), .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb), .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .FCLK_CLK0(axi_clk), .FCLK_CLK1(clk),
        .FCLK_RESET0_N(fclk_reset0_n), .FCLK_RESET1_N(fclk_reset1_n),
        .peripheral_aresetn(aresetn),
        .S_AXI_awid(ax_awid),
        .S_AXI_awaddr(ax_awaddr),
        .S_AXI_awlen(ax_awlen),
        .S_AXI_awsize(ax_awsize),
        .S_AXI_awburst(ax_awburst),
        .S_AXI_awlock(ax_awlock),
        .S_AXI_awcache(ax_awcache),
        .S_AXI_awprot(ax_awprot),
        .S_AXI_awqos(ax_awqos),
        .S_AXI_awvalid(ax_awvalid),
        .S_AXI_awready(ax_awready),
        .S_AXI_wdata(ax_wdata),
        .S_AXI_wstrb(ax_wstrb),
        .S_AXI_wlast(ax_wlast),
        .S_AXI_wvalid(ax_wvalid),
        .S_AXI_wready(ax_wready),
        .S_AXI_bid(ax_bid),
        .S_AXI_bresp(ax_bresp),
        .S_AXI_bvalid(ax_bvalid),
        .S_AXI_bready(ax_bready),
        .S_AXI_arid(ax_arid),
        .S_AXI_araddr(ax_araddr),
        .S_AXI_arlen(ax_arlen),
        .S_AXI_arsize(ax_arsize),
        .S_AXI_arburst(ax_arburst),
        .S_AXI_arlock(ax_arlock),
        .S_AXI_arcache(ax_arcache),
        .S_AXI_arprot(ax_arprot),
        .S_AXI_arqos(ax_arqos),
        .S_AXI_arvalid(ax_arvalid),
        .S_AXI_arready(ax_arready),
        .S_AXI_rid(ax_rid),
        .S_AXI_rdata(ax_rdata),
        .S_AXI_rresp(ax_rresp),
        .S_AXI_rlast(ax_rlast),
        .S_AXI_rvalid(ax_rvalid),
        .S_AXI_rready(ax_rready)
    );

    // ---------------- clocking: MMCM still from FCLK0 100 MHz ----------------
    // VCO 1000 MHz = 100 MHz * 10; pixel 40.000 MHz (/25), serial 200.000 MHz (/5).
    // The 50 MHz RC clock is FCLK1, not an MMCM output, so the pixel clock stays exact.
    wire mmcm_rst = ~aresetn[0] | btn0;
    wire clkfb_o, clkfb_i, pix_unbuf, ser_unbuf, locked, pix_clk, ser_clk;
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.000), .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(25.000),  // pixel clock, 40.000 MHz
        .CLKOUT1_DIVIDE(5)          // 5x serial clock, 200.000 MHz
    ) u_mmcm (
        .CLKIN1(axi_clk), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .CLKFBIN(clkfb_i), .CLKFBOUT(clkfb_o),
        .CLKOUT0(pix_unbuf), .CLKOUT1(ser_unbuf),
        .LOCKED(locked), .RST(mmcm_rst), .PWRDWN(1'b0),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0)
    );
    BUFG u_bufg_fb  (.I(clkfb_o),   .O(clkfb_i));
    BUFG u_bufg_pix (.I(pix_unbuf), .O(pix_clk));
    BUFG u_bufg_ser (.I(ser_unbuf), .O(ser_clk));

    // resets: each domain from its FCLK reset + BTN0; pix domain from MMCM lock
    wire rst_async     = btn0 | ~fclk_reset1_n | ~fclk_reset0_n;
    wire axi_rst_async = btn0 | ~fclk_reset0_n | ~fclk_reset1_n;
    reg [2:0] rst_sync = 3'b111;
    always @(posedge clk or posedge rst_async)
        if (rst_async) rst_sync <= 3'b111;
        else           rst_sync <= {rst_sync[1:0], 1'b0};
    wire rst = rst_sync[2];

    reg [2:0] axi_rst_sync = 3'b111;
    always @(posedge axi_clk or posedge axi_rst_async)
        if (axi_rst_async) axi_rst_sync <= 3'b111;
        else               axi_rst_sync <= {axi_rst_sync[1:0], 1'b0};
    wire axi_rst = axi_rst_sync[2];

    reg [2:0] prst_sync = 3'b111;
    always @(posedge pix_clk or negedge locked)
        if (!locked) prst_sync <= 3'b111;
        else         prst_sync <= {prst_sync[1:0], 1'b0};
    wire pix_rst = prst_sync[2];

    wire [7:0] r, g, b;
    wire de, hs, vs, tick, rx_toggle, pf_running, uf_sticky, cpu_running;
    sys_core u_core (
        .clk(clk), .rst_in(rst), .axi_clk(axi_clk), .axi_rst(axi_rst),
        .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(locked),
        .rxd(uart_rxd), .txd(uart_txd), .rx_toggle(rx_toggle),
        .pf_running(pf_running), .uf_sticky(uf_sticky), .cpu_running(cpu_running),
        .vid_r(r), .vid_g(g), .vid_b(b), .vid_de(de), .vid_hs(hs), .vid_vs(vs),
        .frame_tick(tick),
        .m_axi_awregion(), .m_axi_arregion(),
        .m_axi_awid(ax_awid),
        .m_axi_awaddr(ax_awaddr),
        .m_axi_awlen(ax_awlen),
        .m_axi_awsize(ax_awsize),
        .m_axi_awburst(ax_awburst),
        .m_axi_awlock(ax_awlock),
        .m_axi_awcache(ax_awcache),
        .m_axi_awprot(ax_awprot),
        .m_axi_awqos(ax_awqos),
        .m_axi_awvalid(ax_awvalid),
        .m_axi_awready(ax_awready),
        .m_axi_wdata(ax_wdata),
        .m_axi_wstrb(ax_wstrb),
        .m_axi_wlast(ax_wlast),
        .m_axi_wvalid(ax_wvalid),
        .m_axi_wready(ax_wready),
        .m_axi_bid(ax_bid),
        .m_axi_bresp(ax_bresp),
        .m_axi_bvalid(ax_bvalid),
        .m_axi_bready(ax_bready),
        .m_axi_arid(ax_arid),
        .m_axi_araddr(ax_araddr),
        .m_axi_arlen(ax_arlen),
        .m_axi_arsize(ax_arsize),
        .m_axi_arburst(ax_arburst),
        .m_axi_arlock(ax_arlock),
        .m_axi_arcache(ax_arcache),
        .m_axi_arprot(ax_arprot),
        .m_axi_arqos(ax_arqos),
        .m_axi_arvalid(ax_arvalid),
        .m_axi_arready(ax_arready),
        .m_axi_rid(ax_rid),
        .m_axi_rdata(ax_rdata),
        .m_axi_rresp(ax_rresp),
        .m_axi_rlast(ax_rlast),
        .m_axi_rvalid(ax_rvalid),
        .m_axi_rready(ax_rready)
    );

    // Digilent rgb2dvi pixel format is {R[23:16], B[15:8], G[7:0]}
    rgb2dvi #(
        .kGenerateSerialClk(1'b0), .kClkPrimitive("MMCM"), .kClkRange(5),
        .kRstActiveHigh(1'b0),
        .kD0Swap(1'b0), .kD1Swap(1'b0), .kD2Swap(1'b0), .kClkSwap(1'b0)
    ) u_rgb2dvi (
        .TMDS_Clk_p(hdmi_tx_clk_p), .TMDS_Clk_n(hdmi_tx_clk_n),
        .TMDS_Data_p(hdmi_tx_d_p),  .TMDS_Data_n(hdmi_tx_d_n),
        .aRst(1'b0), .aRst_n(locked),
        .vid_pData({r, b, g}),
        .vid_pVDE(de), .vid_pHSync(hs), .vid_pVSync(vs),
        .PixelClk(pix_clk), .SerialClk(ser_clk)
    );

    // pf_running is in the pixel domain and drives an LED (false path)
    assign led[0] = cpu_running;  // LD0 CPU out of reset (adapter ready + 256 clk)
    assign led[1] = rx_toggle;    // LD1 toggles on each UART byte received
    assign led[2] = pf_running;   // LD2 video sink locked to the PixelFeeder stream
    assign led[3] = uf_sticky;    // LD3 PixelFeeder underflow seen since reset
endmodule
