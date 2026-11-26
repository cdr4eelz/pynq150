// Self-checking Icarus testbench for the 08 framebuffer core (fb_core):
// UART FSM -> frame_drawer -> cs150 RequestController (dcache port),
// proj150 PixelFeeder (pixf port) -> RequestController -> rc_axi_fifo_adapter
// (proj150 FIFO models) -> pipelined AXI4 slave model; video out of the sink.
// Reduced raster (64x16 active, same structure as 800x600) so a run covers
// many frames. 100 MHz clk, 40 MHz pix_clk, UART 1 Mbaud.
`timescale 1ns/1ps
module tb_fb;
    localparam H_ACT = 64, H_FP = 8, H_SYN = 8, H_BP = 8;
    localparam V_ACT = 16, V_FP = 1, V_SYN = 2, V_BP = 2;
    localparam H_TOT = H_ACT + H_FP + H_SYN + H_BP;
    localparam V_TOT = V_ACT + V_FP + V_SYN + V_BP;
    localparam BAUD = 1_000_000;
    localparam [31:0] BASE = 32'h1690_0040;   // 32 B aligned, not page aligned
    localparam MEM_AW = 24;   // 16 MiB: frames 1 and 2 must not alias

    reg clk = 0, pix_clk = 0, rst = 1, pix_rst = 1, locked = 0;
    always #5    clk = ~clk;
    always #12.5 pix_clk = ~pix_clk;

    // ---- host UART
    wire rxd_dut, txd_dut;
    reg  h_start = 0; reg [7:0] h_data = 0; wire h_busy, h_valid; wire [7:0] h_rx;
    uart_tx #(.CLK_FREQ(100_000_000), .BAUD(BAUD)) h_tx (.clk(clk), .rst(rst), .start(h_start),
        .data_in(h_data), .busy(h_busy), .txd(rxd_dut));
    uart_rx #(.CLK_FREQ(100_000_000), .BAUD(BAUD)) h_rxm (.clk(clk), .rst(rst), .rxd(txd_dut),
        .valid(h_valid), .data(h_rx));

    // ---- AXI
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

    axi4_slave_pipe #(.MEM_AW(MEM_AW), .STALL(1)) mem (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    integer errors = 0;

    // ---- AXI address checks: every access inside frame 1/2 of the window
    always @(posedge clk) begin
        if (awvalid && awready && (awaddr < BASE + 32'h40_0000 || awaddr >= BASE + 32'hC0_0000)) begin
            $display("ERROR: AW 0x%08x outside frames 1..2", awaddr); errors = errors + 1; end
        if (arvalid && arready && (araddr < BASE + 32'h40_0000 || araddr >= BASE + 32'hC0_0000)) begin
            $display("ERROR: AR 0x%08x outside frames 1..2", araddr); errors = errors + 1; end
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
    reg [7:0] rq [0:63]; integer rq_w = 0, rq_r = 0;
    always @(posedge clk) if (h_valid) begin rq[rq_w % 64] = h_rx; rq_w = rq_w + 1; end

    task send; input [7:0] c; begin
        @(posedge clk); while (h_busy) @(posedge clk);
        h_data <= c; h_start <= 1; @(posedge clk); h_start <= 0; @(posedge clk);
        while (h_busy) @(posedge clk);
    end endtask

    task recv; output [7:0] c; integer t; begin
        t = 0;
        while (rq_r == rq_w && t < 20_000_000) begin @(posedge clk); t = t + 1; end
        if (rq_r == rq_w) begin c = 8'h00; $display("ERROR: UART reply timeout"); errors = errors + 1; end
        else begin c = rq[rq_r % 64]; rq_r = rq_r + 1; end
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

    integer rs0;
    initial begin
        $display("tb_fb: %0dx%0d active, %0dx%0d total", H_ACT, V_ACT, H_TOT, V_TOT);
        #200 rst = 0;
        #500 locked = 1;
        #300 @(posedge pix_clk) pix_rst = 0;

        // PixelFeeder starts in its local-pattern frame (frame 0, no DDR)
        wait (pf_running);
        $display("  sink running on PixelFeeder local pattern at %0t ns", $time);
        wait_frames(2);

        send("C"); expect1("C noA", "N");
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

        // debug probe: R x=5 y=3 (twice; the second reply reports the probe)
        begin : probe
            reg [7:0] pr [0:28]; integer n, pass;
            for (pass = 0; pass < 2; pass = pass + 1) begin
                send("R"); send(8'd5); send(8'd0); send(8'd3); send(8'd0);
                for (n = 0; n < 29; n = n + 1) recv(pr[n]);
                if (pass == 0) wait_frames(2);
            end
            $display("  R 5,3 -> %c%c %c%c%c%c%c%c%c%c %c%c%c%c%c%c%c%c %c%c%c%c%c%c%c%c",
                pr[0], pr[1], pr[2], pr[3], pr[4], pr[5], pr[6], pr[7], pr[8], pr[9],
                pr[11], pr[12], pr[13], pr[14], pr[15], pr[16], pr[17], pr[18],
                pr[20], pr[21], pr[22], pr[23], pr[24], pr[25], pr[26], pr[27]);
            $display("  R raw: %h %h %h %h %h %h %h %h %h", pr[19],pr[20],pr[21],pr[22],pr[23],pr[24],pr[25],pr[26],pr[27]);
            $display("  R pend_beats=%0d acc=%0d beat=%0d", dut.pend_beats, dut.acc_cnt, dut.beat_cnt);
            // taken + valid + running, RGB A0B0C0; 64x16 = 0x400 pixels per frame
            if ({pr[2],pr[3],pr[4],pr[5],pr[6],pr[7],pr[8],pr[9]} != "E0A0B0C0" ||
                {pr[11],pr[12],pr[13],pr[14],pr[15],pr[16],pr[17],pr[18]} != "00000400" ||
                {pr[20],pr[21],pr[22],pr[23],pr[24],pr[25],pr[26],pr[27]} != "00000000" || pr[28] !== 8'h0A) begin
                $display("ERROR: probe reply"); errors = errors + 1;
            end
        end

        $display("frames=%0d bad_frames=%0d hsync periods=%0d bad=%0d", frames, bad_frames, hs_per, hs_bad);
        if (bad_frames != 0 || hs_bad != 0) errors = errors + 1;
        if (errors == 0) $display("TB_PASS"); else $display("TB_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #200_000_000; $display("TB_FAIL timeout"); $finish; end
endmodule
