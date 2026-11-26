// rc_ddr_test: UART command FSM + fake dcache (dcache_tester) -> cs150
// RequestController (verbatim copy) -> rc_axi_fifo_adapter (mig_caf / mig_wdf /
// mig_rdf FIFOs + AXI master, in MIG's place) -> AXI4 master (HP0).
// All other RequestController clients are tied off (null).
//
// UART 115200 8N1, single-character commands (same style as 04):
//   'A' a0 a1 a2 a3  base address, LE, bits [4:0] forced 0 -> 'K'
//   'W'  seed += 1, write LINES 32-byte lines via the dcache port -> 'D'/'E'
//   'R'  read LINES lines via the dcache port and compare        -> 'P'/'F'
//   'G'  'W' then 'R' in one go (the "single char" test)          -> 'P'/'F'
//   'B'  toggle streaming reads (pixf port, back to back): 'B' = now on,
//        'b' = now off. Off after reset: 'R'/'G' read through the dcache port
//        one line at a time, exactly as in 05.
//   'O'  "Oxx yy\n": peak AXI writes (xx) / reads (yy) in flight since the
//        last 'W'/'G'/'R' start (hex)
//   'T'  "Wwwwwwwww Rrrrrrrrr Mmmmmmmmm Bbbbbbbbb Sss\n"
//        (write cycles, read cycles, mismatching lines, first bad line,
//        seed; hex)
//   'W'/'R'/'G' before 'A' -> 'N'; anything else -> '?'
// Write time (wcyc) runs until the AXI side has completed every write.
// 'E' = an AXI error response or bad command during the write; an AXI
// error during a read gives 'F'.
module rc_ddr_test #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200,
    parameter LINES    = 32768,          // 32768 x 32 B = 1 MiB
    parameter WIN_AW   = 20              // address window 2**WIN_AW bytes
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          rxd,
    output wire          txd,
    output reg           rx_toggle,
    output reg           last_pass,
    output wire          busy,

    output wire [0:0]    m_axi_awid,
    output wire [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output wire [2:0]    m_axi_awsize,
    output wire [1:0]    m_axi_awburst,
    output wire          m_axi_awlock,
    output wire [3:0]    m_axi_awcache,
    output wire [2:0]    m_axi_awprot,
    output wire [3:0]    m_axi_awqos,
    output wire [3:0]    m_axi_awregion,
    output wire          m_axi_awvalid,
    input  wire          m_axi_awready,
    output wire [63:0]   m_axi_wdata,
    output wire [7:0]    m_axi_wstrb,
    output wire          m_axi_wlast,
    output wire          m_axi_wvalid,
    input  wire          m_axi_wready,
    input  wire [0:0]    m_axi_bid,
    input  wire [1:0]    m_axi_bresp,
    input  wire          m_axi_bvalid,
    output wire          m_axi_bready,
    output wire [0:0]    m_axi_arid,
    output wire [31:0]   m_axi_araddr,
    output wire [7:0]    m_axi_arlen,
    output wire [2:0]    m_axi_arsize,
    output wire [1:0]    m_axi_arburst,
    output wire          m_axi_arlock,
    output wire [3:0]    m_axi_arcache,
    output wire [2:0]    m_axi_arprot,
    output wire [3:0]    m_axi_arqos,
    output wire [3:0]    m_axi_arregion,
    output wire          m_axi_arvalid,
    input  wire          m_axi_arready,
    input  wire [0:0]    m_axi_rid,
    input  wire [63:0]   m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready
);

    localparam MSG_LEN = 44;
    localparam OMSG_LEN = 7;
    localparam ST_IDLE = 3'd0, ST_ADDR = 3'd1, ST_WRITE = 3'd2,
               ST_READ = 3'd3, ST_TX = 3'd4;

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

    // ---------------- RequestController + clients ----------------
    // master side (rcon_* in Memory150.v), wired straight to the adapter
    wire         rcon_caf_full, rcon_caf_wren;
    wire [33:0]  rcon_caf_cadr;
    wire         rcon_wdf_full, rcon_wdf_wren;
    wire [143:0] rcon_wdf_mdat;
    wire         rcon_rdf_rden, rcon_rdf_wren;
    wire [127:0] ALLR_rdf_data;          // read data goes to all readers (as in Memory150.v)

    // dcache port
    wire         data_caf_full, data_caf_wren;
    wire [33:0]  data_caf_cadr;
    wire         data_wdf_full, data_wdf_wren;
    wire [143:0] data_wdf_mdat;
    wire         data_rdf_rden, data_rdf_wren;
    // pixf (read-only) port: used for streaming reads
    wire         pixf_raf_wren, pixf_raf_full, pixf_rdf_rden, pixf_rdf_wren;
    wire [30:0]  pixf_raf_addr;
    reg          stream_rd;
    wire [3:0]   peak_wr, peak_rd;
    wire         a_idle;                 // adapter: all accepted commands completed
    reg          wfin;                   // dcache finished pushing writes

    reg          start_w, start_r;
    reg  [7:0]   seed;
    wire         t_done, t_busy;
    wire [31:0]  t_mism, t_first;
    reg  [31:0]  base_addr;
    reg          clr_err;
    wire         axi_err, bad_cmd;

    dcache_tester #(.LINES(LINES)) u_dcache (
        .clk(clk), .rst(rst),
        .start_w(start_w), .start_r(start_r), .seed(seed),
        .done(t_done), .busy(t_busy), .mism(t_mism), .first_bad(t_first),
        .caf_wren(data_caf_wren), .caf_cadr(data_caf_cadr), .caf_full(data_caf_full),
        .wdf_wren(data_wdf_wren), .wdf_mdat(data_wdf_mdat), .wdf_full(data_wdf_full),
        .rdf_rden(data_rdf_rden), .rdf_wren(data_rdf_wren), .rdf_data(ALLR_rdf_data),
        .stream_rd(stream_rd), .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr),
        .pixf_raf_full(pixf_raf_full), .pixf_rdf_rden(pixf_rdf_rden),
        .pixf_rdf_wren(pixf_rdf_wren));

    RequestController req_con (
        .clk(clk), .rst(rst),
        .caf_full(rcon_caf_full), .wdf_full(rcon_wdf_full), .rdf_wren(rcon_rdf_wren),
        // Inst-cache: null
        .inst_caf_wren(1'b0), .inst_caf_cadr(34'd0), .inst_wdf_wren(1'b0),
        .inst_wdf_mdat(144'd0), .inst_rdf_rden(1'b0), .inst_stall(1'b0),
        // Data-cache: the fake dcache
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr),
        .data_wdf_wren(data_wdf_wren), .data_wdf_mdat(data_wdf_mdat),
        .data_rdf_rden(data_rdf_rden), .data_stall(t_busy),
        // GraphicsProcessor, PixelFeeder (read-only): null
        .gcmd_raf_wren(1'b0), .gcmd_raf_addr(31'd0), .gcmd_rdf_rden(1'b0),
        // PixelFeeder read-only port: the tester's streaming-read mode
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_rdf_rden(pixf_rdf_rden),
        // FrameFiller, LineEngine, Bypass (write-only): null
        .fill_waf_wren(1'b0), .fill_waf_addr(31'd0), .fill_wdf_wren(1'b0), .fill_wdf_mdat(144'd0),
        .line_waf_wren(1'b0), .line_waf_addr(31'd0), .line_wdf_wren(1'b0), .line_wdf_mdat(144'd0),
        .bpas_waf_wren(1'b0), .bpas_waf_addr(31'd0), .bpas_wdf_wren(1'b0), .bpas_wdf_mdat(144'd0),
        // master outputs
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .rdf_rden(rcon_rdf_rden),
        // client outputs
        .inst_caf_full(), .inst_wdf_full(), .inst_rdf_wren(),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full),
        .data_rdf_wren(data_rdf_wren),
        .gcmd_raf_full(), .gcmd_rdf_wren(), .pixf_raf_full(pixf_raf_full), .pixf_rdf_wren(pixf_rdf_wren),
        .fill_waf_full(), .fill_wdf_full(), .line_waf_full(), .line_wdf_full(),
        .bpas_waf_full(), .bpas_wdf_full());

`ifdef REF_ADAPTER
    // 05's register-only adapter (rtl/rc_axi_adapter.v), for A/B sim runs only
    // (make simref). It has no FIFOs and no overlap.
    assign peak_wr = 4'd0;
    assign peak_rd = 4'd0;
    assign a_idle  = 1'b1;
    rc_axi_adapter #(.WIN_AW(WIN_AW)) u_adapter (
        .clk(clk), .rst(rst), .base_addr(base_addr), .clr_err(clr_err),
        .axi_err(axi_err), .bad_cmd(bad_cmd),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr), .caf_full(rcon_caf_full),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .wdf_full(rcon_wdf_full),
        .rdf_wren(rcon_rdf_wren), .rdf_data(ALLR_rdf_data), .rdf_rden(rcon_rdf_rden),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
        .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
        .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready));
`else
    rc_axi_fifo_adapter #(.WIN_AW(WIN_AW)) u_adapter (
        .clk(clk), .rst(rst), .base_addr(base_addr), .clr_err(clr_err),
        .axi_err(axi_err), .bad_cmd(bad_cmd), .peak_wr(peak_wr), .peak_rd(peak_rd), .idle(a_idle),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr), .caf_full(rcon_caf_full),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .wdf_full(rcon_wdf_full),
        .rdf_wren(rcon_rdf_wren), .rdf_data(ALLR_rdf_data), .rdf_rden(rcon_rdf_rden),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
        .m_axi_awregion(m_axi_awregion), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
        .m_axi_arregion(m_axi_arregion), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready));
`endif

    // ---------------- command FSM ----------------
    reg [2:0]  state;
    reg [1:0]  addr_idx;
    reg [31:0] addr_shift;
    reg        addr_set;
    reg        then_read;                // 'G': read after the write
    reg [31:0] cyc, wcyc, rcyc;
    reg [7:0]  msg [0:MSG_LEN-1];
    reg [5:0]  tx_len, tx_idx;

    assign busy = (state == ST_WRITE) || (state == ST_READ);

    function [7:0] tohex;
        input [3:0] n;
        begin
            tohex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            addr_idx  <= 2'd0;
            addr_shift<= 32'd0;
            addr_set  <= 1'b0;
            base_addr <= 32'd0;
            seed      <= 8'd0;
            then_read <= 1'b0;
            cyc       <= 32'd0;
            wcyc      <= 32'd0;
            rcyc      <= 32'd0;
            tx_len    <= 6'd0;
            tx_idx    <= 6'd0;
            tx_start  <= 1'b0;
            tx_data   <= 8'd0;
            rx_toggle <= 1'b0;
            last_pass <= 1'b0;
            stream_rd <= 1'b0;
            wfin      <= 1'b0;
            start_w   <= 1'b0;
            start_r   <= 1'b0;
            clr_err   <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            start_w  <= 1'b0;
            start_r  <= 1'b0;
            clr_err  <= 1'b0;
            if (rx_valid)
                rx_toggle <= ~rx_toggle;

            case (state)
            ST_IDLE: if (rx_valid) begin
                tx_idx <= 6'd0;
                tx_len <= 6'd1;
                case (rx_data)
                    "A": begin
                        addr_idx <= 2'd0;
                        state    <= ST_ADDR;
                    end
                    "W", "G": begin
                        if (!addr_set) begin
                            msg[0] <= "N";
                            state  <= ST_TX;
                        end else begin
                            seed      <= seed + 8'd1;
                            then_read <= (rx_data == "G");
                            cyc       <= 32'd0;
                            clr_err   <= 1'b1;
                            start_w   <= 1'b1;
                            state     <= ST_WRITE;
                        end
                    end
                    "R": begin
                        if (!addr_set) begin
                            msg[0] <= "N";
                            state  <= ST_TX;
                        end else begin
                            cyc     <= 32'd0;
                            clr_err <= 1'b1;
                            start_r <= 1'b1;
                            state   <= ST_READ;
                        end
                    end
                    "B": begin
                        stream_rd <= ~stream_rd;
                        msg[0]    <= stream_rd ? "b" : "B";
                        state     <= ST_TX;
                    end
                    "O": begin
                        msg[0] <= "O";
                        msg[1] <= "0"; msg[2] <= tohex(peak_wr);
                        msg[3] <= " ";
                        msg[4] <= "0"; msg[5] <= tohex(peak_rd);
                        msg[6] <= 8'h0A;
                        tx_len <= OMSG_LEN[5:0];
                        state  <= ST_TX;
                    end
                    "T": begin
                        msg[0] <= "W";
                        for (k = 0; k < 8; k = k + 1) msg[1+k]  <= tohex(wcyc[31-4*k -: 4]);
                        msg[9]  <= " "; msg[10] <= "R";
                        for (k = 0; k < 8; k = k + 1) msg[11+k] <= tohex(rcyc[31-4*k -: 4]);
                        msg[19] <= " "; msg[20] <= "M";
                        for (k = 0; k < 8; k = k + 1) msg[21+k] <= tohex(t_mism[31-4*k -: 4]);
                        msg[29] <= " "; msg[30] <= "B";
                        for (k = 0; k < 8; k = k + 1) msg[31+k] <= tohex(t_first[31-4*k -: 4]);
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
            ST_ADDR: if (rx_valid) begin
                addr_shift <= {rx_data, addr_shift[31:8]};
                if (addr_idx == 2'd3) begin
                    base_addr <= {rx_data, addr_shift[31:13], 5'b00000};
                    addr_set  <= 1'b1;
                    msg[0]    <= "K";
                    tx_len    <= 6'd1;
                    tx_idx    <= 6'd0;
                    state     <= ST_TX;
                end
                addr_idx <= addr_idx + 2'd1;
            end
            ST_WRITE: begin
                cyc <= cyc + 32'd1;
                if (t_done) wfin <= 1'b1;
                // 'D' only once every write is in DDR (last BRESP): the FIFOs
                // let the tester finish long before the AXI side does
                if ((t_done || wfin) && a_idle) begin
                    wfin <= 1'b0;
                    wcyc <= cyc;
                    if (then_read && !axi_err && !bad_cmd) begin
                        cyc     <= 32'd0;
                        start_r <= 1'b1;
                        state   <= ST_READ;
                    end else begin
                        msg[0] <= (axi_err || bad_cmd) ? "E" : "D";
                        if (then_read) begin
                            msg[0]    <= "F";
                            last_pass <= 1'b0;
                        end
                        tx_len <= 6'd1;
                        tx_idx <= 6'd0;
                        state  <= ST_TX;
                    end
                end
            end
            ST_READ: begin
                cyc <= cyc + 32'd1;
                if (t_done) begin
                    rcyc      <= cyc;
                    last_pass <= (t_mism == 32'd0) && !axi_err && !bad_cmd;
                    msg[0]    <= ((t_mism == 32'd0) && !axi_err && !bad_cmd) ? "P" : "F";
                    tx_len    <= 6'd1;
                    tx_idx    <= 6'd0;
                    state     <= ST_TX;
                end
            end
            ST_TX: if (!tx_busy && !tx_start) begin
                if (tx_idx == tx_len) begin
                    state <= ST_IDLE;
                end else begin
                    tx_data  <= msg[tx_idx];
                    tx_start <= 1'b1;
                    tx_idx   <= tx_idx + 6'd1;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
