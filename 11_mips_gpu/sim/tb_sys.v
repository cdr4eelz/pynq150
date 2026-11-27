`timescale 1ns/1ps
// tb_sys (11_mips_gpu, make simsys): the whole sys_core boots the gios BIOS from the bios_mem ROM
// image and talks to it over the UART. CPU_FREQ = 16*115200 so a UART bit is 16 clk (the clock is
// still 50 MHz). DDR = axi4_slave_pipe on a folded address {a[27], a[22:0]} (16 MiB) so the stack
// at 0x1F000000, data at 0x10xxxxxx and frame 1 at 0x10400000 do not collide.
// Pass: banner "[Golt45.3", prompt "> ", then each command's reply contains the expected text.
module tb_sys;
    localparam BIT = 16;                   // clk per UART bit
    reg clk = 0, axi_clk = 0, pix_clk = 0;
    always #10   clk = ~clk;               // 50 MHz
    always #5    axi_clk = ~axi_clk;       // 100 MHz
    always #12.5 pix_clk = ~pix_clk;       // 40 MHz
    reg rst = 1, axi_rst = 1, pix_rst = 1;
    reg rxd = 1;
    wire txd;

    wire [0:0] m_awid;
    wire [31:0] m_awaddr;
    wire [7:0] m_awlen;
    wire [2:0] m_awsize;
    wire [1:0] m_awburst;
    wire [0:0] m_awlock;
    wire [3:0] m_awcache;
    wire [2:0] m_awprot;
    wire [3:0] m_awqos;
    wire [0:0] m_awvalid;
    wire [0:0] m_awready;
    wire [63:0] m_wdata;
    wire [7:0] m_wstrb;
    wire [0:0] m_wlast;
    wire [0:0] m_wvalid;
    wire [0:0] m_wready;
    wire [0:0] m_bid;
    wire [1:0] m_bresp;
    wire [0:0] m_bvalid;
    wire [0:0] m_bready;
    wire [0:0] m_arid;
    wire [31:0] m_araddr;
    wire [7:0] m_arlen;
    wire [2:0] m_arsize;
    wire [1:0] m_arburst;
    wire [0:0] m_arlock;
    wire [3:0] m_arcache;
    wire [2:0] m_arprot;
    wire [3:0] m_arqos;
    wire [0:0] m_arvalid;
    wire [0:0] m_arready;
    wire [0:0] m_rid;
    wire [63:0] m_rdata;
    wire [1:0] m_rresp;
    wire [0:0] m_rlast;
    wire [0:0] m_rvalid;
    wire [0:0] m_rready;
    assign m_bid = 1'b0;
    assign m_rid = 1'b0;
    // fold 0x1xxxxxxx into 16 MiB: {a[27], a[22:0]}
    wire [31:0] f_awaddr = {8'd0, m_awaddr[27], m_awaddr[22:0]};
    wire [31:0] f_araddr = {8'd0, m_araddr[27], m_araddr[22:0]};

    sys_core #(.CPU_FREQ(16*115200)) dut (
        .clk(clk), .rst_in(rst), .axi_clk(axi_clk), .axi_rst(axi_rst),
        .pix_clk(pix_clk), .pix_rst(pix_rst), .pix_locked(1'b1),
        .rxd(rxd), .txd(txd), .rx_toggle(), .pf_running(), .uf_sticky(), .cpu_running(),
        .vid_r(), .vid_g(), .vid_b(), .vid_de(), .vid_hs(), .vid_vs(), .frame_tick(),
        .m_axi_awregion(), .m_axi_arregion(),
        .m_axi_awid(m_awid),
        .m_axi_awaddr(m_awaddr),
        .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst),
        .m_axi_awlock(m_awlock),
        .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot),
        .m_axi_awqos(m_awqos),
        .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata),
        .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid),
        .m_axi_wready(m_wready),
        .m_axi_bid(m_bid),
        .m_axi_bresp(m_bresp),
        .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .m_axi_arid(m_arid),
        .m_axi_araddr(m_araddr),
        .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst),
        .m_axi_arlock(m_arlock),
        .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot),
        .m_axi_arqos(m_arqos),
        .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),
        .m_axi_rid(m_rid),
        .m_axi_rdata(m_rdata),
        .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid),
        .m_axi_rready(m_rready)
    );

    axi4_slave_pipe #(.MEM_AW(24), .RLAT(20), .BLAT(15)) ddr (
        .clk(axi_clk), .rst(axi_rst),
        .s_axi_awaddr(f_awaddr), .s_axi_araddr(f_araddr),
        .s_axi_awlen(m_awlen),
        .s_axi_awsize(m_awsize),
        .s_axi_awvalid(m_awvalid),
        .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata),
        .s_axi_wstrb(m_wstrb),
        .s_axi_wlast(m_wlast),
        .s_axi_wvalid(m_wvalid),
        .s_axi_wready(m_wready),
        .s_axi_bresp(m_bresp),
        .s_axi_bvalid(m_bvalid),
        .s_axi_bready(m_bready),
        .s_axi_arlen(m_arlen),
        .s_axi_arsize(m_arsize),
        .s_axi_arvalid(m_arvalid),
        .s_axi_arready(m_arready),
        .s_axi_rdata(m_rdata),
        .s_axi_rresp(m_rresp),
        .s_axi_rlast(m_rlast),
        .s_axi_rvalid(m_rvalid),
        .s_axi_rready(m_rready)
    );


    // monitor: every PixelFeeder resync, underflow event and sink lock change
    always @(posedge clk) begin
        if (dut.resync)   $display("[%0t] MON resync (count %0d)", $time, dut.u_pf.resyncs);
        if (dut.uf_event) $display("[%0t] MON underflow event (pf_rst=%b)", $time, dut.u_pf.pf_rst);
    end
    always @(dut.pf_running) $display("[%0t] MON sink running=%b", $time, dut.pf_running);
    always @(posedge dut.frame_tick) if (dut.u_pf.pf_rst == 0) $display("[%0t] MON frame_tick pf_status=%h", $time, dut.u_pf.pf_status);

    // ---------------- UART receive (from the CPU) ----------------
    reg [8*128-1:0] tail = 0;              // last 128 characters received
    integer nrx = 0;
    reg [7:0] ch;
    integer b;
    initial forever begin
        @(negedge txd);
        repeat (BIT/2) @(posedge clk);
        for (b = 0; b < 8; b = b + 1) begin repeat (BIT) @(posedge clk); ch[b] = txd; end
        repeat (BIT) @(posedge clk);
        tail = {tail[8*127-1:0], ch};
        nrx = nrx + 1;
        if (ch == 8'h0d) ; else $write("%c", ch);
    end
    function has(input [8*128-1:0] t, input [8*16-1:0] pat, input integer n);  // pat = last n chars
        integer i, j; reg ok;
        begin
            has = 0;
            for (i = 0; i + n <= 128; i = i + 1) begin
                ok = 1;
                for (j = 0; j < n; j = j + 1)
                    if (t[8*(i+j) +: 8] != pat[8*j +: 8]) ok = 0;
                if (ok) has = 1;
            end
        end
    endfunction

    // ---------------- UART send (to the CPU) ----------------
    task send_byte(input [7:0] c);
        integer k;
        begin
            rxd = 0; repeat (BIT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin rxd = c[k]; repeat (BIT) @(posedge clk); end
            rxd = 1; repeat (2*BIT) @(posedge clk);
        end
    endtask
    task send_str(input [8*48-1:0] s);
        integer k;
        begin
            for (k = 47; k >= 0; k = k - 1) if (s[8*k +: 8] != 0) send_byte(s[8*k +: 8]);
            send_byte(8'h0d);
        end
    endtask
    integer fails = 0;
    reg [7:0]  rs_n;
    reg [15:0] rs_hex;
    function [7:0] hexc(input [3:0] v); hexc = (v < 10) ? ("0" + v) : ("a" + v - 10); endfunction
    task wait_prompt(input integer max_clk);
        integer c;
        begin
            c = 0; tail = 0;
            while (!has(tail, "> ", 2) && c < max_clk) begin @(posedge clk); c = c + 1; end
            if (c >= max_clk) begin $display("\nTB_FAIL: no prompt after %0d clk", max_clk); fails = fails + 1; end
        end
    endtask
    // run a command and check the reply (before the next prompt) contains want (n chars, 0 = no check)
    reg [8*128-1:0] reply;
    task cmd(input [8*48-1:0] s, input [8*16-1:0] want, input integer n, input integer max_clk);
        integer c;
        begin
            tail = 0;
            send_str(s);
            c = 0;
            while (!has(tail, "> ", 2) && c < max_clk) begin @(posedge clk); c = c + 1; end
            reply = tail;
            if (c >= max_clk) begin $display("\nTB_FAIL: '%0s' no prompt", s); fails = fails + 1; end
            else if (n > 0 && !has(reply, want, n)) begin
                $display("\nTB_FAIL: '%0s' reply lacks '%0s'", s, want); fails = fails + 1;
            end
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin $dumpfile("sim/sys.vcd"); $dumpvars(0, tb_sys); end
        repeat (20) @(posedge axi_clk); axi_rst = 0;
        repeat (10) @(posedge clk); rst = 0; pix_rst = 0;
        wait (dut.cpu_running);
        $display("[%0t] cpu out of reset", $time);
        wait_prompt(400_000);
        if (!fails && !has(tail, "> ", 2)) fails = fails + 1;
        $display("\n[%0t] prompt seen (%0d chars)", $time, nrx);
        cmd("help",                 "", 0, 400_000);
        cmd("sw c0ffee14 10001014", "", 0, 100_000);
        cmd("lw 10001014",          "c0ffee14", 8, 100_000);
        cmd("sw 18181818 18000040", "", 0, 100_000);
        cmd("sw 10101010 10000040", "", 0, 100_000);
        cmd("lw 18000040",          "18181818", 8, 100_000);
        cmd("lw 10000040",          "10101010", 8, 100_000);
        cmd("sw 11223344 10001100", "", 0, 100_000);
        cmd("sb aa 10001101",       "", 0, 100_000);
        cmd("lw 10001100",          "11aa3344", 8, 100_000);   // big-endian: byte 1 = [23:16]
        cmd("lw 40000000",          "", 0, 100_000);
        cmd("gs",                   "", 0, 100_000);
        if (!$test$plusargs("nogpu")) begin
            cmd("gf 1",             "", 0, 100_000);
            cmd("hwcolor 00ff8040", "", 0, 100_000);
            cmd("hwline 0 4 40 4",  "", 0, 400_000);
            repeat (20000) @(posedge clk);
            cmd("gs",               "", 0, 100_000);
            cmd("lw 10404028",      "ff8040", 6, 100_000);   // frame 1 (0x10400000, 1024 px stride), x=10 y=4
            cmd("lw 10400000",      "", 0, 100_000);
        end
        // PF_FRAME must survive an underflow resync (the wrapper replays the CPU's last write).
        // Forcing the resync reg holds it for 2 clocks (a released reg keeps the forced value
        // until its next assignment), so the expected count is whatever the wrapper counted; gs
        // must show it (bits [23:16]) and it must not grow over 2 more frames (no follow-on
        // underflow), with uf_sticky still clear.
        cmd("pf 1",                 "", 0, 100_000);
        @(posedge dut.frame_tick);                 // PF#xx = frame being fed, updates per frame
        @(negedge clk); force dut.resync = 1'b1; @(negedge clk); release dut.resync;
        repeat (2) @(posedge dut.frame_tick);
        rs_n = dut.u_pf.resyncs;
        cmd("gs",                   "PF#01", 5, 100_000);
        rs_hex = {hexc(rs_n[7:4]), hexc(rs_n[3:0])};
        if (rs_n == 0 || !has(reply, {rs_hex, "011f"}, 6)) begin   // status word = {fault,dormant,frame6, count8, gp_status16}
            $display("\nTB_FAIL: resync count %0d not shown in gs", rs_n); fails = fails + 1;
        end
        repeat (2) @(posedge dut.frame_tick);
        cmd("gs",                   "PF#01", 5, 100_000);
        if (dut.u_pf.resyncs != rs_n || dut.uf_sticky) begin
            $display("\nTB_FAIL: follow-on resync/underflow (count %0d -> %0d, uf_sticky=%b)",
                     rs_n, dut.u_pf.resyncs, dut.uf_sticky); fails = fails + 1;
        end else $display("\n[%0t] PF_FRAME kept across resync (count %0d, no follow-on underflow)", $time, rs_n);
        cmd("pf 0",                 "", 0, 100_000);
        if ($test$plusargs("pf")) begin
            // PixelFeeder shows frame 1 for two frames; no underflow, no '*' (pf_fault) in gs
            cmd("pf 1",             "", 0, 100_000);
            repeat (2) @(posedge dut.frame_tick);
            repeat (2) @(posedge dut.frame_tick);
            cmd("gs",               "", 0, 100_000);
            if (has(reply, "*", 1) || dut.uf_sticky) begin
                $display("\nTB_FAIL: PixelFeeder fault/underflow (uf_sticky=%b)", dut.uf_sticky); fails = fails + 1;
            end else $display("\n[%0t] PixelFeeder ran 3+ frames of frame 1 without underflow", $time);
        end
        if (dut.u_adapter.axi_err || dut.u_adapter.bad_cmd) begin
            $display("TB_FAIL: adapter axi_err=%b bad_cmd=%b", dut.u_adapter.axi_err, dut.u_adapter.bad_cmd);
            fails = fails + 1;
        end
        if (fails == 0) $display("\nTB_PASS sys: gios booted to prompt, commands OK (%0d chars rx)", nrx);
        else            $display("\nTB_FAIL sys: %0d failures", fails);
        $finish;
    end
    initial begin #400_000_000; $display("\nTB_FAIL: global timeout"); $finish; end
endmodule
