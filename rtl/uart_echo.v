// Echo each received 8N1 byte back out the transmitter.
// A one-byte holding register covers the case where a new byte finishes
// while a previous echo is still on the wire (continuous stream).
module uart_echo #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 115200
) (
    input  wire clk,
    input  wire rst,
    input  wire rxd,
    output wire txd,
    output reg  rx_toggle
);

    wire       rx_valid;
    wire [7:0] rx_data;
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

    reg        pend_valid;
    reg  [7:0] pend_data;

    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_rx (
        .clk  (clk),
        .rst  (rst),
        .rxd  (rxd),
        .valid(rx_valid),
        .data (rx_data)
    );

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_tx (
        .clk    (clk),
        .rst    (rst),
        .start  (tx_start),
        .data_in(tx_data),
        .busy   (tx_busy),
        .txd    (txd)
    );

    always @(posedge clk) begin
        if (rst) begin
            tx_start   <= 1'b0;
            tx_data    <= 8'd0;
            pend_valid <= 1'b0;
            pend_data  <= 8'd0;
            rx_toggle  <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (rx_valid) begin
                rx_toggle <= ~rx_toggle;
                if (!tx_busy && !tx_start) begin
                    tx_data  <= rx_data;
                    tx_start <= 1'b1;
                end else begin
                    pend_valid <= 1'b1;
                    pend_data  <= rx_data;
                end
            end else if (pend_valid && !tx_busy && !tx_start) begin
                tx_data    <= pend_data;
                tx_start   <= 1'b1;
                pend_valid <= 1'b0;
            end
        end
    end

endmodule
