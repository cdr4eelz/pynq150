// Minimal PL-only top for the PYNQ-Z2.
// The Zynq PS is unused: clocking comes from the 125 MHz board oscillator
// through an MMCM (clk_wiz_0), reset from BTN0, and UART I/O from Pmod A.
module pynq150_top (
    input  wire       sysclk,
    input  wire       btn0,
    input  wire       uart_rxd,
    output wire       uart_txd,
    output wire [3:0] led
);

    localparam CLK_FREQ = 125_000_000;
    localparam BAUD     = 115200;

    wire clk;
    wire locked;
    wire rst_async;
    wire rst;

    clk_wiz_0 u_clk_wiz (
        .clk_in1 (sysclk),
        .reset   (btn0),
        .clk_out1(clk),
        .locked  (locked)
    );

    // Stay in reset while the button is held or the MMCM is unlocked.
    assign rst_async = btn0 | ~locked;

    reg [2:0] rst_sync;
    always @(posedge clk or posedge rst_async) begin
        if (rst_async)
            rst_sync <= 3'b111;
        else
            rst_sync <= {rst_sync[1:0], 1'b0};
    end
    assign rst = rst_sync[2];

    wire rx_toggle;
    uart_echo #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_echo (
        .clk      (clk),
        .rst      (rst),
        .rxd      (uart_rxd),
        .txd      (uart_txd),
        .rx_toggle(rx_toggle)
    );

    // ~0.93 Hz heartbeat on the 125 MHz clock (2^27 cycles).
    reg [26:0] hb_cnt;
    always @(posedge clk) begin
        if (rst)
            hb_cnt <= 27'd0;
        else
            hb_cnt <= hb_cnt + 1'b1;
    end

    assign led[0] = hb_cnt[26];
    assign led[1] = rx_toggle;
    assign led[2] = locked;
    assign led[3] = 1'b0;

endmodule
