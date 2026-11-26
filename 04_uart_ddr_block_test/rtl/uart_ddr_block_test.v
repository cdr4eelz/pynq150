// Single-character UART triggers for a full-speed PL-generated DDR block
// test over a 64-bit AXI4 master (PS7 S_AXI_HP0 through SmartConnect).
//
// Host -> DUT (115200 8N1). One command character at a time; the DUT
// replies, then waits for the next command. Bytes that arrive while a
// command is running are ignored.
//
//   'A' a0 a1 a2 a3  set base address (4 bytes little-endian, bits [2:0]
//                    forced to 0). Reply 'K'. W/R are refused ('N') until
//                    an address has been set, so a reset never writes
//                    physical address 0.
//   'W'              seed <= seed + 1, then write LEN_BYTES of the
//                    pattern for that seed at full AXI speed.
//                    Reply 'D' (all BRESP OKAY) or 'E' (any error).
//   'R'              read LEN_BYTES at full speed, compare every beat in
//                    the PL with the pattern for the current seed.
//                    Reply 'P' (no mismatches, all RRESP OKAY) or 'F'.
//   'T'              stats line, 44 ASCII bytes:
//                    "Wwwwwwwww Rrrrrrrrr Mmmmmmmmm Bbbbbbbbb Sss\n"
//                    w/r = cycles of the last write/read (FCLK0 cycles),
//                    m = mismatch beats of the last read, b = first bad
//                    beat index, s = current seed. All hex.
//   anything else    reply '?'.
//
// Pattern, beat i (0-based from the base address), 64 bits LE:
//   lo = i ^ {4{seed}},  hi = ~{lo[15:0], lo[31:16]},  beat = {hi, lo}
//
// Bursts are INCR, 8-byte beats, at most 256 beats (2 KB), split so no
// burst crosses a 4 KB boundary. Up to MAX_OUT bursts are outstanding on
// each of the write and read sides. WVALID stays high across bursts and
// RREADY is always high during a read, so the master never throttles.
module uart_ddr_block_test #(
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD       = 115200,
    parameter LEN_BYTES  = 1024 * 1024,   // multiple of 8
    parameter MAX_OUT    = 4,             // outstanding bursts per side (<= 15)
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 64,            // fixed at 64
    parameter AXI_ID_W   = 1
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    rxd,
    output wire                    txd,
    output reg                     rx_toggle,
    output reg                     last_pass,
    output wire                    busy,

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
    output wire                    m_axi_wvalid,
    input  wire                    m_axi_wready,

    input  wire [AXI_ID_W-1:0]     m_axi_bid,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output wire                    m_axi_bready,

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
    output wire                    m_axi_rready
);

    localparam [31:0] TOTAL_BEATS = LEN_BYTES / 8;
    localparam MSG_LEN = 44;

    localparam ST_IDLE  = 3'd0;
    localparam ST_ADDR  = 3'd1;
    localparam ST_WRITE = 3'd2;
    localparam ST_READ  = 3'd3;
    localparam ST_TX    = 3'd4;

    // ---------------- UART ----------------
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rxd(rxd), .valid(rx_valid), .data(rx_data));

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .data_in(tx_data),
        .busy(tx_busy), .txd(txd));

    // ---------------- state ----------------
    reg [2:0]  state;
    reg [1:0]  addr_idx;
    reg [31:0] addr_shift;
    reg [31:0] base_addr;
    reg        addr_set;
    reg [7:0]  seed;

    reg [31:0] cyc;
    reg [31:0] wcyc, rcyc;
    reg [31:0] mism, first_bad;
    reg        berr, rerr;

    reg [7:0]  msg [0:MSG_LEN-1];
    reg [5:0]  tx_len;
    reg [5:0]  tx_idx;

    // write side
    reg [31:0] aw_addr, aw_rem;
    reg [15:0] aw_bursts;
    reg [31:0] w_addr, w_rem, w_idx;
    reg [8:0]  w_left;        // beats left in the current W burst
    reg [15:0] w_bursts;
    reg [15:0] b_bursts;

    // read side
    reg [31:0] ar_addr, ar_rem;
    reg [15:0] ar_bursts;
    reg [15:0] r_bursts;
    reg [31:0] r_idx;

    assign busy = (state == ST_WRITE) || (state == ST_READ);

    // ---------------- AXI constants ----------------
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
    assign m_axi_wstrb    = {(AXI_DATA_W/8){1'b1}};

    // ---------------- helpers ----------------
    // Beats in the next burst: min(256, beats to the next 4 KB boundary,
    // beats remaining). Result 1..256 (0 only when rem is 0).
    function [8:0] blen;
        input [31:0] addr;
        input [31:0] rem;
        reg   [9:0]  to4k;   // 1..512
        begin
            to4k = (13'd4096 - {1'b0, addr[11:0]}) >> 3;
            blen = 9'd256;
            if (to4k < 10'd256)
                blen = to4k[8:0];
            if (rem < {23'd0, blen})
                blen = rem[8:0];
        end
    endfunction

    function [63:0] pattern;
        input [31:0] idx;
        input [7:0]  s;
        reg   [31:0] lo;
        begin
            lo      = idx ^ {4{s}};
            pattern = {~{lo[15:0], lo[31:16]}, lo};
        end
    endfunction

    function [7:0] tohex;
        input [3:0] n;
        begin
            tohex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    wire [8:0] aw_len_n = blen(aw_addr, aw_rem);
    wire [8:0] w_len_n  = blen(w_addr,  w_rem);
    wire [8:0] ar_len_n = blen(ar_addr, ar_rem);

    wire [15:0] w_out = aw_bursts - b_bursts;
    wire [15:0] r_out = ar_bursts - r_bursts;

    assign m_axi_wvalid = (state == ST_WRITE) && (w_left != 9'd0);
    assign m_axi_wlast  = (w_left == 9'd1);
    assign m_axi_wdata  = pattern(w_idx, seed);
    assign m_axi_bready = (state == ST_WRITE);
    assign m_axi_rready = (state == ST_READ);

    wire w_hs = m_axi_wvalid && m_axi_wready;
    // Start the next W burst when idle, or on the last beat of the current
    // one (no bubble), but never ahead of the AW issue count.
    wire w_load = (w_rem != 32'd0) && (w_bursts != aw_bursts) &&
                  ((w_left == 9'd0) || (w_left == 9'd1 && w_hs));

    wire [63:0] r_exp = pattern(r_idx, seed);

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            state      <= ST_IDLE;
            addr_idx   <= 2'd0;
            addr_shift <= 32'd0;
            base_addr  <= 32'd0;
            addr_set   <= 1'b0;
            seed       <= 8'd0;
            cyc        <= 32'd0;
            wcyc       <= 32'd0;
            rcyc       <= 32'd0;
            mism       <= 32'd0;
            first_bad  <= 32'd0;
            berr       <= 1'b0;
            rerr       <= 1'b0;
            tx_len     <= 6'd0;
            tx_idx     <= 6'd0;
            tx_start   <= 1'b0;
            tx_data    <= 8'd0;
            rx_toggle  <= 1'b0;
            last_pass  <= 1'b0;
            m_axi_awvalid <= 1'b0;
            m_axi_awaddr  <= 32'd0;
            m_axi_awlen   <= 8'd0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'd0;
            m_axi_arlen   <= 8'd0;
            aw_addr <= 32'd0; aw_rem <= 32'd0; aw_bursts <= 16'd0;
            w_addr  <= 32'd0; w_rem  <= 32'd0; w_idx     <= 32'd0;
            w_left  <= 9'd0;  w_bursts <= 16'd0; b_bursts <= 16'd0;
            ar_addr <= 32'd0; ar_rem <= 32'd0; ar_bursts <= 16'd0;
            r_bursts <= 16'd0; r_idx <= 32'd0;
        end else begin
            tx_start <= 1'b0;
            if (rx_valid)
                rx_toggle <= ~rx_toggle;

            case (state)
            // ------------------------------------------------------------
            ST_IDLE: begin
                if (rx_valid) begin
                    tx_idx <= 6'd0;
                    tx_len <= 6'd1;
                    case (rx_data)
                        "A": begin
                            addr_idx <= 2'd0;
                            state    <= ST_ADDR;
                        end
                        "W": begin
                            if (!addr_set) begin
                                msg[0] <= "N";
                                state  <= ST_TX;
                            end else begin
                                seed      <= seed + 8'd1;
                                cyc       <= 32'd0;
                                berr      <= 1'b0;
                                aw_addr   <= base_addr;
                                aw_rem    <= TOTAL_BEATS;
                                aw_bursts <= 16'd0;
                                w_addr    <= base_addr;
                                w_rem     <= TOTAL_BEATS;
                                w_idx     <= 32'd0;
                                w_left    <= 9'd0;
                                w_bursts  <= 16'd0;
                                b_bursts  <= 16'd0;
                                state     <= ST_WRITE;
                            end
                        end
                        "R": begin
                            if (!addr_set) begin
                                msg[0] <= "N";
                                state  <= ST_TX;
                            end else begin
                                cyc       <= 32'd0;
                                rerr      <= 1'b0;
                                mism      <= 32'd0;
                                first_bad <= 32'd0;
                                ar_addr   <= base_addr;
                                ar_rem    <= TOTAL_BEATS;
                                ar_bursts <= 16'd0;
                                r_bursts  <= 16'd0;
                                r_idx     <= 32'd0;
                                state     <= ST_READ;
                            end
                        end
                        "T": begin
                            msg[0] <= "W";
                            for (k = 0; k < 8; k = k + 1) msg[1+k]  <= tohex(wcyc[31-4*k -: 4]);
                            msg[9]  <= " "; msg[10] <= "R";
                            for (k = 0; k < 8; k = k + 1) msg[11+k] <= tohex(rcyc[31-4*k -: 4]);
                            msg[19] <= " "; msg[20] <= "M";
                            for (k = 0; k < 8; k = k + 1) msg[21+k] <= tohex(mism[31-4*k -: 4]);
                            msg[29] <= " "; msg[30] <= "B";
                            for (k = 0; k < 8; k = k + 1) msg[31+k] <= tohex(first_bad[31-4*k -: 4]);
                            msg[39] <= " "; msg[40] <= "S";
                            msg[41] <= tohex(seed[7:4]);
                            msg[42] <= tohex(seed[3:0]);
                            msg[43] <= 8'h0A;
                            tx_len  <= MSG_LEN[5:0];
                            state   <= ST_TX;
                        end
                        default: begin
                            msg[0] <= "?";
                            state  <= ST_TX;
                        end
                    endcase
                end
            end
            // ------------------------------------------------------------
            ST_ADDR: begin
                if (rx_valid) begin
                    addr_shift <= {rx_data, addr_shift[31:8]};
                    if (addr_idx == 2'd3) begin
                        base_addr <= {rx_data, addr_shift[31:11], 3'b000};
                        addr_set  <= 1'b1;
                        msg[0]    <= "K";
                        tx_len    <= 6'd1;
                        tx_idx    <= 6'd0;
                        state     <= ST_TX;
                    end
                    addr_idx <= addr_idx + 2'd1;
                end
            end
            // ------------------------------------------------------------
            ST_WRITE: begin
                cyc <= cyc + 32'd1;

                // AW issue
                if (m_axi_awvalid) begin
                    if (m_axi_awready)
                        m_axi_awvalid <= 1'b0;
                end else if (aw_rem != 32'd0 && w_out < MAX_OUT) begin
                    m_axi_awaddr  <= aw_addr;
                    m_axi_awlen   <= aw_len_n[7:0] - 8'd1;
                    m_axi_awvalid <= 1'b1;
                    aw_addr       <= aw_addr + {20'd0, aw_len_n, 3'b000};
                    aw_rem        <= aw_rem - {23'd0, aw_len_n};
                    aw_bursts     <= aw_bursts + 16'd1;
                end

                // W data
                if (w_hs)
                    w_idx <= w_idx + 32'd1;
                if (w_load) begin
                    w_left   <= w_len_n;
                    w_addr   <= w_addr + {20'd0, w_len_n, 3'b000};
                    w_rem    <= w_rem - {23'd0, w_len_n};
                    w_bursts <= w_bursts + 16'd1;
                end else if (w_hs) begin
                    w_left <= w_left - 9'd1;
                end

                // B
                if (m_axi_bvalid) begin
                    b_bursts <= b_bursts + 16'd1;
                    if (m_axi_bresp != 2'b00)
                        berr <= 1'b1;
                end

                if (aw_rem == 32'd0 && !m_axi_awvalid && w_rem == 32'd0 &&
                    w_left == 9'd0 && b_bursts == aw_bursts) begin
                    wcyc   <= cyc;
                    msg[0] <= berr ? "E" : "D";
                    tx_len <= 6'd1;
                    tx_idx <= 6'd0;
                    state  <= ST_TX;
                end
            end
            // ------------------------------------------------------------
            ST_READ: begin
                cyc <= cyc + 32'd1;

                if (m_axi_arvalid) begin
                    if (m_axi_arready)
                        m_axi_arvalid <= 1'b0;
                end else if (ar_rem != 32'd0 && r_out < MAX_OUT) begin
                    m_axi_araddr  <= ar_addr;
                    m_axi_arlen   <= ar_len_n[7:0] - 8'd1;
                    m_axi_arvalid <= 1'b1;
                    ar_addr       <= ar_addr + {20'd0, ar_len_n, 3'b000};
                    ar_rem        <= ar_rem - {23'd0, ar_len_n};
                    ar_bursts     <= ar_bursts + 16'd1;
                end

                if (m_axi_rvalid) begin
                    r_idx <= r_idx + 32'd1;
                    if (m_axi_rlast)
                        r_bursts <= r_bursts + 16'd1;
                    if (m_axi_rresp != 2'b00)
                        rerr <= 1'b1;
                    if (m_axi_rdata != r_exp) begin
                        if (mism == 32'd0)
                            first_bad <= r_idx;
                        mism <= mism + 32'd1;
                    end
                end

                if (r_idx == TOTAL_BEATS && ar_rem == 32'd0 && !m_axi_arvalid &&
                    r_bursts == ar_bursts) begin
                    rcyc      <= cyc;
                    last_pass <= (mism == 32'd0) && !rerr;
                    msg[0]    <= ((mism == 32'd0) && !rerr) ? "P" : "F";
                    tx_len    <= 6'd1;
                    tx_idx    <= 6'd0;
                    state     <= ST_TX;
                end
            end
            // ------------------------------------------------------------
            ST_TX: begin
                if (!tx_busy && !tx_start) begin
                    if (tx_idx == tx_len) begin
                        state <= ST_IDLE;
                    end else begin
                        tx_data  <= msg[tx_idx];
                        tx_start <= 1'b1;
                        tx_idx   <= tx_idx + 6'd1;
                    end
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
