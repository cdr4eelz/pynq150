// UART-driven 64-bit AXI4 master: buffer 256 bytes, write them to a
// runtime-set DDR address, read them back, compare, and report over UART.
//
// Host -> DUT  (115200 8N1):
//   4-byte little-endian destination address, then 256 data bytes.
//   Bits [2:0] of the address are ignored (forced 8-byte aligned).
//   The transfer is one 32-beat INCR burst, split if it would cross a
//   4 KB boundary.
//
// DUT -> host, after the AXI write, AXI read-back and compare:
//   a 16-byte ASCII line
//     "PASS 0x000 0x00\n"
//     "FAIL 0xMMM 0xII\n"
//   MMM is the mismatch count (0..100 hex = 256) and II is the first
//   mismatched byte index (00..FF). Both are zero on PASS. An AXI
//   response other than OKAY also produces FAIL (the count may be 0).
//
// Then the FSM returns to receiving the next address.
module uart_axi_ddr_test #(
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD       = 115200,
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 64,
    parameter AXI_ID_W   = 1
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    rxd,
    output wire                    txd,
    output reg                     rx_toggle,
    output reg                     last_pass,
    output wire                    rx_phase,

    output wire [AXI_ID_W-1:0]     m_axi_awid,
    output reg  [AXI_ADDR_W-1:0]   m_axi_awaddr,
    output reg  [7:0]              m_axi_awlen,
    output wire [2:0]              m_axi_awsize,
    output wire [1:0]              m_axi_awburst,
    output wire                    m_axi_awlock,
    output wire [3:0]              m_axi_awcache,
    output wire [2:0]              m_axi_awprot,
    output wire [3:0]              m_axi_awqos,
    output wire [3:0]              m_axi_awregion,
    output reg                     m_axi_awvalid,
    input  wire                    m_axi_awready,

    output wire [AXI_DATA_W-1:0]   m_axi_wdata,
    output wire [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output wire                    m_axi_wlast,
    output reg                     m_axi_wvalid,
    input  wire                    m_axi_wready,

    input  wire [AXI_ID_W-1:0]     m_axi_bid,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output reg                     m_axi_bready,

    output wire [AXI_ID_W-1:0]     m_axi_arid,
    output reg  [AXI_ADDR_W-1:0]   m_axi_araddr,
    output reg  [7:0]              m_axi_arlen,
    output wire [2:0]              m_axi_arsize,
    output wire [1:0]              m_axi_arburst,
    output wire                    m_axi_arlock,
    output wire [3:0]              m_axi_arcache,
    output wire [2:0]              m_axi_arprot,
    output wire [3:0]              m_axi_arqos,
    output wire [3:0]              m_axi_arregion,
    output reg                     m_axi_arvalid,
    input  wire                    m_axi_arready,

    input  wire [AXI_ID_W-1:0]     m_axi_rid,
    input  wire [AXI_DATA_W-1:0]   m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire                    m_axi_rvalid,
    output reg                     m_axi_rready
);

    localparam BYTES     = 256;
    localparam BEATS_ALL = 32;
    localparam STRB_W    = AXI_DATA_W / 8;

    localparam ST_RX_ADDR = 4'd0;
    localparam ST_RX_DATA = 4'd1;
    localparam ST_CALC_W  = 4'd2;
    localparam ST_AW      = 4'd3;
    localparam ST_W       = 4'd4;
    localparam ST_B       = 4'd5;
    localparam ST_CALC_R  = 4'd6;
    localparam ST_AR      = 4'd7;
    localparam ST_R       = 4'd8;
    localparam ST_TX      = 4'd9;

    localparam MSG_LEN = 16;

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

    // 256 x 8 distributed RAM (async read for packing/compare).
    reg [7:0] buf_mem [0:BYTES-1];

    reg [3:0]  state;
    reg [1:0]  addr_idx;
    reg [7:0]  data_idx;
    reg [31:0] addr_shift;
    reg [31:0] base_addr;
    reg [31:0] cur_addr;
    reg [5:0]  beats_left;
    reg [5:0]  burst_beats;
    reg [5:0]  beats_in_burst;
    reg [7:0]  byte_ptr;
    reg [8:0]  mismatch_count;
    reg [7:0]  first_bad;
    reg        got_first;
    reg        axi_err;
    reg [3:0]  tx_idx;
    reg [7:0]  msg [0:MSG_LEN-1];

    assign rx_phase = (state == ST_RX_ADDR) || (state == ST_RX_DATA);

    assign m_axi_awid     = {AXI_ID_W{1'b0}};
    assign m_axi_awsize   = 3'd3;
    assign m_axi_awburst  = 2'b01;
    assign m_axi_awlock   = 1'b0;
    assign m_axi_awcache  = 4'b0011;
    assign m_axi_awprot   = 3'b000;
    assign m_axi_awqos    = 4'b0000;
    assign m_axi_awregion = 4'b0000;

    assign m_axi_arid     = {AXI_ID_W{1'b0}};
    assign m_axi_arsize   = 3'd3;
    assign m_axi_arburst  = 2'b01;
    assign m_axi_arlock   = 1'b0;
    assign m_axi_arcache  = 4'b0011;
    assign m_axi_arprot   = 3'b000;
    assign m_axi_arqos    = 4'b0000;
    assign m_axi_arregion = 4'b0000;

    assign m_axi_wstrb    = {STRB_W{1'b1}};
    assign m_axi_wlast    = (beats_in_burst == 6'd1);
    assign m_axi_wdata    = {
        buf_mem[byte_ptr + 8'd7],
        buf_mem[byte_ptr + 8'd6],
        buf_mem[byte_ptr + 8'd5],
        buf_mem[byte_ptr + 8'd4],
        buf_mem[byte_ptr + 8'd3],
        buf_mem[byte_ptr + 8'd2],
        buf_mem[byte_ptr + 8'd1],
        buf_mem[byte_ptr + 8'd0]
    };

    // Beats from cur_addr to the next 4 KB boundary, capped by beats_left.
    // Width is 10 bits so a full 4 KB (512 beats) does not overflow or look
    // negative in a 9-bit compare; that bug made burst_len return 0 in Icarus
    // and the write phase looped forever (beats_left never decreased).
    wire [9:0] beats_to_bdry = (13'd4096 - {1'b0, cur_addr[11:0]}) >> 3;
    wire [5:0] cmd_burst = (beats_to_bdry > {4'b0, beats_left})
                         ? beats_left
                         : beats_to_bdry[5:0];

    function [7:0] tohex;
        input [3:0] n;
        begin
            tohex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    integer i;
    integer cmiss;
    integer first_set;
    integer first_idx;

    always @(posedge clk) begin
        if (rst) begin
            state           <= ST_RX_ADDR;
            addr_idx        <= 2'd0;
            data_idx        <= 8'd0;
            addr_shift      <= 32'd0;
            base_addr       <= 32'd0;
            cur_addr        <= 32'd0;
            beats_left      <= 6'd0;
            burst_beats     <= 6'd0;
            beats_in_burst  <= 6'd0;
            byte_ptr        <= 8'd0;
            mismatch_count  <= 9'd0;
            first_bad       <= 8'd0;
            got_first       <= 1'b0;
            axi_err         <= 1'b0;
            tx_idx          <= 4'd0;
            tx_start        <= 1'b0;
            tx_data         <= 8'd0;
            rx_toggle       <= 1'b0;
            last_pass       <= 1'b0;
            m_axi_awaddr    <= {AXI_ADDR_W{1'b0}};
            m_axi_awlen     <= 8'd0;
            m_axi_awvalid   <= 1'b0;
            m_axi_wvalid    <= 1'b0;
            m_axi_bready    <= 1'b0;
            m_axi_araddr    <= {AXI_ADDR_W{1'b0}};
            m_axi_arlen     <= 8'd0;
            m_axi_arvalid   <= 1'b0;
            m_axi_rready    <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                ST_RX_ADDR: begin
                    if (rx_valid) begin
                        rx_toggle  <= ~rx_toggle;
                        addr_shift <= {rx_data, addr_shift[31:8]};
                        if (addr_idx == 2'd3) begin
                            addr_idx  <= 2'd0;
                            data_idx  <= 8'd0;
                            state     <= ST_RX_DATA;
                        end else begin
                            addr_idx <= addr_idx + 2'd1;
                        end
                    end
                end

                ST_RX_DATA: begin
                    if (rx_valid) begin
                        rx_toggle        <= ~rx_toggle;
                        buf_mem[data_idx] <= rx_data;
                        if (data_idx == 8'd255) begin
                            base_addr      <= {addr_shift[31:3], 3'b000};
                            cur_addr       <= {addr_shift[31:3], 3'b000};
                            beats_left     <= BEATS_ALL[5:0];
                            byte_ptr       <= 8'd0;
                            mismatch_count <= 9'd0;
                            first_bad      <= 8'd0;
                            got_first      <= 1'b0;
                            axi_err        <= 1'b0;
                            state          <= ST_CALC_W;
                        end else begin
                            data_idx <= data_idx + 8'd1;
                        end
                    end
                end

                ST_CALC_W: begin
                    burst_beats    <= cmd_burst;
                    beats_in_burst <= cmd_burst;
                    m_axi_awaddr   <= cur_addr;
                    m_axi_awlen    <= {2'b00, cmd_burst} - 8'd1;
                    m_axi_awvalid  <= 1'b1;
                    state          <= ST_AW;
                end

                ST_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        state         <= ST_W;
                    end
                end

                ST_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        byte_ptr <= byte_ptr + 8'd8;
                        if (beats_in_burst == 6'd1) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= ST_B;
                        end else begin
                            beats_in_burst <= beats_in_burst - 6'd1;
                        end
                    end
                end

                ST_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        if (m_axi_bresp != 2'b00)
                            axi_err <= 1'b1;
                        if (beats_left == burst_beats) begin
                            cur_addr   <= base_addr;
                            beats_left <= BEATS_ALL[5:0];
                            byte_ptr   <= 8'd0;
                            state      <= ST_CALC_R;
                        end else begin
                            cur_addr   <= cur_addr + {23'd0, burst_beats, 3'b000};
                            beats_left <= beats_left - burst_beats;
                            // byte_ptr already advanced through this burst
                            state      <= ST_CALC_W;
                        end
                    end
                end

                ST_CALC_R: begin
                    burst_beats    <= cmd_burst;
                    beats_in_burst <= cmd_burst;
                    m_axi_araddr   <= cur_addr;
                    m_axi_arlen    <= {2'b00, cmd_burst} - 8'd1;
                    m_axi_arvalid  <= 1'b1;
                    state          <= ST_AR;
                end

                ST_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= ST_R;
                    end
                end

                ST_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (m_axi_rresp != 2'b00)
                            axi_err <= 1'b1;
                        if ((beats_in_burst == 6'd1) != m_axi_rlast)
                            axi_err <= 1'b1;

                        // Blocking temps so the first mismatch in this beat wins
                        // and the count includes every bad byte in the beat.
                        cmiss     = mismatch_count;
                        first_set = got_first;
                        first_idx = first_bad;
                        for (i = 0; i < 8; i = i + 1) begin
                            if (m_axi_rdata[i*8 +: 8] !== buf_mem[byte_ptr + i[7:0]]) begin
                                cmiss = cmiss + 1;
                                if (!first_set) begin
                                    first_set = 1;
                                    first_idx = byte_ptr + i[7:0];
                                end
                            end
                        end
                        mismatch_count <= cmiss[8:0];
                        got_first      <= first_set[0];
                        first_bad      <= first_idx[7:0];

                        byte_ptr <= byte_ptr + 8'd8;
                        if (beats_in_burst == 6'd1) begin
                            m_axi_rready <= 1'b0;
                            if (beats_left == burst_beats)
                                state <= ST_TX;
                            else begin
                                cur_addr   <= cur_addr + {23'd0, burst_beats, 3'b000};
                                beats_left <= beats_left - burst_beats;
                                state      <= ST_CALC_R;
                            end
                        end else begin
                            beats_in_burst <= beats_in_burst - 6'd1;
                        end
                    end
                end

                ST_TX: begin
                    if (tx_idx == 4'd0 && !tx_busy && !tx_start) begin
                        // Build the 16-byte report, then send the first byte.
                        if (!axi_err && mismatch_count == 9'd0) begin
                            last_pass <= 1'b1;
                            msg[0]    <= "P";
                            msg[1]    <= "A";
                            msg[2]    <= "S";
                            msg[3]    <= "S";
                        end else begin
                            last_pass <= 1'b0;
                            msg[0]    <= "F";
                            msg[1]    <= "A";
                            msg[2]    <= "I";
                            msg[3]    <= "L";
                        end
                        msg[4]  <= " ";
                        msg[5]  <= "0";
                        msg[6]  <= "x";
                        msg[7]  <= tohex({3'b000, mismatch_count[8]});
                        msg[8]  <= tohex(mismatch_count[7:4]);
                        msg[9]  <= tohex(mismatch_count[3:0]);
                        msg[10] <= " ";
                        msg[11] <= "0";
                        msg[12] <= "x";
                        msg[13] <= tohex(first_bad[7:4]);
                        msg[14] <= tohex(first_bad[3:0]);
                        msg[15] <= "\n";

                        tx_data  <= (!axi_err && mismatch_count == 9'd0) ? "P" : "F";
                        tx_start <= 1'b1;
                        tx_idx   <= 4'd1;
                    end else if (tx_idx != 4'd0 && !tx_busy && !tx_start) begin
                        tx_data  <= msg[tx_idx];
                        tx_start <= 1'b1;
                        if (tx_idx == MSG_LEN[3:0] - 4'd1) begin
                            tx_idx <= 4'd0;
                            addr_idx <= 2'd0;
                            state    <= ST_RX_ADDR;
                        end else begin
                            tx_idx <= tx_idx + 4'd1;
                        end
                    end
                end

                default: state <= ST_RX_ADDR;
            endcase
        end
    end

endmodule
