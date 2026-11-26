// Icarus testbench for rc_ddr_test (UART FSM + fake dcache + cs150
// RequestController + rc_axi_adapter). Reuses ../03_axi_ddr_test/sim/
// axi4_slave_mem.v (random backpressure) by relative reference.
//
// Override with iverilog -P: LINES (32-byte lines), WIN_AW (window bits),
// MEM_AW (slave memory address bits), BASE.
`timescale 1ns / 1ps

module tb_rc_ddr_test;

    parameter LINES  = 512;
    parameter WIN_AW = 14;
    parameter MEM_AW = 16;
    parameter [31:0] BASE  = 32'h1684_9F20;   // 32 B aligned, not 4 KB aligned
    parameter [31:0] BASE2 = 32'h1684_0013;   // [4:0] must be masked off
    localparam LEN = LINES * 32;

    localparam CLK_NS = 10;                    // 100 MHz
    localparam BIT_NS = 8681;                  // 115200 baud

    reg clk, rst;
    reg uart_to_dut;
    wire uart_from_dut;
    reg hold_arready;
    integer errors;

    wire [0:0]  awid, bid, arid, rid;
    wire [31:0] awaddr, araddr;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire        arvalid, arready, rvalid, rready, rlast;
    wire [63:0] wdata, rdata;
    wire [7:0]  wstrb;
    wire        rx_toggle, last_pass, busy;

    rc_ddr_test #(
        .CLK_FREQ(100_000_000), .BAUD(115200), .LINES(LINES), .WIN_AW(WIN_AW)
    ) dut (
        .clk(clk), .rst(rst), .rxd(uart_to_dut), .txd(uart_from_dut),
        .rx_toggle(rx_toggle), .last_pass(last_pass), .busy(busy),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(),
        .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(), .m_axi_awregion(),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(),
        .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(), .m_axi_arregion(),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    axi4_slave_mem #(.MEM_AW(MEM_AW), .STALL(1)) u_mem (
        .clk(clk), .rst(rst), .hold_arready(hold_arready),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    initial clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    // ---------------- AXI protocol monitor ----------------
    reg [7:0]  aw_q [0:255];
    reg [7:0]  ar_q [0:255];
    integer aw_wr, aw_rd, ar_wr, ar_rd, w_cnt, r_cnt;
    integer aw_total_beats, w_total_beats, ar_total_beats, r_total_beats;
    integer max_aw_out, b_cnt, aw_cnt;

    always @(posedge clk) begin
        if (rst) begin
            aw_wr = 0; aw_rd = 0; ar_wr = 0; ar_rd = 0; w_cnt = 0; r_cnt = 0;
            aw_total_beats = 0; w_total_beats = 0;
            ar_total_beats = 0; r_total_beats = 0;
            max_aw_out = 0; b_cnt = 0; aw_cnt = 0;
        end else begin
            if (awvalid && awready) begin
                if (awsize != 3'd3 || awburst != 2'b01) begin
                    $display("ERROR: AW size/burst %0d/%0d", awsize, awburst); errors = errors + 1;
                end
                if (awaddr[2:0] != 3'd0) begin
                    $display("ERROR: AW unaligned 0x%08x", awaddr); errors = errors + 1;
                end
                if (awlen != 8'd3 || awaddr[4:0] != 5'd0) begin
                    $display("ERROR: AW 0x%08x len %0d not one 32 B block", awaddr, awlen + 1); errors = errors + 1;
                end
                if (awaddr < (dut.base_addr) || awaddr >= dut.base_addr + (1 << WIN_AW)) begin
                    $display("ERROR: AW 0x%08x outside window", awaddr); errors = errors + 1;
                end
                if ({1'b0, awaddr[11:0]} + (awlen + 1) * 8 > 4096) begin
                    $display("ERROR: AW 0x%08x len %0d crosses 4 KB", awaddr, awlen + 1); errors = errors + 1;
                end
                aw_q[aw_wr % 256] = awlen; aw_wr = aw_wr + 1;
                aw_total_beats = aw_total_beats + awlen + 1;
                aw_cnt = aw_cnt + 1;
            end
            if (bvalid && bready) b_cnt = b_cnt + 1;
            if (aw_cnt - b_cnt > max_aw_out) max_aw_out = aw_cnt - b_cnt;
            if (wvalid && wready) begin
                w_cnt = w_cnt + 1;
                if (wstrb != 8'hFF) begin
                    $display("ERROR: WSTRB 0x%02x on a full-line write", wstrb); errors = errors + 1;
                end
                w_total_beats = w_total_beats + 1;
                if (aw_rd >= aw_wr) begin
                    // W ahead of an accepted AW is legal; check at WLAST
                end
                if (wlast) begin
                    if (w_cnt != aw_q[aw_rd % 256] + 1) begin
                        $display("ERROR: WLAST after %0d beats, AWLEN+1=%0d", w_cnt, aw_q[aw_rd % 256] + 1);
                        errors = errors + 1;
                    end
                    aw_rd = aw_rd + 1; w_cnt = 0;
                end else if (w_cnt > 256) begin
                    $display("ERROR: W burst > 256 beats without WLAST"); errors = errors + 1;
                end
            end
            if (arvalid && arready) begin
                if (arlen != 8'd3 || araddr[4:0] != 5'd0 ||
                    araddr < dut.base_addr || araddr >= dut.base_addr + (1 << WIN_AW)) begin
                    $display("ERROR: AR 0x%08x len %0d bad", araddr, arlen + 1); errors = errors + 1;
                end
                if ({1'b0, araddr[11:0]} + (arlen + 1) * 8 > 4096) begin
                    $display("ERROR: AR 0x%08x len %0d crosses 4 KB", araddr, arlen + 1); errors = errors + 1;
                end
                ar_q[ar_wr % 256] = arlen; ar_wr = ar_wr + 1;
                ar_total_beats = ar_total_beats + arlen + 1;
            end
            // MIG-style read pulses have no backpressure: the waiting client
            // must already be in READ1/READ2 (rdf_rden high) when one arrives.
            if (dut.rcon_rdf_wren && !(dut.data_rdf_wren && dut.data_rdf_rden)) begin
                $display("ERROR: rd_data_valid pulse not taken by the dcache"); errors = errors + 1;
            end
            if (rvalid && rready) begin
                r_cnt = r_cnt + 1;
                r_total_beats = r_total_beats + 1;
                if (rlast) begin
                    if (r_cnt != ar_q[ar_rd % 256] + 1) begin
                        $display("ERROR: RLAST after %0d beats, ARLEN+1=%0d", r_cnt, ar_q[ar_rd % 256] + 1);
                        errors = errors + 1;
                    end
                    ar_rd = ar_rd + 1; r_cnt = 0;
                end
            end
        end
    end

    // ---------------- UART host model ----------------
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            uart_to_dut = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_to_dut = b[i];
                #(BIT_NS);
            end
            uart_to_dut = 1'b1;
            #(BIT_NS);
        end
    endtask

    task recv_byte;
        output [7:0] b;
        integer i;
        integer guard;
        begin
            guard = 0;
            b = 8'h00;
            while (uart_from_dut !== 1'b0 && guard <= 20_000_000) begin
                #100;
                guard = guard + 1;
            end
            if (guard > 20_000_000) begin
                $display("ERROR: timeout waiting for DUT start bit");
                errors = errors + 1;
            end else begin
                #(BIT_NS / 2);
                #(BIT_NS);
                for (i = 0; i < 8; i = i + 1) begin
                    b[i] = uart_from_dut;
                    #(BIT_NS);
                end
                if (uart_from_dut !== 1'b1) begin
                    $display("ERROR: stop bit was not high"); errors = errors + 1;
                end
            end
        end
    endtask

    task cmd;
        input [7:0] c;
        input [7:0] expect;
        input [8*24-1:0] what;
        reg [7:0] r;
        begin
            send_byte(c);
            recv_byte(r);
            if (r !== expect) begin
                $display("ERROR: %0s: sent '%c' got '%c' (0x%02x), expected '%c'", what, c, r, r, expect);
                errors = errors + 1;
            end else begin
                $display("  %0s: '%c' -> '%c'  @%0d us", what, c, r, $time / 1000);
            end
        end
    endtask

    task set_addr;
        input [31:0] a;
        reg [7:0] r;
        begin
            send_byte("A");
            send_byte(a[7:0]); send_byte(a[15:8]); send_byte(a[23:16]); send_byte(a[31:24]);
            recv_byte(r);
            if (r !== "K") begin
                $display("ERROR: 'A' 0x%08x reply '%c'", a, r); errors = errors + 1;
            end else
                $display("  set base 0x%08x -> 'K' (DUT base 0x%08x)", a, dut.base_addr);
        end
    endtask

    reg [8*44-1:0] tline;

    // Parse n hex digits starting at character position pos of tline.
    function [31:0] hexfield;
        input integer pos;
        input integer n;
        integer q;
        reg [7:0] ch;
        begin
            hexfield = 0;
            for (q = 0; q < n; q = q + 1) begin
                ch = tline[8*(44-pos-q)-1 -: 8];
                hexfield = (hexfield << 4) |
                    ((ch >= "A") ? (ch - "A" + 10) : (ch - "0"));
            end
        end
    endfunction
    task stats;
        output [31:0] wc, rc, mm, fb;
        output [7:0]  sd;
        integer n;
        reg [7:0] b;
        begin
            send_byte("T");
            tline = 0;
            for (n = 0; n < 44; n = n + 1) begin
                recv_byte(b);
                tline = (tline << 8) | b;
            end
            $display("  T -> %0s", tline[8*44-1:8]);
            // values come from the ASCII line, cross-checked with the DUT
            wc = hexfield(1, 8); rc = hexfield(11, 8); mm = hexfield(21, 8);
            fb = hexfield(31, 8); sd = hexfield(41, 2);
            if (tline[8*44-1 -: 8] !== "W" || tline[7:0] !== 8'h0A ||
                wc !== dut.wcyc || rc !== dut.rcyc || mm !== dut.t_mism ||
                fb !== dut.t_first || sd !== dut.seed) begin
                $display("ERROR: stats line does not match DUT registers"); errors = errors + 1;
            end
        end
    endtask

    // Line pattern, identical to dcache_tester.line_pat.
    function [255:0] line_pat;
        input [31:0] i;
        input [7:0]  sd;
        integer k;
        reg [31:0] v;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                v = {i[28:0], k[2:0]} ^ {4{sd}};
                line_pat[32*k +: 32] = k[0] ? ~v : v;
            end
        end
    endfunction

    // Expected DDR byte j (0..31) of line i. The dcache sends line[255:128]
    // first (Cache.v WRITE1) and rc_axi_adapter puts the first 128-bit beat at
    // the lower 16 bytes, so DDR bytes 0..15 = line[255:128] (words 4..7),
    // bytes 16..31 = line[127:0] (words 0..3), each little-endian.
    function [7:0] ddr_byte;
        input [31:0] i;
        input [7:0]  sd;
        input integer j;
        reg [255:0] l;
        begin
            l = line_pat(i, sd);
            ddr_byte = (j < 16) ? l[128 + 8*j +: 8] : l[8*(j-16) +: 8];
        end
    endfunction

    task check_mem;
        input [31:0] base;
        input [7:0]  sd;
        integer i, j, bad;
        reg [31:0] a;
        begin
            bad = 0;
            for (i = 0; i < LINES; i = i + 1) begin
                for (j = 0; j < 32; j = j + 1) begin
                    a = base + i * 32 + j;
                    if (u_mem.mem[a[MEM_AW-1:0]] !== ddr_byte(i, sd, j)) begin
                        if (bad < 4)
                            $display("ERROR: mem[0x%08x]=0x%02x exp 0x%02x", a, u_mem.mem[a[MEM_AW-1:0]], ddr_byte(i, sd, j));
                        bad = bad + 1;
                    end
                end
            end
            for (j = 1; j <= 8; j = j + 1) begin
                a = base - j;
                if (u_mem.mem[a[MEM_AW-1:0]] !== 8'hCC) bad = bad + 1;
                a = base + LEN - 1 + j;
                if (u_mem.mem[a[MEM_AW-1:0]] !== 8'hCC) bad = bad + 1;
            end
            if (bad != 0) begin
                $display("ERROR: memory check base 0x%08x seed %0d: %0d bad bytes", base, sd, bad);
                errors = errors + 1;
            end else
                $display("  memory check: %0d lines at 0x%08x match seed %0d (DDR layout), guard bytes 0xCC intact", LINES, base, sd);
        end
    endtask

    reg [31:0] wc, rc, mm, fb, mbase;
    reg [7:0]  sd;
    integer t0;

    initial begin
        errors = 0;
        uart_to_dut = 1'b1;
        hold_arready = 1'b0;
        rst = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);

        $display("tb_rc_ddr_test: LINES=%0d (%0d bytes), WIN_AW=%0d, MEM_AW=%0d, BASE=0x%08x", LINES, LEN, WIN_AW, MEM_AW, BASE);

        $display("[1] W/R/G before an address is set are refused");
        cmd("W", "N", "W without A");
        cmd("G", "N", "G without A");
        cmd("R", "N", "R without A");
        if (aw_cnt != 0 || ar_wr != 0) begin
            $display("ERROR: AXI traffic before address set"); errors = errors + 1;
        end
        cmd("x", "?", "unknown char");

        $display("[2] write all lines through the dcache port, read back PASS");
        set_addr(BASE);
        cmd("W", "D", "write seed 1");
        check_mem(BASE, 8'd1);
        if (aw_cnt != LINES || w_total_beats != LINES * 4) begin
            $display("ERROR: write bursts %0d beats %0d, exp %0d / %0d", aw_cnt, w_total_beats, LINES, LINES * 4);
            errors = errors + 1;
        end
        cmd("R", "P", "read seed 1");
        if (ar_wr != LINES || r_total_beats != LINES * 4) begin
            $display("ERROR: read bursts %0d beats %0d, exp %0d / %0d", ar_wr, r_total_beats, LINES, LINES * 4);
            errors = errors + 1;
        end
        if (!last_pass) begin $display("ERROR: last_pass low after P"); errors = errors + 1; end
        stats(wc, rc, mm, fb, sd);
        $display("  write %0d cycles (%0d per line), read %0d cycles (%0d per line)",
                 wc, wc / LINES, rc, rc / LINES);
        if (mm != 0 || sd != 1) begin $display("ERROR: stats mm=%0d seed=%0d", mm, sd); errors = errors + 1; end

        $display("[3] corrupt memory under two lines, read must FAIL");
        mbase = BASE + 100 * 32 + 5;                 // line 100, byte 5
        u_mem.mem[mbase[MEM_AW-1:0]] = u_mem.mem[mbase[MEM_AW-1:0]] ^ 8'h10;
        mbase = BASE + (LINES - 1) * 32 + 31;        // last line, last byte
        u_mem.mem[mbase[MEM_AW-1:0]] = ~u_mem.mem[mbase[MEM_AW-1:0]];
        cmd("R", "F", "read corrupted");
        if (last_pass) begin $display("ERROR: last_pass high after F"); errors = errors + 1; end
        stats(wc, rc, mm, fb, sd);
        if (mm != 2 || fb != 100) begin
            $display("ERROR: expected 2 bad lines first 100, got %0d first %0d", mm, fb);
            errors = errors + 1;
        end else
            $display("  bad lines=%0d first bad line=%0d as injected", mm, fb);

        $display("[4] 'G' (write seed 2 then read) in one character repairs it");
        cmd("G", "P", "G seed 2");
        check_mem(BASE, 8'd2);

        $display("[5] base with [4:0] set is masked; G PASS");
        for (t0 = 0; t0 < (1 << MEM_AW); t0 = t0 + 1)
            u_mem.mem[t0] = 8'hCC;
        set_addr(BASE2);
        if (dut.base_addr !== (BASE2 & 32'hFFFF_FFE0)) begin
            $display("ERROR: base not masked: 0x%08x", dut.base_addr); errors = errors + 1;
        end
        cmd("G", "P", "G seed 3");
        check_mem(BASE2 & 32'hFFFF_FFE0, 8'd3);

        $display("[6] RequestController read bookkeeping and adapter back to idle, no protocol errors");
        if (dut.req_con.data_req_valid !== 2'b00 || dut.u_adapter.st !== 3'd0 || dut.u_adapter.bad_cmd) begin
            $display("ERROR: RC data_req_valid=%b adapter state=%0d", dut.req_con.data_req_valid, dut.u_adapter.st);
            errors = errors + 1;
        end

        repeat (100) @(posedge clk);
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("ERROR: global timeout");
        $finish;
    end

endmodule
