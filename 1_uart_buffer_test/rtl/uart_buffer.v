// 256-byte UART buffer test (no AXI).
// Receive 256 bytes at 115200 8N1 into a local distributed-RAM buffer,
// then play them back in order on the transmitter. After the last byte
// is sent, return to receiving. No TX starts until all 256 bytes have
// arrived. Reuses rtl/uart_rx.v and rtl/uart_tx.v.
module uart_buffer #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 115200,
    parameter NBYTES   = 256
) (
    input  wire clk,
    input  wire rst,
    input  wire rxd,
    output wire txd,
    output reg  rx_toggle,
    output wire tx_phase
);

    localparam ST_RX = 1'b0;
    localparam ST_TX = 1'b1;

    wire       rx_valid;
    wire [7:0] rx_data;
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

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

    // 256 x 8, expected to infer distributed RAM.
    reg [7:0] buf_mem [0:NBYTES-1];
    reg       state;
    reg [7:0] idx;

    assign tx_phase = (state == ST_TX);

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_RX;
            idx       <= 8'd0;
            tx_start  <= 1'b0;
            tx_data   <= 8'd0;
            rx_toggle <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                ST_RX: begin
                    if (rx_valid) begin
                        buf_mem[idx] <= rx_data;
                        rx_toggle    <= ~rx_toggle;
                        if (idx == 8'd255) begin // last of NBYTES=256
                            idx   <= 8'd0;
                            state <= ST_TX;
                        end else begin
                            idx <= idx + 8'd1;
                        end
                    end
                end
                ST_TX: begin
                    if (!tx_busy && !tx_start) begin
                        tx_data  <= buf_mem[idx];
                        tx_start <= 1'b1;
                        if (idx == 8'd255) begin
                            idx   <= 8'd0;
                            state <= ST_RX;
                        end else begin
                            idx <= idx + 8'd1;
                        end
                    end
                end
                default: state <= ST_RX;
            endcase
        end
    end

endmodule
