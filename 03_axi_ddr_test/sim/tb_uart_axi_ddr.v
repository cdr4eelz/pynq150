`timescale 1ns / 1ps

// Host-side bit-banged UART + AXI4 slave memory talking to uart_axi_ddr_test.
// The DUT runs at 10 MHz so the test finishes quickly; the baud is still
// 115200 8N1 (same rate-error approach as tb_uart_echo.v).
//
// Tests:
//   1. PASS: send a 4-byte LE address and 256-byte pattern, check the
//      slave memory, and check the UART report is "PASS 0x000 0x00\n".
//      No TX may start before the last of the 260 host bytes is sent.
//   2. 4 KB-crossing address (split bursts), also PASS.
//   3. FAIL: hold ARREADY, wait until the write lands, corrupt one byte
//      in the slave memory, release ARREADY, check "FAIL 0x001 0x<idx>\n".
module tb_uart_axi_ddr;

    localparam CLK_FREQ = 10_000_000;
    localparam BAUD     = 115200;
    localparam CLK_NS   = 100;
    localparam BIT_NS   = CLK_NS * (CLK_FREQ / BAUD); // DUT bit period (8600 ns at 10 MHz)

    localparam [31:0] ADDR_PASS  = 32'h16849000; // 4 KB aligned
    localparam [31:0] ADDR_CROSS = 32'h00000F08; // crosses 4 KB
    localparam [31:0] ADDR_FAIL  = 32'h1684A000;
    localparam integer CORRUPT_I = 42;

    reg        clk;
    reg        rst;
    reg        uart_to_dut;
    wire       uart_from_dut;
    wire       rx_toggle;
    wire       last_pass;
    wire       rx_phase;
    reg        hold_arready;

    integer    errors;
    integer    early_tx;
    integer    sending;

    // AXI wires
    wire [0:0]  awid, arid, bid, rid;
    wire [31:0] awaddr, araddr;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst;
    wire        awlock, arlock;
    wire [3:0]  awcache, arcache, awqos, arqos, awregion, arregion;
    wire [2:0]  awprot, arprot;
    wire        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire        arvalid, arready, rvalid, rready, rlast;
    wire [63:0] wdata, rdata;
    wire [7:0]  wstrb;
    wire [1:0]  bresp, rresp;

    uart_axi_ddr_test #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .rxd            (uart_to_dut),
        .txd            (uart_from_dut),
        .rx_toggle      (rx_toggle),
        .last_pass      (last_pass),
        .rx_phase       (rx_phase),
        .m_axi_awid     (awid),
        .m_axi_awaddr   (awaddr),
        .m_axi_awlen    (awlen),
        .m_axi_awsize   (awsize),
        .m_axi_awburst  (awburst),
        .m_axi_awlock   (awlock),
        .m_axi_awcache  (awcache),
        .m_axi_awprot   (awprot),
        .m_axi_awqos    (awqos),
        .m_axi_awregion (awregion),
        .m_axi_awvalid  (awvalid),
        .m_axi_awready  (awready),
        .m_axi_wdata    (wdata),
        .m_axi_wstrb    (wstrb),
        .m_axi_wlast    (wlast),
        .m_axi_wvalid   (wvalid),
        .m_axi_wready   (wready),
        .m_axi_bid      (bid),
        .m_axi_bresp    (bresp),
        .m_axi_bvalid   (bvalid),
        .m_axi_bready   (bready),
        .m_axi_arid     (arid),
        .m_axi_araddr   (araddr),
        .m_axi_arlen    (arlen),
        .m_axi_arsize   (arsize),
        .m_axi_arburst  (arburst),
        .m_axi_arlock   (arlock),
        .m_axi_arcache  (arcache),
        .m_axi_arprot   (arprot),
        .m_axi_arqos    (arqos),
        .m_axi_arregion (arregion),
        .m_axi_arvalid  (arvalid),
        .m_axi_arready  (arready),
        .m_axi_rid      (rid),
        .m_axi_rdata    (rdata),
        .m_axi_rresp    (rresp),
        .m_axi_rlast    (rlast),
        .m_axi_rvalid   (rvalid),
        .m_axi_rready   (rready)
    );

    axi4_slave_mem u_mem (
        .clk            (clk),
        .rst            (rst),
        .hold_arready   (hold_arready),
        .s_axi_awid     (awid),
        .s_axi_awaddr   (awaddr),
        .s_axi_awlen    (awlen),
        .s_axi_awsize   (awsize),
        .s_axi_awburst  (awburst),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (wstrb),
        .s_axi_wlast    (wlast),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bid      (bid),
        .s_axi_bresp    (bresp),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_arid     (arid),
        .s_axi_araddr   (araddr),
        .s_axi_arlen    (arlen),
        .s_axi_arsize   (arsize),
        .s_axi_arburst  (arburst),
        .s_axi_arvalid  (arvalid),
        .s_axi_arready  (arready),
        .s_axi_rid      (rid),
        .s_axi_rdata    (rdata),
        .s_axi_rresp    (rresp),
        .s_axi_rlast    (rlast),
        .s_axi_rvalid   (rvalid),
        .s_axi_rready   (rready)
    );

    initial clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    function [7:0] pat;
        input integer idx;
        input integer salt;
        begin
            pat = (idx * 7 + 3 + salt) & 8'hff;
        end
    endfunction

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
            while (uart_from_dut !== 1'b0) begin
                #100;
                guard = guard + 1;
                if (guard > 2_000_000) begin
                    $display("ERROR: timeout waiting for DUT start bit");
                    errors = errors + 1;
                    b = 8'hxx;
                    disable recv_byte;
                end
            end
            #(BIT_NS / 2);
            if (uart_from_dut !== 1'b0) begin
                $display("ERROR: start bit was not still low at midpoint");
                errors = errors + 1;
            end
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_from_dut;
                #(BIT_NS);
            end
            if (uart_from_dut !== 1'b1) begin
                $display("ERROR: stop bit was not high");
                errors = errors + 1;
            end
            // Return immediately; the next recv_byte waits for the falling
            // edge. Waiting another half-bit here can overshoot into the
            // next start bit when the host period is longer than the DUT's.
        end
    endtask

    task send_frame;
        input [31:0] addr;
        input integer salt;
        integer n;
        begin
            sending = 1;
            early_tx = 0;
            send_byte(addr[7:0]);
            send_byte(addr[15:8]);
            send_byte(addr[23:16]);
            send_byte(addr[31:24]);
            for (n = 0; n < 256; n = n + 1)
                send_byte(pat(n, salt));
            sending = 0;
        end
    endtask

    task recv_line;
        output [8*16-1:0] line; // 16 characters, [127:120] is first
        integer n;
        reg [7:0] b;
        begin
            line = {16{8'h00}};
            for (n = 0; n < 16; n = n + 1) begin
                recv_byte(b);
                line = (line << 8) | b;
            end
        end
    endtask

    task check_mem;
        input [31:0] addr;
        input integer salt;
        integer n;
        integer bad;
        reg [7:0] got, exp;
        integer before, after;
        begin
            bad = 0;
            before = addr[15:0] - 16'd1;
            after  = addr[15:0] + 16'd256;
            if (u_mem.mem[before] !== 8'hCC) begin
                $display("ERROR: byte before 0x%08x was overwritten (0x%02x)", addr, u_mem.mem[before]);
                errors = errors + 1;
            end
            if (u_mem.mem[after] !== 8'hCC) begin
                $display("ERROR: byte after 0x%08x+255 was overwritten (0x%02x)", addr, u_mem.mem[after]);
                errors = errors + 1;
            end
            for (n = 0; n < 256; n = n + 1) begin
                got = u_mem.mem[addr[15:0] + n[15:0]];
                exp = pat(n, salt);
                if (got !== exp) begin
                    if (bad < 4)
                        $display("ERROR: mem[0x%08x] = 0x%02x, expected 0x%02x", addr + n, got, exp);
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                $display("ERROR: %0d data byte(s) wrong at 0x%08x", bad, addr);
                errors = errors + 1;
            end else begin
                $display("PASS: 256 bytes present at 0x%08x", addr);
            end
        end
    endtask

    task expect_report;
        input [8*16-1:0] got;
        input            want_pass;
        input integer    want_mmm;
        input integer    want_ii;
        reg [8*16-1:0] exp;
        integer n;
        begin
            if (want_pass)
                exp = {"PASS 0x000 0x00\n"};
            else
                exp = {"FAIL 0x", hex3(want_mmm), " 0x", hex2(want_ii), "\n"};
            if (got !== exp) begin
                $display("ERROR: report mismatch");
                $write  ("  got: ");
                for (n = 15; n >= 0; n = n - 1)
                    $write("%s", got[n*8 +: 8]);
                $write("  exp: ");
                for (n = 15; n >= 0; n = n - 1)
                    $write("%s", exp[n*8 +: 8]);
                $write("\n");
                errors = errors + 1;
            end else if (want_pass) begin
                $display("PASS: UART report 'PASS 0x000 0x00'");
            end else begin
                $display("PASS: UART report 'FAIL 0x%03x 0x%02x'", want_mmm, want_ii);
            end
        end
    endtask

    function [23:0] hex3;
        input integer v;
        begin
            hex3[23:16] = nib(v[11:8]);
            hex3[15:8]  = nib(v[7:4]);
            hex3[7:0]   = nib(v[3:0]);
        end
    endfunction

    function [15:0] hex2;
        input integer v;
        begin
            hex2[15:8] = nib(v[7:4]);
            hex2[7:0]  = nib(v[3:0]);
        end
    endfunction

    function [7:0] nib;
        input [3:0] n;
        begin
            nib = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    task wait_mem_written;
        input [31:0] addr;
        input integer salt;
        integer guard;
        integer n;
        integer ok;
        begin
            guard = 0;
            ok = 0;
            while (!ok) begin
                @(posedge clk);
                ok = 1;
                for (n = 0; n < 256; n = n + 1) begin
                    if (u_mem.mem[addr[15:0] + n[15:0]] !== pat(n, salt))
                        ok = 0;
                end
                guard = guard + 1;
                if (guard > 100_000) begin
                    $display("ERROR: timeout waiting for write to land at 0x%08x", addr);
                    errors = errors + 1;
                    ok = 1; // break
                end
            end
        end
    endtask

    // Watch for TX starting while the host is still sending.

    always @(negedge uart_from_dut) begin
        if (sending && !rst)
            early_tx = early_tx + 1;
    end

    initial begin
        errors        = 0;
        early_tx      = 0;
        sending       = 0;
        hold_arready  = 1'b0;
        uart_to_dut   = 1'b1;
        rst           = 1'b1;
        repeat (20) @(posedge clk);
        rst           = 1'b0;
        repeat (20) @(posedge clk);

        $display("tb_uart_axi_ddr: 10 MHz clock, 115200 8N1, 64-bit AXI4 slave");

        // ---------- 1. Aligned PASS ----------
        begin : t_pass
            reg [8*16-1:0] line;
            send_frame(ADDR_PASS, 0);
            if (early_tx != 0) begin
                $display("ERROR: DUT TX started before all 260 RX bytes (PASS test)");
                errors = errors + 1;
            end else begin
                $display("PASS: no UART TX during the 260-byte host write (PASS test)");
            end
            recv_line(line);
            expect_report(line, 1, 0, 0);
            check_mem(ADDR_PASS, 0);
            if (last_pass !== 1'b1) begin
                $display("ERROR: last_pass was not set after PASS");
                errors = errors + 1;
            end
        end

        // ---------- 2. 4 KB-crossing PASS ----------
        begin : t_cross
            reg [8*16-1:0] line;
            early_tx = 0;
            send_frame(ADDR_CROSS, 11);
            if (early_tx != 0) begin
                $display("ERROR: DUT TX started before all 260 RX bytes (CROSS test)");
                errors = errors + 1;
            end
            recv_line(line);
            expect_report(line, 1, 0, 0);
            check_mem(ADDR_CROSS, 11);
        end

        // ---------- 3. FAIL: corrupt one byte between write and read ----------
        begin : t_fail
            reg [8*16-1:0] line;
            hold_arready = 1'b1;
            early_tx = 0;
            send_frame(ADDR_FAIL, 5);
            if (early_tx != 0) begin
                $display("ERROR: DUT TX started before all 260 RX bytes (FAIL test)");
                errors = errors + 1;
            end
            wait_mem_written(ADDR_FAIL, 5);
            check_mem(ADDR_FAIL, 5);
            u_mem.mem[ADDR_FAIL[15:0] + CORRUPT_I[15:0]] = 8'h5A;
            $display("INFO: corrupted byte %0d at 0x%08x to 0x5A (was 0x%02x)",
                     CORRUPT_I, ADDR_FAIL + CORRUPT_I, pat(CORRUPT_I, 5));
            hold_arready = 1'b0;
            recv_line(line);
            expect_report(line, 0, 1, CORRUPT_I);
            if (last_pass !== 1'b0) begin
                $display("ERROR: last_pass was not cleared after FAIL");
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("tb_uart_axi_ddr: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("tb_uart_axi_ddr: FAILED with %0d error(s)", errors);
            $fatal(1);
        end
    end

    initial begin
        #400_000_000; // 400 ms: three 260-byte UART frames plus reports
        $display("ERROR: simulation timed out");
        $fatal(1);
    end

endmodule
