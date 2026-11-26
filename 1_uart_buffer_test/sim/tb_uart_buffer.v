`timescale 1ns / 1ps

// Host-side bit-banged UART talking to uart_buffer. The DUT runs at
// 10 MHz so the test finishes quickly; the baud is still 115200 8N1.
// The host uses the ideal bit period (8680 ns) while the DUT uses
// integer CLK_FREQ/BAUD, matching tb_uart_echo.v.
module tb_uart_buffer;

    localparam CLK_FREQ = 10_000_000;
    localparam BAUD     = 115200;
    localparam CLK_NS   = 100;
    localparam BIT_NS   = CLK_NS * (CLK_FREQ / BAUD); // DUT bit period (8600 ns at 10 MHz)
    localparam NBYTES   = 256;

    reg        clk;
    reg        rst;
    reg        uart_to_dut;
    wire       uart_from_dut;
    wire       rx_toggle;
    wire       tx_phase;

    integer    errors;
    integer    sending;
    integer    early_tx;
    integer    saw_toggle;
    integer    mismatches;
    integer    rx_count;

    uart_buffer #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .rxd      (uart_to_dut),
        .txd      (uart_from_dut),
        .rx_toggle(rx_toggle),
        .tx_phase (tx_phase)
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

    task run_frame;
        input integer salt;
        integer n;
        integer bad;
        integer first_bad;
        reg [7:0] got;
        begin
            sending  = 1;
            early_tx = 0;
            rx_count = 0;
            bad = 0;
            first_bad = -1;
            // Recv in parallel so a start bit that begins during the last
            // host stop bit is not missed.
            fork
                begin : send_loop
                    integer s;
                    for (s = 0; s < NBYTES; s = s + 1)
                        send_byte(pat(s, salt));
                    sending = 0;
                end
                begin : recv_loop
                    integer r;
                    wait (rx_count >= NBYTES);
                    for (r = 0; r < NBYTES; r = r + 1) begin
                        recv_byte(got);
                        if (got !== pat(r, salt)) begin
                            if (bad < 4)
                                $display("ERROR: byte %0d got 0x%02x, expected 0x%02x", r, got, pat(r, salt));
                            if (first_bad < 0)
                                first_bad = r;
                            bad = bad + 1;
                        end
                    end
                end
            join

            if (early_tx != 0) begin
                $display("ERROR: TX started before all 256 bytes were received (salt=%0d)", salt);
                errors = errors + 1;
            end else begin
                $display("PASS: no UART TX during the 256-byte host write (salt=%0d)", salt);
            end
            mismatches = mismatches + bad;
            if (bad != 0) begin
                $display("ERROR: replay mismatches=%0d first=%0d (salt=%0d)", bad, first_bad, salt);
                errors = errors + 1;
            end else begin
                $display("PASS: 256 bytes replayed in order (salt=%0d)", salt);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst)
            rx_count <= 0;
        else if (dut.u_rx.valid)
            rx_count <= rx_count + 1;
    end

    // TX is only an error if it starts before the 256th byte has been
    // accepted (valid). The DUT may start the first start bit during
    // the host's last stop-bit period, which is legal.
    always @(negedge uart_from_dut) begin
        if (sending && !rst && rx_count < NBYTES)
            early_tx = early_tx + 1;
    end

    always @(posedge rx_toggle or negedge rx_toggle) begin
        if (!rst)
            saw_toggle = saw_toggle + 1;
    end

    initial begin
        errors     = 0;
        early_tx   = 0;
        sending    = 0;
        saw_toggle = 0;
        mismatches = 0;
        rx_count   = 0;
        uart_to_dut = 1'b1;
        rst         = 1'b1;
        repeat (20) @(posedge clk);
        rst         = 1'b0;
        repeat (20) @(posedge clk);

        $display("tb_uart_buffer: 10 MHz clock, 115200 8N1, 256-byte buffer replay");

        run_frame(0);
        run_frame(11); // second frame, confirms the FSM returns to RX

        if (saw_toggle == 0) begin
            $display("ERROR: rx_toggle never changed");
            errors = errors + 1;
        end else begin
            $display("PASS: rx_toggle flipped during the test");
        end

        if (errors == 0) begin
            $display("tb_uart_buffer: ALL TESTS PASSED");
            $finish;
        end else begin
            $display("tb_uart_buffer: FAILED with %0d error(s), mismatches=%0d", errors, mismatches);
            $fatal(1);
        end
    end

    initial begin
        #300_000_000;
        $display("ERROR: simulation timed out");
        $fatal(1);
    end

endmodule
