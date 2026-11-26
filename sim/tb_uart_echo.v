`timescale 1ns / 1ps

// Host-side bit-banged UART talking to uart_echo. The DUT runs at 10 MHz
// so the test finishes quickly; the baud is still 115200 8N1. The host
// uses the ideal bit period (8680 ns) while the DUT uses integer
// CLK_FREQ/BAUD, which is a small but realistic rate error.
module tb_uart_echo;

    localparam CLK_FREQ = 10_000_000;
    localparam BAUD     = 115200;
    localparam CLK_NS   = 100;                 // 10 MHz
    localparam BIT_NS   = 1_000_000_000 / BAUD; // 8680 ns

    reg        clk;
    reg        rst;
    reg        uart_to_dut;
    wire       uart_from_dut;
    wire       rx_toggle;

    integer    errors;
    integer    saw_toggle;

    uart_echo #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .rxd      (uart_to_dut),
        .txd      (uart_from_dut),
        .rx_toggle(rx_toggle)
    );

    initial clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

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
                if (guard > 200000) begin
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
            #(BIT_NS / 2);
        end
    endtask

    task check_echo;
        input [7:0] sent;
        reg   [7:0] got;
        begin
            // DUT TX starts during the incoming stop bit; recv in parallel.
            fork
                send_byte(sent);
                recv_byte(got);
            join
            if (got !== sent) begin
                $display("ERROR: echoed 0x%02x, expected 0x%02x", got, sent);
                errors = errors + 1;
            end else begin
                $display("PASS: echoed 0x%02x (%c)", sent, (sent >= 8'h20 && sent <= 8'h7e) ? sent : 8'h2e);
            end
        end
    endtask

    initial begin
        errors      = 0;
        saw_toggle  = 0;
        uart_to_dut = 1'b1;
        rst         = 1'b1;
        repeat (20) @(posedge clk);
        rst         = 1'b0;
        repeat (20) @(posedge clk);

        $display("tb_uart_echo: 10 MHz clock, 115200 8N1");

        check_echo(8'h48); // H
        check_echo(8'h65); // e
        check_echo(8'h6c); // l
        check_echo(8'h6c); // l
        check_echo(8'h6f); // o
        check_echo(8'h00);
        check_echo(8'hff);
        check_echo(8'ha5);
        check_echo(8'h5a);

        // Two bytes back-to-back; the DUT has a one-byte hold register.
        begin : back_to_back
            reg [7:0] g0, g1;
            fork
                begin
                    send_byte(8'h11);
                    send_byte(8'h22);
                end
                begin
                    recv_byte(g0);
                    recv_byte(g1);
                end
            join
            if (g0 !== 8'h11 || g1 !== 8'h22) begin
                $display("ERROR: back-to-back got 0x%02x 0x%02x, expected 0x11 0x22", g0, g1);
                errors = errors + 1;
            end else begin
                $display("PASS: back-to-back 0x11 0x22");
            end
        end

        if (saw_toggle == 0) begin
            $display("ERROR: rx_toggle never changed");
            errors = errors + 1;
        end else begin
            $display("PASS: rx_toggle flipped during the test");
        end

        if (errors == 0) begin
            $display("tb_uart_echo: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("tb_uart_echo: FAILED with %0d error(s)", errors);
            $fatal(1);
        end
    end

    always @(posedge rx_toggle or negedge rx_toggle) begin
        if (!rst)
            saw_toggle = saw_toggle + 1;
    end

    initial begin
        #50_000_000;
        $display("ERROR: simulation timed out");
        $fatal(1);
    end

endmodule
