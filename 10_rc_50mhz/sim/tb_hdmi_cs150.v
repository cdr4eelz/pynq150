// Self-checking testbench: vga_timing + test_pattern at the cs150 mode, 800x600@60
// (1056x628 total, H 40/128/88, V 1/4/23, positive syncs).
// Runs 3 frames. Checks hsync/vsync period and width, DE counts, bar and
// ramp colours, border, and that the box moves between frames.
`timescale 1ns/1ps
module tb_hdmi_cs150;
    localparam H_ACT = 800, V_ACT = 600, H_FP = 40, H_SYN = 128, H_BP = 88,
               V_FP = 1, V_SYN = 4, V_BP = 23, BAR_H = 450, BOXSZ = 40;
    localparam H_TOT = H_ACT + H_FP + H_SYN + H_BP, V_TOT = V_ACT + V_FP + V_SYN + V_BP;
    localparam BARW = H_ACT / 8;
    reg clk = 0, rst_n = 0;
    always #12.5 clk = ~clk;   // 40 MHz

    wire [11:0] x, y;
    wire t_de, t_hs, t_vs, tick;
    vga_timing #(.H_ACT(H_ACT), .H_FP(H_FP), .H_SYN(H_SYN), .H_BP(H_BP),
                .V_ACT(V_ACT), .V_FP(V_FP), .V_SYN(V_SYN), .V_BP(V_BP),
                .HS_NEG(0), .VS_NEG(0)) u_t (.clk(clk), .rst_n(rst_n), .x(x), .y(y), .de(t_de),
                    .hs(t_hs), .vs(t_vs), .frame_tick(tick));
    wire [7:0] r, g, b;
    wire de, hs, vs;
    test_pattern #(.H_ACT(H_ACT), .V_ACT(V_ACT), .BAR_H(BAR_H), .BOX(BOXSZ), .STEP_X(4), .STEP_Y(3),
                  .BAR_MUL(41), .BAR_SH(12), .RAMP_MUL(327), .RAMP_SH(10)) u_p (.clk(clk), .rst_n(rst_n), .x(x), .y(y), .de_in(t_de),
                      .hs_in(t_hs), .vs_in(t_vs), .frame_tick(tick),
                      .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs));

    integer errors = 0;
    task fail(input [255:0] msg);
        begin errors = errors + 1; if (errors < 20) $display("FAIL t=%0t %0s x=%0d y=%0d", $time, msg, x, y); end
    endtask

    // Pixel coordinates for the output stage (pattern adds 1 clock):
    reg [11:0] ox, oy;
    always @(posedge clk) begin ox <= x; oy <= y; end

    // ---- sync/DE monitors on the pattern outputs ----
    integer clk_cnt = 0;
    integer hs_fall_prev = -1, hs_periods = 0, hs_bad_period = 0, hs_bad_width = 0;
    integer vs_fall_prev = -1, vs_periods = 0, vs_bad_period = 0, vs_bad_width = 0;
    integer hs_lo = 0, vs_lo = 0;
    reg hs_d = 0, vs_d = 0, de_d = 0;   // positive polarity: idle low
    integer de_cnt = 0, de_frames_ok = 0, frames = 0;
    integer line_de = 0, bad_line = 0, lines_with_de = 0;
    integer box_pix = 0, box_pix_last = 0, box_pix_prev = -1, box_moves = 0;
    integer bar_err = 0, ramp_err = 0, border_err = 0;
    integer ramp_prev = -1, ramp_nonmono = 0;
    reg [7:0] exp_r, exp_g, exp_b;
    integer bx;

    always @(posedge clk) if (rst_n) begin
        clk_cnt <= clk_cnt + 1;
        hs_d <= hs; vs_d <= vs; de_d <= de;
        // hsync
        if (hs) hs_lo = hs_lo + 1;
        if (!hs_d && hs) begin
            if (hs_fall_prev >= 0) begin
                hs_periods = hs_periods + 1;
                if (clk_cnt - hs_fall_prev != H_TOT) hs_bad_period = hs_bad_period + 1;
            end
            hs_fall_prev = clk_cnt; hs_lo = 1;
        end
        if (hs_d && !hs && hs_fall_prev >= 0 && hs_lo != H_SYN) hs_bad_width = hs_bad_width + 1;
        // vsync
        if (vs) vs_lo = vs_lo + 1;
        if (!vs_d && vs) begin
            if (vs_fall_prev >= 0) begin
                vs_periods = vs_periods + 1;
                if (clk_cnt - vs_fall_prev != H_TOT * V_TOT) vs_bad_period = vs_bad_period + 1;
            end
            vs_fall_prev = clk_cnt; vs_lo = 1;
        end
        if (vs_d && !vs && vs_fall_prev >= 0 && vs_lo != V_SYN * H_TOT) vs_bad_width = vs_bad_width + 1;
        // DE per line / frame
        if (de) begin de_cnt = de_cnt + 1; line_de = line_de + 1; end
        if (de_d && !de) begin
            if (line_de != H_ACT) bad_line = bad_line + 1;
            lines_with_de = lines_with_de + 1; line_de = 0;
        end
        // new frame boundary: vsync deasserts (falls)
        if (vs_d && !vs) begin
            if (frames > 0) begin
                if (de_cnt == H_ACT * V_ACT && lines_with_de == V_ACT) de_frames_ok = de_frames_ok + 1;
                else $display("FAIL frame %0d: de_cnt=%0d lines=%0d", frames, de_cnt, lines_with_de);
                if (box_pix_prev >= 0 && box_pix != box_pix_prev) box_moves = box_moves + 0;
            end
            if (frames > 0) box_pix_last = box_pix;
            frames = frames + 1; de_cnt = 0; lines_with_de = 0; box_pix = 0;
        end
        // blanking must be black
        if (!de && (r !== 8'h00 || g !== 8'h00 || b !== 8'h00)) fail("non-black blanking");
        // pixel content checks (ox,oy are the coordinates of the pixel on r,g,b)
        if (de) begin
            if (ox < 2 || ox >= H_ACT - 2 || oy < 2 || oy >= V_ACT - 2) begin
                if (!(r == 8'h80 && g == 8'h80 && b == 8'h80)) border_err = border_err + 1;
            end else if (oy < BAR_H) begin
                case (ox / BARW)
                    0: begin exp_r = 8'hFF; exp_g = 8'hFF; exp_b = 8'hFF; end
                    1: begin exp_r = 8'hFF; exp_g = 8'hFF; exp_b = 8'h00; end
                    2: begin exp_r = 8'h00; exp_g = 8'hFF; exp_b = 8'hFF; end
                    3: begin exp_r = 8'h00; exp_g = 8'hFF; exp_b = 8'h00; end
                    4: begin exp_r = 8'hFF; exp_g = 8'h00; exp_b = 8'hFF; end
                    5: begin exp_r = 8'hFF; exp_g = 8'h00; exp_b = 8'h00; end
                    6: begin exp_r = 8'h00; exp_g = 8'h00; exp_b = 8'hFF; end
                    default: begin exp_r = 8'h00; exp_g = 8'h00; exp_b = 8'h00; end
                endcase
                if (r == exp_r && g == exp_g && b == exp_b) ;
                else if (r == ~exp_r && g == ~exp_g && b == ~exp_b) box_pix = box_pix + 1;
                else bar_err = bar_err + 1;
            end else begin
                exp_r = (ox * 327) >> 10;
                if (r == exp_r && g == exp_r && b == exp_r) ;
                else if (r == ~exp_r && g == ~exp_r && b == ~exp_r) box_pix = box_pix + 1;
                else ramp_err = ramp_err + 1;
            end
        end
    end

    // box position per frame (sample at the frame tick pulse)
    integer box_x_prev = -1, box_x_cur;
    always @(posedge clk) if (tick && rst_n) begin
        bx = u_p.bx;
        if (box_x_prev >= 0 && bx != box_x_prev) box_moves = box_moves + 1;
        box_x_prev = bx;
    end

    integer ramp_cnt = 0;
    initial begin
        // exhaustive check of the x/100 and ramp arithmetic used in test_pattern
        begin : arith
            integer i; reg [31:0] m;
            for (i = 0; i < H_ACT; i = i + 1) begin
                m = i * 41;
                if (m[14:12] !== (i / BARW)) begin errors = errors + 1; $display("FAIL bar index x=%0d", i); end
                if (((i * 327) >> 10) < (((i - 1) * 327) >> 10) && i > 0) begin errors = errors + 1; $display("FAIL ramp nonmono x=%0d", i); end
            end
        end
        repeat (5) @(posedge clk);
        rst_n = 1;
        // 3.2 frames
        repeat (H_TOT * V_TOT * 3 + 4000) @(posedge clk);
        $display("hsync periods=%0d bad_period=%0d bad_width=%0d", hs_periods, hs_bad_period, hs_bad_width);
        $display("vsync periods=%0d bad_period=%0d bad_width=%0d", vs_periods, vs_bad_period, vs_bad_width);
        $display("frames seen=%0d, frames with exactly 800x600 DE=%0d, bad DE lines=%0d", frames, de_frames_ok, bad_line);
        $display("bar_err=%0d ramp_err=%0d border_err=%0d box_pixels(last full frame)=%0d box_moves=%0d",
                 bar_err, ramp_err, border_err, box_pix_last, box_moves);
        if (hs_periods < 1000 || hs_bad_period != 0 || hs_bad_width != 0) errors = errors + 1;
        if (vs_periods < 1 || vs_bad_period != 0 || vs_bad_width != 0) errors = errors + 1;
        if (de_frames_ok < 2 || bad_line != 0) errors = errors + 1;
        if (bar_err != 0 || ramp_err != 0 || border_err != 0) errors = errors + 1;
        if (box_moves < 2 || box_pix_last < 1400 || box_pix_last > BOXSZ * BOXSZ) errors = errors + 1;
        if (errors == 0) $display("TB_PASS"); else $display("TB_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
