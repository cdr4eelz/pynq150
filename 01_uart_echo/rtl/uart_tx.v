// Simple 8N1 UART transmitter. Assert start for one cycle with data_in
// when busy is low. The start bit begins on the following cycle.
module uart_tx #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data_in,
    output reg        busy,
    output reg        txd
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam CNT_W        = 16;

    localparam ST_IDLE = 1'b0;
    localparam ST_BITS = 1'b1;

    reg             state;
    reg [CNT_W-1:0] clk_cnt;
    reg [3:0]       bit_idx;
    reg [9:0]       shifter;

    always @(posedge clk) begin
        if (rst) begin
            state   <= ST_IDLE;
            clk_cnt <= {CNT_W{1'b0}};
            bit_idx <= 4'd0;
            shifter <= 10'h3FF;
            busy    <= 1'b0;
            txd     <= 1'b1;
        end else begin
            case (state)
                ST_IDLE: begin
                    txd     <= 1'b1;
                    clk_cnt <= {CNT_W{1'b0}};
                    bit_idx <= 4'd0;
                    if (start) begin
                        // start, 8 data bits LSB first, stop
                        shifter <= {1'b1, data_in, 1'b0};
                        busy    <= 1'b1;
                        state   <= ST_BITS;
                    end else begin
                        busy <= 1'b0;
                    end
                end
                ST_BITS: begin
                    txd <= shifter[0];
                    if (clk_cnt == CLKS_PER_BIT[CNT_W-1:0] - 1) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        shifter <= {1'b1, shifter[9:1]};
                        if (bit_idx == 4'd9) begin
                            state <= ST_IDLE;
                            busy  <= 1'b0;
                            txd   <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
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
