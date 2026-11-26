// 09 same-line race test: the whole fb_core (UART -> cache_ex -> cs150
// RequestController -> rc_axi_fifo_adapter) against sim/axi4_slave_rand.v
// (from patch 0001), a hostile AXI slave that commits a write only when its
// B is presented and samples a read when its burst starts, with random
// latencies, so a read that is not ordered behind an earlier same-line write
// returns stale data, as HP0 may legally do.
// Runs ITER rounds of the UART commands
//   E addr data     D write miss, then immediate D re-miss of the line
//   O addr data     D write, then immediate I fetch of the line
//   E x addr data   fill, write hit, 8 KiB conflict miss, re-miss
// with fresh data and lines each round, and counts "F" replies.
//   EXPECT_FAIL=0  (patched adapter, or 08's direction barrier): TB_PASS iff no F
//   EXPECT_FAIL=1  (adapter with the hazard check removed): TB_PASS iff >= 1 F,
//                  i.e. the test really detects the race
`timescale 1ns/1ps
module tb_hazard;
    parameter ITER        = 16;
    parameter SEED        = 32'h1234_5678;
    parameter EXPECT_FAIL = 0;
    localparam H_ACT = 64, H_FP = 8, H_SYN = 8, H_BP = 8;
    localparam V_ACT = 16, V_FP = 1, V_SYN = 2, V_BP = 2;
    localparam BAUD = 10_000_000;
    localparam [31:0] BASE = 32'h1690_0040;
    localparam MEM_AW = 24;

    reg clk = 0, pix_clk = 0, rst = 1, pix_rst = 1, locked = 0;
    always #5    clk = ~clk;
    always #12.5 pix_clk = ~pix_clk;

    wire rxd_dut, txd_dut;
    reg  h_start = 0; reg [7:0] h_data = 0; wire h_busy, h_valid; wire [7:0] h_rx;
    uart_tx #(.CLK_FREQ(100_000_000), .BAUD(BAUD)) h_tx (.clk(clk), .rst(rst), .start(h_start),
        .data_in(h_data), .busy(h_busy), .txd(rxd_dut));
    uart_rx #(.CLK_FREQ(100_000_000), .BAUD(BAUD)) h_rxm (.clk(clk), .rst(rst), .rxd(txd_dut),
        .valid(h_valid), .data(h_rx));

    wire [0:0] awid, arid; wire [31:0] awaddr, araddr; wire [7:0] awlen, arlen;
    wire [2:0] awsize, arsize, awprot, arprot; wire [1:0] awburst, arburst, bresp, rresp;
    wire awlock, arlock; wire [3:0] awcache, arcache, awqos, arqos, awregion, arregion;
    wire awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
    wire [63:0] wdata, rdata; wire [7:0] wstrb;
    wire [7:0] vr, vg, vb; wire vde, vhs, vvs, tick, rx_toggle, pf_running, uf_sticky;

    fb_core #(.CLK_FREQ(100_000_000), .BAUD(BAUD), .WIN_AW(24),
              .H_ACT(H_ACT), .H_FP(H_FP), .H_SYN(H_SYN), .H_BP(H_BP),
              .V_ACT(V_ACT), .V_FP(V_FP), .V_SYN(V_SYN), .V_BP(V_BP)) dut (
        .clk(clk), .rst(rst), .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(locked),
        .rxd(rxd_dut), .txd(txd_dut), .rx_toggle(rx_toggle), .pf_running(pf_running), .uf_sticky(uf_sticky),
        .vid_r(vr), .vid_g(vg), .vid_b(vb), .vid_de(vde), .vid_hs(vhs), .vid_vs(vvs), .frame_tick(tick),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache), .m_axi_awprot(awprot),
        .m_axi_awqos(awqos), .m_axi_awregion(awregion), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bid(1'b0), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
        .m_axi_bready(bready), .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arcache(arcache),
        .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion), .m_axi_arvalid(arvalid),
        .m_axi_arready(arready), .m_axi_rid(1'b0), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

    axi4_slave_rand #(.MEM_AW(MEM_AW), .SEED(SEED)) mem (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready));

    integer errors = 0;
    reg [7:0] rq [0:255]; integer rq_w = 0, rq_r = 0;
    always @(posedge clk) if (h_valid) begin rq[rq_w % 256] = h_rx; rq_w = rq_w + 1; end
    task send; input [7:0] c; begin
        @(posedge clk); while (h_busy) @(posedge clk);
        h_data <= c; h_start <= 1; @(posedge clk); h_start <= 0; @(posedge clk);
        while (h_busy) @(posedge clk);
    end endtask
    task recv; output [7:0] c; integer t; begin
        t = 0;
        while (rq_r == rq_w && t < 2_000_000) begin @(posedge clk); t = t + 1; end
        if (rq_r == rq_w) begin c = 8'h00; $display("ERROR: UART reply timeout"); errors = errors + 1; end
        else begin c = rq[rq_r % 256]; rq_r = rq_r + 1; end
    end endtask
    reg [7:0] lb [0:127]; integer ln;
    task recv_line; reg [7:0] c; begin
        ln = 0; c = 8'h00;
        while (c != 8'h0A && ln < 127) begin recv(c); lb[ln] = c; ln = ln + 1; if (c == 8'h00) c = 8'h0A; end
    end endtask
    task send_str; input [8*16-1:0] s; integer q; reg st; begin
        st = 0;
        for (q = 15; q >= 0; q = q - 1)
            if (st || s[8*q +: 8] != 8'h00) begin st = 1; send(s[8*q +: 8]); end
    end endtask
    task send_hex; input [31:0] v; integer q; reg [3:0] n; begin
        send("0"); send("x");
        for (q = 7; q >= 0; q = q - 1) begin n = v[4*q +: 4]; send(n < 10 ? "0" + n : "A" + n - 10); end
    end endtask

    integer it, k, fails = 0, notmiss = 0, total = 0;
    integer nf [0:2];
    reg [31:0] a, d;
    reg [8*4-1:0] tag;
    initial begin
        nf[0] = 0; nf[1] = 0; nf[2] = 0;
        #200 rst = 0;
        #500 locked = 1;
        #300 @(posedge pix_clk) pix_rst = 0;
        wait (pf_running);                    // frame 0: PixelFeeder local pattern, no DDR
        send("A"); send(BASE[7:0]); send(BASE[15:8]); send(BASE[23:16]); send(BASE[31:24]);
        recv(lb[0]); if (lb[0] != "K") begin $display("ERROR: A"); errors = errors + 1; end
        for (it = 0; it < ITER; it = it + 1) begin
            for (k = 0; k < 3; k = k + 1) begin
                a = 32'hC0_0000 + (it * 3 + k) * 32'h40 + 32'h0C;
                d = {8'h5A, it[7:0], k[7:0], 8'h00} ^ SEED;
                case (k)
                0: begin send_str("E ");   tag = "E";   end
                1: begin send_str("O ");   tag = "O";   end
                default: begin send_str("E x "); tag = "E x"; end
                endcase
                send_hex(a); send(" "); send_hex(d); send(8'h0A);
                recv_line;
                total = total + 1;
                if (lb[2] != "P") begin
                    fails = fails + 1; nf[k] = nf[k] + 1;
                    if (fails <= 6) $display("  race %0s @%08x: %c%c%c ... got %c%c%c%c%c%c%c%c exp %08x", tag, a,
                        lb[0], lb[1], lb[2], lb[4], lb[5], lb[6], lb[7], lb[8], lb[9], lb[10], lb[11], d);
                end
                if (lb[40] != "m") notmiss = notmiss + 1;
            end
        end
        $display("HZ_RESULT seed=%08x tests=%0d stale=%0d (E %0d, O %0d, E x %0d) not-a-miss=%0d errors=%0d",
                 SEED, total, fails, nf[0], nf[1], nf[2], notmiss, errors);
        if (notmiss != 0) errors = errors + 1;
        if (EXPECT_FAIL == 0) begin
            if (errors == 0 && fails == 0) $display("TB_PASS"); else $display("TB_FAIL");
        end else begin
            if (errors == 0 && fails > 0) $display("TB_PASS (race detected, as expected without a hazard check)");
            else $display("TB_FAIL (expected stale reads, saw none)");
        end
        $finish;
    end
    initial begin #100_000_000; $display("TB_FAIL timeout"); $finish; end
endmodule
