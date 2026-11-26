// Simple 8N1 UART receiver. Samples each bit at the midpoint.
// CLKS_PER_BIT is integer division of CLK_FREQ/BAUD (1085 at 125 MHz / 115200).
module uart_rx #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg        valid,
    output reg  [7:0] data
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;
    localparam CNT_W        = 16;

    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]      rx_sync;
    reg [1:0]      state;
    reg [CNT_W-1:0] clk_cnt;
    reg [2:0]      bit_idx;
    reg [7:0]      shifter;

    wire rx = rx_sync[1];

    always @(posedge clk) begin
        if (rst)
            rx_sync <= 2'b11;
        else
            rx_sync <= {rx_sync[0], rxd};
    end

    always @(posedge clk) begin
        if (rst) begin
            state   <= ST_IDLE;
            clk_cnt <= {CNT_W{1'b0}};
            bit_idx <= 3'd0;
            shifter <= 8'd0;
            data    <= 8'd0;
            valid   <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
                ST_IDLE: begin
                    clk_cnt <= {CNT_W{1'b0}};
                    bit_idx <= 3'd0;
                    if (rx == 1'b0)
                        state <= ST_START;
                end
                ST_START: begin
                    if (clk_cnt == HALF_BIT[CNT_W-1:0]) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        if (rx == 1'b0)
                            state <= ST_DATA;
                        else
                            state <= ST_IDLE; // spurious falling edge
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                ST_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT[CNT_W-1:0] - 1) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        shifter <= {rx, shifter[7:1]};
                        if (bit_idx == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                ST_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT[CNT_W-1:0] - 1) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        state   <= ST_IDLE;
                        if (rx == 1'b1) begin
                            data  <= shifter;
                            valid <= 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
