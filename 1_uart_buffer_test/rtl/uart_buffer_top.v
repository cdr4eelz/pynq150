// PYNQ-Z2 PL-only top for the 256-byte UART buffer test.
// Same pinout and clocking as the original pynq150_top (125 MHz board
// oscillator through clk_wiz_0, BTN0 reset, Pmod A UART). uart_echo.v
// is not used; the original repo top is left unchanged.
module uart_buffer_top (
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
    wire rx_toggle;
    wire tx_phase;

    clk_wiz_0 u_clk_wiz (
        .clk_in1 (sysclk),
        .reset   (btn0),
        .clk_out1(clk),
        .locked  (locked)
    );

    assign rst_async = btn0 | ~locked;

    reg [2:0] rst_sync;
    always @(posedge clk or posedge rst_async) begin
        if (rst_async)
            rst_sync <= 3'b111;
        else
            rst_sync <= {rst_sync[1:0], 1'b0};
    end
    assign rst = rst_sync[2];

    uart_buffer #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_buf (
        .clk      (clk),
        .rst      (rst),
        .rxd      (uart_rxd),
        .txd      (uart_txd),
        .rx_toggle(rx_toggle),
        .tx_phase (tx_phase)
    );

    // ~0.93 Hz heartbeat on the 125 MHz clock (2^27 cycles).
    reg [26:0] hb_cnt;
    always @(posedge clk) begin
        if (rst)
            hb_cnt <= 27'd0;
        else
            hb_cnt <= hb_cnt + 1'b1;
    end

    assign led[0] = hb_cnt[26]; // LD0 heartbeat
    assign led[1] = rx_toggle;  // LD1 toggles on each received byte
    assign led[2] = locked;     // LD2 MMCM locked
    assign led[3] = tx_phase;   // LD3 high while replaying the buffer

endmodule
