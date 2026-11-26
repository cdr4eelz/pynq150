// 08: HDMI (DVI) test pattern at the cs150/proj150 video mode, out of the PYNQ-Z2
// HDMI OUT port. No DDR. Mode: VESA 800x600 @ 60 Hz, 1056x628 total, 40.000 MHz
// pixel clock, positive syncs (cs150 ml505top.v:186-187 and proj150 VGAFramer.v:40-48).
//   fclk (PS7 FCLK_CLK0, 100 MHz) -> MMCM -> pixel clock + 5x serial clock
//   vga_timing -> test_pattern -> Digilent rgb2dvi (TMDS encoders,
//   OSERDESE2 10:1 master/slave, OBUFDS TMDS_33)
// Clocking: MMCM VCO 1000 MHz = 100 MHz * 10 / 1; pixel = VCO/25 = 40.000 MHz and
// serial = VCO/5 = 200.000 MHz (TMDS 400 Mbit/s per lane), both exact from FCLK0.
module hdmi_cs150_top (
    input  wire        fclk,        // PS7 FCLK_CLK0, 100 MHz
    input  wire        rst_n,       // PS7 FCLK_RESET0_N, active low
    input  wire        btn0,        // extra active-high reset
    output wire        hdmi_tx_clk_p,
    output wire        hdmi_tx_clk_n,
    output wire [2:0]  hdmi_tx_d_p,
    output wire [2:0]  hdmi_tx_d_n,
    output wire [3:0]  led
);
    // ---------------- clocking ----------------
    wire mmcm_rst = ~rst_n | btn0;
    wire clkfb_o, clkfb_i, pix_unbuf, ser_unbuf, locked;
    wire pix_clk, ser_clk;

    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(25.000),  // pixel clock, 40.000 MHz
        .CLKOUT1_DIVIDE(5)          // 5x serial clock, 200.000 MHz
    ) u_mmcm (
        .CLKIN1(fclk), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .CLKFBIN(clkfb_i), .CLKFBOUT(clkfb_o),
        .CLKOUT0(pix_unbuf), .CLKOUT1(ser_unbuf),
        .LOCKED(locked), .RST(mmcm_rst), .PWRDWN(1'b0),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0)
    );
    BUFG u_bufg_fb  (.I(clkfb_o),   .O(clkfb_i));
    BUFG u_bufg_pix (.I(pix_unbuf), .O(pix_clk));
    BUFG u_bufg_ser (.I(ser_unbuf), .O(ser_clk));

    // pixel-domain reset: asserted while the MMCM is unlocked, released
    // synchronously to pix_clk
    reg [1:0] prst_sync = 2'b00;
    always @(posedge pix_clk or negedge locked) begin
        if (!locked) prst_sync <= 2'b00;
        else         prst_sync <= {prst_sync[0], 1'b1};
    end
    wire pix_rst_n = prst_sync[1];

    // ---------------- video ----------------
    wire [11:0] x, y;
    wire        t_de, t_hs, t_vs, tick;
    // VESA 800x600@60: active 800x600, H FP 40 / sync 128 / BP 88 (total 1056),
    // V FP 1 / sync 4 / BP 23 (total 628), both syncs positive (HS_NEG=VS_NEG=0).
    vga_timing #(
        .H_ACT(800), .H_FP(40), .H_SYN(128), .H_BP(88),
        .V_ACT(600), .V_FP(1),  .V_SYN(4),   .V_BP(23),
        .HS_NEG(0), .VS_NEG(0)
    ) u_timing (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .x(x), .y(y), .de(t_de), .hs(t_hs), .vs(t_vs), .frame_tick(tick)
    );

    wire [7:0] r, g, b;
    wire       p_de, p_hs, p_vs;
    test_pattern #(
        .H_ACT(800), .V_ACT(600), .BAR_H(450), .BOX(40), .STEP_X(4), .STEP_Y(3),
        .BAR_MUL(41), .BAR_SH(12), .RAMP_MUL(327), .RAMP_SH(10)
    ) u_pat (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .x(x), .y(y), .de_in(t_de), .hs_in(t_hs), .vs_in(t_vs),
        .frame_tick(tick),
        .r(r), .g(g), .b(b), .de(p_de), .hs(p_hs), .vs(p_vs)
    );

    // Digilent rgb2dvi pixel format is {R[23:16], B[15:8], G[7:0]}
    // (Xilinx AXI4-Stream video RGB order), see rgb2dvi.vhd.
    rgb2dvi #(
        .kGenerateSerialClk(1'b0),   // we supply PixelClk and the 5x SerialClk
        .kClkPrimitive("MMCM"),
        .kClkRange(5),               // unused with external clocks
        .kRstActiveHigh(1'b0),
        .kD0Swap(1'b0), .kD1Swap(1'b0), .kD2Swap(1'b0), .kClkSwap(1'b0)
    ) u_rgb2dvi (
        .TMDS_Clk_p(hdmi_tx_clk_p), .TMDS_Clk_n(hdmi_tx_clk_n),
        .TMDS_Data_p(hdmi_tx_d_p),  .TMDS_Data_n(hdmi_tx_d_n),
        .aRst(1'b0), .aRst_n(locked),
        .vid_pData({r, b, g}),
        .vid_pVDE(p_de), .vid_pHSync(p_hs), .vid_pVSync(p_vs),
        .PixelClk(pix_clk), .SerialClk(ser_clk)
    );

    // ---------------- status LEDs ----------------
    reg [24:0] pcnt = 25'd0;   // pixel clock / 2^25 = 1.19 Hz toggle
    reg [26:0] fcnt = 27'd0;   // fclk / 2^27 = 0.75 Hz
    reg        ftog = 1'b0;
    always @(posedge pix_clk) pcnt <= pcnt + 25'd1;
    always @(posedge fclk)    fcnt <= fcnt + 27'd1;
    always @(posedge pix_clk) if (tick) ftog <= ~ftog;  // ~30 Hz toggle

    assign led[0] = locked;      // LD0: MMCM locked
    assign led[1] = pcnt[24];    // LD1: pixel clock alive (slow blink)
    assign led[2] = ftog;        // LD2: frame toggle (looks ~on, dim blink)
    assign led[3] = fcnt[26];    // LD3: FCLK0 alive (slow blink)
endmodule
