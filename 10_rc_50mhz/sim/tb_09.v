// Self-checking Icarus testbench for the 10 core (fb_core, from 09): the full 08
// sequence (frame_drawer now on the RC fill_* port) plus every 09 UART command:
// D-cache / I-cache reads, writes, fill / verify, the same-line race commands
// E / E x / O, counters M, ScanLineRunner spans Y / L, and parser errors.
// UART FSM -> frame_drawer -> cs150 RequestController (fill port),
// proj150 PixelFeeder (pixf port) -> RequestController -> rc_axi_fifo_adapter
// (proj150 FIFO models) -> pipelined AXI4 slave model; video out of the sink.
// Reduced raster (64x16 active, same structure as 800x600) so a run covers
// many frames. 50 MHz clk (RC/UART), 100 MHz axi_clk (HP0 side), 40 MHz pix_clk, UART 1 Mbaud.
`timescale 1ns/1ps
module tb_10;
    localparam H_ACT = 64, H_FP = 8, H_SYN = 8, H_BP = 8;
    localparam V_ACT = 16, V_FP = 1, V_SYN = 2, V_BP = 2;
    localparam H_TOT = H_ACT + H_FP + H_SYN + H_BP;
    localparam V_TOT = V_ACT + V_FP + V_SYN + V_BP;
    localparam BAUD = 1_000_000;
    localparam [31:0] BASE = 32'h1690_0040;   // 32 B aligned, not page aligned
    localparam MEM_AW = 24;   // 16 MiB: frames 1 and 2 must not alias

    reg clk = 0, axi_clk = 0, pix_clk = 0, rst = 1, axi_rst = 1, pix_rst = 1, locked = 0;
    always #10   clk     = ~clk;      // 50 MHz RC / UART
    always #5    axi_clk = ~axi_clk;  // 100 MHz AXI / HP0
    always #12.5 pix_clk = ~pix_clk;

    // ---- host UART
    wire rxd_dut, txd_dut;
    reg  h_start = 0; reg [7:0] h_data = 0; wire h_busy, h_valid; wire [7:0] h_rx;
    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(BAUD)) h_tx (.clk(clk), .rst(rst), .start(h_start),
        .data_in(h_data), .busy(h_busy), .txd(rxd_dut));
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(BAUD)) h_rxm (.clk(clk), .rst(rst), .rxd(txd_dut),
        .valid(h_valid), .data(h_rx));

    // ---- AXI
    wire [0:0] awid, arid; wire [31:0] awaddr, araddr; wire [7:0] awlen, arlen;
    wire [2:0] awsize, arsize, awprot, arprot; wire [1:0] awburst, arburst, bresp, rresp;
    wire awlock, arlock; wire [3:0] awcache, arcache, awqos, arqos, awregion, arregion;
    wire awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
    wire [63:0] wdata, rdata; wire [7:0] wstrb;

    wire [7:0] vr, vg, vb; wire vde, vhs, vvs, tick, rx_toggle, pf_running, uf_sticky;
    fb_core #(.CLK_FREQ(50_000_000), .BAUD(BAUD), .WIN_AW(24),
              .H_ACT(H_ACT), .H_FP(H_FP), .H_SYN(H_SYN), .H_BP(H_BP),
              .V_ACT(V_ACT), .V_FP(V_FP), .V_SYN(V_SYN), .V_BP(V_BP)) dut (
        .clk(clk), .rst_in(rst), .axi_clk(axi_clk), .axi_rst(axi_rst),
        .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(locked),
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

    axi4_slave_pipe #(.MEM_AW(MEM_AW), .STALL(1)) mem (
        .clk(axi_clk), .rst(axi_rst),
        .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    integer errors = 0;

    // ---- AXI address checks: every access inside the 16 MiB window at BASE
    // (frames 1..2 for the drawer / SLR / PixelFeeder, anywhere for the caches)
    always @(posedge axi_clk) begin
        if (awvalid && awready && (awaddr < BASE || awaddr >= BASE + 32'h100_0000)) begin
            $display("ERROR: AW 0x%08x outside the window", awaddr); errors = errors + 1; end
        if (arvalid && arready && (araddr < BASE || araddr >= BASE + 32'h100_0000)) begin
            $display("ERROR: AR 0x%08x outside the window", araddr); errors = errors + 1; end
    end

    // ---- video monitor: last complete frame, sync checks
    reg [23:0] fb [0:V_ACT-1][0:H_ACT-1];
    reg [23:0] last [0:V_ACT-1][0:H_ACT-1];
    integer cx = 0, cy = 0, de_cnt = 0, frames = 0, bad_frames = 0, line_de = 0;
    integer hs_per = 0, hs_bad = 0, pclk = 0, hs_last = -1;
    reg vs_d = 0, hs_d = 0, de_d = 0;
    integer i, j;
    always @(posedge pix_clk) begin
        pclk = pclk + 1;
        hs_d <= vhs; vs_d <= vvs; de_d <= vde;
        if (vhs && !hs_d) begin
            if (hs_last >= 0 && pclk - hs_last != H_TOT) hs_bad = hs_bad + 1;
            hs_last = pclk; hs_per = hs_per + 1;
        end
        if (vde) begin
            if (cy < V_ACT && cx < H_ACT) fb[cy][cx] = {vr, vg, vb};
            cx = cx + 1; de_cnt = de_cnt + 1;
        end
        if (de_d && !vde) begin cx = 0; cy = cy + 1; end
        if (vvs && !vs_d) begin
            if (de_cnt == H_ACT * V_ACT) begin
                for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1) last[i][j] = fb[i][j];
                frames = frames + 1;
            end else if (frames > 0) bad_frames = bad_frames + 1;
            de_cnt = 0; cx = 0; cy = 0;
        end
    end

    // ---- UART helpers
    reg [7:0] rq [0:255]; integer rq_w = 0, rq_r = 0;
    always @(posedge clk) if (h_valid) begin rq[rq_w % 256] = h_rx; rq_w = rq_w + 1; end

    task send; input [7:0] c; begin
        @(posedge clk); while (h_busy) @(posedge clk);
        h_data <= c; h_start <= 1; @(posedge clk); h_start <= 0; @(posedge clk);
        while (h_busy) @(posedge clk);
    end endtask

    task recv; output [7:0] c; integer t; begin
        t = 0;
        while (rq_r == rq_w && t < 20_000_000) begin @(posedge clk); t = t + 1; end
        if (rq_r == rq_w) begin c = 8'h00; $display("ERROR: UART reply timeout"); errors = errors + 1; end
        else begin c = rq[rq_r % 256]; rq_r = rq_r + 1; end
    end endtask

    task expect1; input [8*8-1:0] what; input [7:0] e; reg [7:0] c; begin
        recv(c);
        if (c !== e) begin $display("ERROR: %0s: got '%c' (0x%02x) expected '%c'", what, c, c, e); errors = errors + 1; end
        else $display("  %0s -> '%c'", what, c);
    end endtask

    task wait_frames; input integer n; integer f0; begin
        f0 = frames; while (frames < f0 + n) @(posedge pix_clk);
    end endtask

    // expected pixel for each drawer mode (mirrors frame_drawer)
    function [23:0] exp_pix; input [2:0] md; input [23:0] c; input integer x, y;
        integer bar, k; reg [31:0] tx, ty; begin
        bar = 0; for (k = 1; k < 8; k = k + 1) if (x >= (k * H_ACT) / 8) bar = k;
        tx = x * (262143 / (H_ACT - 1)); ty = y * (262143 / (V_ACT - 1));
        case (md)
        0: exp_pix = c;
        1: case (bar) 0: exp_pix = 24'hFFFFFF; 1: exp_pix = 24'hFFFF00; 2: exp_pix = 24'h00FFFF;
                      3: exp_pix = 24'h00FF00; 4: exp_pix = 24'hFF00FF; 5: exp_pix = 24'hFF0000;
                      6: exp_pix = 24'h0000FF; default: exp_pix = 24'h000000; endcase
        2: exp_pix = (((x >> 5) ^ (y >> 5)) & 1) ? 24'h202020 : 24'hFFFFFF;
        3: exp_pix = {tx[17:10], ty[17:10], ~tx[17:10]};
        4: if (x <= 1 || x >= H_ACT - 2 || y <= 1 || y >= V_ACT - 2) exp_pix = 24'hFF0000;
           else if (x == H_ACT/2 - 1 || x == H_ACT/2 || y == V_ACT/2 - 1 || y == V_ACT/2) exp_pix = 24'h00FF00;
           else if ((x % 64) == 0 || (y % 64) == 0) exp_pix = 24'hFFFFFF;
           else exp_pix = 24'h000000;
        default: exp_pix = 0;
        endcase
    end endfunction

    task check_frame; input [8*10-1:0] what; input [2:0] md; input [23:0] c; integer bad; begin
        bad = 0;
        for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1)
            if (last[i][j] !== exp_pix(md, c, j, i)) begin
                if (bad < 4) $display("    %0s: pixel (%0d,%0d) = %06x expected %06x", what, j, i, last[i][j], exp_pix(md, c, j, i));
                bad = bad + 1;
            end
        if (bad) begin $display("ERROR: %0s: %0d bad pixels on screen", what, bad); errors = errors + 1; end
        else $display("  %0s: all %0d displayed pixels correct", what, H_ACT * V_ACT);
    end endtask

    // DDR (model) layout: pixel x of line y in frame f at
    //   BASE + f*4 MiB + y*4096 + (x & ~3)*4 + (3 - (x & 3))*4, 32-bit LE 0x00RRGGBB
    task check_mem; input integer f; input [2:0] md; input [23:0] c; integer a, bad; reg [31:0] w; begin
        bad = 0;
        for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1) begin
            a = BASE + f * 32'h40_0000 + i * 4096 + (j & ~3) * 4 + (3 - (j & 3)) * 4;
            w = {mem.mem[(a + 3) % (1 << MEM_AW)], mem.mem[(a + 2) % (1 << MEM_AW)],
                 mem.mem[(a + 1) % (1 << MEM_AW)], mem.mem[a % (1 << MEM_AW)]};
            if (w !== {8'h00, exp_pix(md, c, j, i)}) bad = bad + 1;
        end
        if (bad) begin $display("ERROR: memory frame %0d: %0d bad pixels", f, bad); errors = errors + 1; end
        else $display("  memory frame %0d layout correct (%0d pixels)", f, H_ACT * V_ACT);
    end endtask

    reg [7:0] ustat [0:22];
    task status; integer n; begin
        send("U");
        for (n = 0; n < 23; n = n + 1) recv(ustat[n]);
        $display("  U -> %c%c %c%c%c%c %c%c%c%c W%c%c%c%c%c%c%c%c", ustat[0], ustat[1],
            ustat[3], ustat[4], ustat[5], ustat[6], ustat[8], ustat[9], ustat[10], ustat[11],
            ustat[14], ustat[15], ustat[16], ustat[17], ustat[18], ustat[19], ustat[20], ustat[21]);
        if (ustat[22] != 8'h0A) begin $display("ERROR: U line not terminated"); errors = errors + 1; end
    end endtask

    // ---- 09 line-based helpers (ASCII commands, '\n'-terminated replies)
    reg [7:0] lb [0:127]; integer ln;
    task sendln; input [8*80-1:0] s; integer q; reg started; begin
        started = 0;
        for (q = 79; q >= 0; q = q - 1)
            if (started || s[8*q +: 8] != 8'h00) begin started = 1; send(s[8*q +: 8]); end
        send(8'h0A);
    end endtask
    task recv_line; reg [7:0] c; begin
        ln = 0; c = 8'h00;
        while (c != 8'h0A && ln < 127) begin
            recv(c); lb[ln] = c; ln = ln + 1;
            if (c == 8'h00) c = 8'h0A;          // timeout
        end
    end endtask
    task show_line; input [8*12-1:0] what; reg [8*100-1:0] t; integer q; begin
        t = 0;
        for (q = 0; q < ln && lb[q] != 8'h0A; q = q + 1) t = {t[8*99-1:0], lb[q]};
        $display("  %0s -> \"%0s\"", what, t);
    end endtask
    // compare the received line with s (prefix only if pfx)
    task chk_line; input [8*12-1:0] what; input [8*80-1:0] s; input pfx;
        integer q, n, bad; reg [7:0] b; reg started; begin
        recv_line; show_line(what);
        n = 0; bad = 0; started = 0;
        for (q = 79; q >= 0; q = q - 1) begin
            b = s[8*q +: 8];
            if (started || b != 8'h00) begin
                started = 1;
                if (lb[n] !== b) bad = 1;
                n = n + 1;
            end
        end
        if (!pfx && lb[n] !== 8'h0A) bad = 1;
        if (bad) begin $display("ERROR: %0s: reply does not match \"%0s\"", what, s); errors = errors + 1; end
    end endtask
    task expect_line; input [8*12-1:0] what; input [8*80-1:0] s; begin chk_line(what, s, 0); end endtask
    task expect_pfx;  input [8*12-1:0] what; input [8*80-1:0] s; begin chk_line(what, s, 1); end endtask
    function [31:0] hexat; input integer p; integer q; reg [7:0] c; begin
        hexat = 0;
        for (q = 0; q < 8; q = q + 1) begin
            c = lb[p+q];
            hexat = {hexat[27:0], (c >= "A") ? (c[3:0] + 4'd9) : c[3:0]};
        end
    end endfunction
    task race_ok; input [8*12-1:0] what; begin
        if (lb[2] !== "P" || lb[40] !== "m") begin
            $display("ERROR: %0s: race test %c / final read %c (need P / m)", what, lb[2], lb[40]); errors = errors + 1; end
        else $display("    %0s: pass, write %0d cyc, re-fetch %0d cyc", what, hexat(22), hexat(31));
    end endtask

    // reference picture of frame 1 for the 09 checks
    reg [23:0] refimg [0:V_ACT-1][0:H_ACT-1];
    task ref_fill; input [23:0] c; begin
        for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1) refimg[i][j] = c;
    end endtask
    task ref_span; input integer y, xa, xb; input [23:0] c; integer x; begin
        for (x = (xa < xb ? xa : xb); x <= (xa < xb ? xb : xa); x = x + 1) refimg[y][x] = c;
    end endtask
    task check_ref_frame; input [8*10-1:0] what; integer bad; begin
        bad = 0;
        for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1)
            if (last[i][j] !== refimg[i][j]) begin
                if (bad < 6) $display("    %0s: screen (%0d,%0d) = %06x expected %06x", what, j, i, last[i][j], refimg[i][j]);
                bad = bad + 1;
            end
        if (bad) begin $display("ERROR: %0s: %0d bad pixels on screen", what, bad); errors = errors + 1; end
        else $display("  %0s: all %0d displayed pixels match the reference", what, H_ACT * V_ACT);
    end endtask
    task check_ref_mem; input [8*10-1:0] what; integer a, bad; reg [31:0] w; begin
        bad = 0;
        for (i = 0; i < V_ACT; i = i + 1) for (j = 0; j < H_ACT; j = j + 1) begin
            a = BASE + 32'h40_0000 + i * 4096 + (j & ~3) * 4 + (3 - (j & 3)) * 4;
            w = {mem.mem[(a + 3) % (1 << MEM_AW)], mem.mem[(a + 2) % (1 << MEM_AW)],
                 mem.mem[(a + 1) % (1 << MEM_AW)], mem.mem[a % (1 << MEM_AW)]};
            if (w[23:0] !== refimg[i][j]) begin
                if (bad < 6) $display("    %0s: memory (%0d,%0d) = %08x expected %06x", what, j, i, w, refimg[i][j]);
                bad = bad + 1;
            end
        end
        if (bad) begin $display("ERROR: %0s: %0d bad pixels in frame 1 memory", what, bad); errors = errors + 1; end
        else $display("  %0s: frame 1 memory matches the reference", what);
    end endtask

    integer rs0;
    initial begin
        $display("tb_fb: %0dx%0d active, %0dx%0d total", H_ACT, V_ACT, H_TOT, V_TOT);
        #200 rst = 0; axi_rst = 0;
        #500 locked = 1;
        #300 @(posedge pix_clk) pix_rst = 0;

        // PixelFeeder starts in its local-pattern frame (frame 0, no DDR)
        wait (pf_running);
        $display("  sink running on PixelFeeder local pattern at %0t ns", $time);
        wait_frames(2);

        send("C"); expect1("C noA", "N");
        sendln("R 0xC00000"); expect_line("R noA", "N");
        sendln("L 1 2 3");    expect_line("L noA", "N");
        send("A"); send(BASE[7:0]); send(BASE[15:8]); send(BASE[23:16]); send(BASE[31:24]);
        expect1("A", "K");
        send("S"); send(8'd1); expect1("S 1", "K");
        send("S"); send(8'd3); expect1("S 3", "?");

        send("F"); send(8'h12); send(8'h34); send(8'h56); expect1("F", "D");
        check_mem(1, 0, 24'h123456);
        wait_frames(4); check_frame("fill", 0, 24'h123456);

        send("B"); expect1("B", "D"); check_mem(1, 1, 0);
        wait_frames(4); check_frame("bars", 1, 0);
        send("H"); expect1("H", "D"); wait_frames(4); check_frame("checker", 2, 0);
        send("G"); expect1("G", "D"); wait_frames(4); check_frame("gradient", 3, 0);
        send("X"); expect1("X", "D"); wait_frames(4); check_frame("grid", 4, 0);

        // draw into frame 2 while frame 1 is shown, then flip
        send("T"); send(8'd2); expect1("T 2", "K");
        send("C"); expect1("C f2", "D");
        wait_frames(3); check_frame("still f1", 4, 0);
        send("S"); send(8'd2); expect1("S 2", "K");
        wait_frames(4); check_frame("flip f2", 0, 24'h000000);
        check_mem(1, 4, 0); check_mem(2, 0, 0);

        status;
        if (ustat[1] != "0") begin $display("ERROR: underflow with gap 16"); errors = errors + 1; end

        // test-pattern fallback and back
        send("V"); expect1("V pat", "v"); wait_frames(2);
        send("V"); expect1("V pf", "V"); wait_frames(3); check_frame("back pf", 0, 24'h000000);

        // no gap: dcache writes may starve PixelFeeder (lower priority) -> underflow, auto resync
        rs0 = dut.resyncs;
        send("P"); send(8'd0); expect1("P 0", "K");
        send("F"); send(8'hA0); send(8'hB0); send(8'hC0); expect1("F nogap", "D");
        status;
        $display("  gap 0 fill: draw %0d cycles, underflow=%c, resyncs %0d -> %0d",
                 dut.dcyc, ustat[1], rs0, dut.resyncs);
        wait (pf_running); wait_frames(4); check_frame("after gap0", 0, 24'hA0B0C0);

        // forced resync
        rs0 = dut.resyncs;
        send("Z"); expect1("Z", "K");
        wait (!pf_running); wait (pf_running); wait_frames(4);
        check_frame("after Z", 0, 24'hA0B0C0);
        if (dut.resyncs != rs0 + 1) begin $display("ERROR: resync count %0d -> %0d", rs0, dut.resyncs); errors = errors + 1; end

        // injected underflow: hide video_valid for 4 active pixels -> sticky flag,
        // automatic resync, picture back; 'U' reports and clears the flag
        rs0 = dut.resyncs;
        wait (vde && vvs == 0); @(posedge pix_clk);
        wait (dut.u_sink.de_in); force dut.video_valid = 1'b0;
        repeat (4) @(posedge pix_clk); release dut.video_valid;
        wait (!pf_running); wait (pf_running); wait_frames(4);
        check_frame("after uf", 0, 24'hA0B0C0);
        status;
        if (ustat[1] != "1" || dut.resyncs != rs0 + 1) begin
            $display("ERROR: injected underflow not reported / resynced (%c, %0d -> %0d)", ustat[1], rs0, dut.resyncs);
            errors = errors + 1;
        end else $display("  injected underflow: reported, auto resync %0d -> %0d, picture recovered", rs0, dut.resyncs);
        status;
        if (ustat[1] != "0") begin $display("ERROR: U did not clear the flag"); errors = errors + 1; end

        // ======================= 09 =======================
        $display("-- 09: caches, ScanLineRunner, ASCII parser");
        sendln("M c");
        expect_line("M c", "M IH=00000000 IM=00000000 IC=00000000 DH=00000000 DM=00000000 DC=00000000");
        send("P"); send(8'd16); expect1("P 16", "K");
        send("T"); send(8'd1); expect1("T 1", "K");
        send("F"); send(8'h10); send(8'h20); send(8'h30); expect1("F 102030", "D");
        ref_fill(24'h102030);
        send("S"); send(8'd1); expect1("S 1", "K");

        // D-cache reads of a pixel the drawer wrote (frame 1, x=7, y=3)
        sendln("R 0x40301C");  expect_pfx("R miss", "R 00102030 m ");
        sendln("R 4206620");   expect_line("R hit dec", "R 00102030 h 00000001");
        // write through the D-cache into the picture (hit: line just fetched)
        sendln("W 0x40301C 0xABCDEF"); expect_pfx("W hit", "W h ");
        refimg[3][7] = 24'hABCDEF;
        sendln("R 0x40301C");  expect_pfx("R after W", "R 00ABCDEF h ");
        // the I-cache fetches it from DDR (write-through landed)
        sendln("J 0x40301C");  expect_pfx("J miss", "J 00ABCDEF m ");
        sendln("J 0x40301C");  expect_pfx("J hit", "J 00ABCDEF h ");
        // write miss: no allocate, the following read misses and gets the new word
        sendln("W 0x404000 0x445566"); expect_pfx("W miss", "W m ");
        refimg[4][0] = 24'h445566;
        sendln("R 0x404000");  expect_pfx("R after Wm", "R 00445566 m ");
        // range read: one 32-byte line = 1 miss + 7 hits
        sendln("R 0x400000 8");
        expect_line("R range", "R 00102030 00102030 H=00000007 M=00000001");
        wait_frames(3); check_ref_frame("cache px"); check_ref_mem("cache px");

        // fill / verify in the cache test region (+12 MiB)
        sendln("D f 0xC00000 64 0x11110000"); expect_line("D f", "D P 00000000 00000040");
        sendln("D v 0xC00000 64 0x11110000"); expect_line("D v", "D P 00000038 00000008");
        sendln("D v 0xC00000,64,0x11110001;"); expect_line("D v bad", "D F 00C00000 11110000 11110001");
        sendln("J 0xC00000 16"); expect_line("J range", "J 11110000 1111000F H=0000000E M=00000002");

        // same-line races (write then immediate re-fetch of that line)
        sendln("E 0xC00100 0x12345678");   expect_pfx("E", "E P 12345678 12345678 "); race_ok("E");
        sendln("E x 0xC00200 0x0BADBEEF"); expect_pfx("E x", "X P 0BADBEEF 0BADBEEF "); race_ok("E x");
        sendln("O 0xC00300 0xCAFEF00D");   expect_pfx("O", "O P CAFEF00D CAFEF00D "); race_ok("O");
        sendln("E 0xC00400");              expect_pfx("E dflt", "E P A5000003 A5000003 "); race_ok("E dflt");

        // counters: clear, 1 miss + 1 hit on each cache
        sendln("M c"); recv_line; show_line("M c (old)");
        sendln("R 0xC01000"); expect_pfx("cnt R1", "R CCCCCCCC m ");
        sendln("R 0xC01004"); expect_pfx("cnt R2", "R CCCCCCCC h ");
        sendln("J 0xC01000"); expect_pfx("cnt J1", "J CCCCCCCC m ");
        sendln("J 0xC01008"); expect_pfx("cnt J2", "J CCCCCCCC h ");
        sendln("M"); recv_line; show_line("M");
        if (hexat(5) != 1 || hexat(17) != 1 || hexat(41) != 1 || hexat(53) != 1 ||
            hexat(29) < 3 || hexat(65) < 3 || lb[73] != 8'h0A) begin
            $display("ERROR: counters IH=%0d IM=%0d IC=%0d DH=%0d DM=%0d DC=%0d",
                     hexat(5), hexat(17), hexat(29), hexat(41), hexat(53), hexat(65)); errors = errors + 1;
        end else $display("    counters ok: I miss+hit %0d cyc, D miss+hit %0d cyc", hexat(29), hexat(65));

        // parser / range errors
        sendln("R");               expect_line("R noarg", "?");
        sendln("R 0xZZ");          expect_line("R badhex", "?");
        sendln("R 0x");            expect_line("R 0x", "?");
        sendln("R 4294967296");    expect_line("R ovf dec", "?");
        sendln("R 0x100000000");   expect_line("R ovf hex", "?");
        sendln("R 1 2 3 4 5");     expect_line("R 5 args", "?");
        sendln("R 0xC00000 0");    expect_line("R n=0", "?");
        sendln("D 0xC00000 1 2");  expect_line("D nosub", "?");
        sendln("W 1");             expect_line("W 1 arg", "?");
        sendln("L 16 0 1");        expect_line("L row", "?");
        sendln("L 1 0 64");        expect_line("L x1", "?");
        sendln("M x");             expect_line("M x", "?");
        sendln("Y");               expect_line("Y noarg", "?");

        // ScanLineRunner spans on frame 1 (shown)
        send("F"); send(8'h00); send(8'h00); send(8'h00); expect1("F black", "D");
        ref_fill(24'h000000);
        sendln("Y 0xff0000");          expect_line("Y red", "K");
        sendln("L 3,10,40");           expect_line("L 3", "D");   ref_span(3, 10, 40, 24'hFF0000);
        sendln("L 5 50 7;");           expect_line("L 5 rev", "D"); ref_span(5, 7, 50, 24'hFF0000);
        sendln("L 7 0 63 0x0000ff");   expect_line("L 7 full", "D"); ref_span(7, 0, 63, 24'h0000FF);
        sendln("L 9 33 33");           expect_line("L 9 1px", "D"); ref_span(9, 33, 33, 24'hFF0000);
        sendln("L 11 2 61 0x00ffff00"); expect_line("L 11 edge", "D");
        refimg[11][2] = 24'hFFFF00; refimg[11][61] = 24'hFFFF00;
        sendln("Y 65280");             expect_line("Y dec", "K");
        sendln("L 13 20 21");          expect_line("L 13", "D"); ref_span(13, 20, 21, 24'h00FF00);
        sendln("L 0xF 0 0 0xFFFFFF");  expect_line("L 15 1px", "D"); ref_span(15, 0, 0, 24'hFFFFFF);
        sendln("L 1 4 11 0x123456");   expect_line("L 1 chunk", "D"); ref_span(1, 4, 11, 24'h123456);
        wait_frames(4); check_ref_frame("SLR"); check_ref_mem("SLR");
        status;
        $display("    last span (L 1 4 11): %0d cycles to D", dut.dcyc);
        // SLR pixel read back through the D-cache (SLR stores 0xFF in [31:24])
        sendln("R 0x403028"); expect_pfx("R SLR px", "R FFFF0000 m ");
        // D-cache write into an SLR row shows on screen too
        sendln("W 0x403000 0x00FF00FF"); expect_pfx("W on SLR", "W ");
        refimg[3][0] = 24'hFF00FF;
        wait_frames(3); check_ref_frame("SLR+W"); check_ref_mem("SLR+W");
        status;
        if (ustat[1] != "0") $display("  note: underflow seen during the 09 section (auto resync)");

        $display("frames=%0d bad_frames=%0d hsync periods=%0d bad=%0d", frames, bad_frames, hs_per, hs_bad);
        if (bad_frames != 0 || hs_bad != 0) errors = errors + 1;
        if (errors == 0) $display("TB_PASS"); else $display("TB_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #400_000_000; $display("TB_FAIL timeout"); $finish; end
endmodule
