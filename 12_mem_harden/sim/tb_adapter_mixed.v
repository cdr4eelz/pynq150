// Mixed read/write test for rc_axi_fifo_adapter: the cs150 RequestController
// (12: with the proj150 pixf priority + caf_backlog gate) with two behavioural clients, rc_axi_fifo_adapter (with the mig_*
// FIFO models) and the hostile slave sim/axi4_slave_rand.v.
//   data port : Cache.v-style WRITE1/WRITE2 and FETCH/READ1/READ2 (reads AND writes)
//   pixf port : read-only streaming reads, up to the FIFO credit in flight
// A reference memory is updated in command order, at the cycle each command is
// accepted into mig_caf (that IS the order MIG would execute them in). Each read
// result must equal the reference line as of its position in that order, so any
// RAW / WAR reordering by the AXI side shows up as a data mismatch.
//
// MODE 0  random mix over a small hot set of lines (many same-line hazards)
// MODE 1  throughput: sequential writes to lines [WBASE..] while pixf streams
//         lines [RBASE..] (disjoint regions) - no hazards, overlap is free
// MODE 2  throughput, worst case: writes and streaming reads walk the SAME lines
// MODE 3  (12) display under a write flood: data port writes back to back (as MODE 1) while pixf
//         reads at display pace, one line per PIXP RC cycles; PIXF_LAT reports the worst and mean
//         request->last-beat latency of the pixf reads (what a PixelFeeder FIFO must cover)
// Parameters (iverilog -P): MODE N SEED RLAT_MIN RLAT_MAX BLAT_MIN BLAT_MAX HOT GAP
// Needs iverilog -g2012. -DHAVE_HZ adds the hazard-hold statistics (patched adapter only).
`timescale 1ns / 1ps
module tb_adapter_mixed;
    parameter MODE     = 0;
    parameter N        = 4000;               // data-port ops / pixf reads
    parameter SEED     = 1;
    parameter WIN_AW   = 14;
    parameter MEM_AW   = 16;
    parameter RLAT_MIN = 4;
    parameter RLAT_MAX = 60;
    parameter BLAT_MIN = 2;
    parameter BLAT_MAX = 60;
    parameter STALL    = 1;
    parameter HOT      = 24;                 // MODE 0: hot-set size in lines
    parameter GAP      = 2;                  // MODE 0: max idle cycles between ops
    parameter PIXP     = 10;                 // MODE 3: RC cycles per pixf line (10 = 160 MB/s)
    parameter [31:0] BASE = 32'h1684_9F20;
    localparam NLINES = 1 << (WIN_AW - 5);

    reg clk, axi_clk, rst, axi_rst;
    wire a_ready;                   // adapter FIFOs out of reset recovery
    initial begin clk = 1'b0; axi_clk = 1'b0; end
    always #10 clk = ~clk;          // 50 MHz RC
    always #5  axi_clk = ~axi_clk;  // 100 MHz AXI

    // ---------------- DUT chain ----------------
    wire         rcon_caf_full, rcon_caf_wren, rcon_wdf_full, rcon_wdf_wren, rcon_caf_backlog;
    wire [33:0]  rcon_caf_cadr;
    wire [143:0] rcon_wdf_mdat;
    wire         rcon_rdf_rden, rcon_rdf_wren;
    wire [127:0] rdf_data;
    wire         data_caf_full, data_wdf_full, data_rdf_wren, pixf_raf_full, pixf_rdf_wren;
    reg          data_caf_wren, data_wdf_wren, data_rdf_rden;
    reg  [33:0]  data_caf_cadr;
    reg  [143:0] data_wdf_mdat;
    reg          pixf_raf_wren, pixf_rdf_rden;
    reg  [30:0]  pixf_raf_addr;

    RequestController rc (
        .clk(clk), .rst(rst),
        .caf_full(rcon_caf_full), .wdf_full(rcon_wdf_full), .caf_backlog(rcon_caf_backlog), .rdf_wren(rcon_rdf_wren),
        .inst_caf_wren(1'b0), .inst_caf_cadr(34'd0), .inst_wdf_wren(1'b0),
        .inst_wdf_mdat(144'd0), .inst_rdf_rden(1'b0), .inst_stall(1'b0),
        .data_caf_wren(data_caf_wren), .data_caf_cadr(data_caf_cadr),
        .data_wdf_wren(data_wdf_wren), .data_wdf_mdat(data_wdf_mdat),
        .data_rdf_rden(data_rdf_rden), .data_stall(1'b0),
        .gcmd_raf_wren(1'b0), .gcmd_raf_addr(31'd0), .gcmd_rdf_rden(1'b0),
        .pixf_raf_wren(pixf_raf_wren), .pixf_raf_addr(pixf_raf_addr), .pixf_rdf_rden(pixf_rdf_rden),
        .fill_waf_wren(1'b0), .fill_waf_addr(31'd0), .fill_wdf_wren(1'b0), .fill_wdf_mdat(144'd0),
        .line_waf_wren(1'b0), .line_waf_addr(31'd0), .line_wdf_wren(1'b0), .line_wdf_mdat(144'd0),
        .bpas_waf_wren(1'b0), .bpas_waf_addr(31'd0), .bpas_wdf_wren(1'b0), .bpas_wdf_mdat(144'd0),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .rdf_rden(rcon_rdf_rden),
        .inst_caf_full(), .inst_wdf_full(), .inst_rdf_wren(),
        .data_caf_full(data_caf_full), .data_wdf_full(data_wdf_full),
        .data_rdf_wren(data_rdf_wren),
        .gcmd_raf_full(), .gcmd_rdf_wren(), .pixf_raf_full(pixf_raf_full), .pixf_rdf_wren(pixf_rdf_wren),
        .fill_waf_full(), .fill_wdf_full(), .line_waf_full(), .line_wdf_full(),
        .bpas_waf_full(), .bpas_wdf_full());

    wire [0:0] awid, bid, arid, rid;
    wire [31:0] awaddr, araddr;
    wire [7:0] awlen, arlen;
    wire [2:0] awsize, arsize;
    wire [1:0] awburst, arburst, bresp, rresp;
    wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire arvalid, arready, rvalid, rready, rlast;
    wire [63:0] wdata, rdata;
    wire [7:0] wstrb;
    wire axi_err, bad_cmd, a_idle;
    wire [3:0] peak_wr, peak_rd;
    reg  clr_err;

    rc_axi_fifo_adapter #(.WIN_AW(WIN_AW)) u_adapter (
        .clk(clk), .rst(rst), .axi_clk(axi_clk), .axi_rst(axi_rst), .ready(a_ready),
        .base_addr(BASE), .clr_err(clr_err),
        .axi_err(axi_err), .bad_cmd(bad_cmd), .peak_wr(peak_wr), .peak_rd(peak_rd), .idle(a_idle),
        .caf_wren(rcon_caf_wren), .caf_cadr(rcon_caf_cadr), .caf_full(rcon_caf_full), .caf_backlog(rcon_caf_backlog),
        .wdf_wren(rcon_wdf_wren), .wdf_mdat(rcon_wdf_mdat), .wdf_full(rcon_wdf_full),
        .rdf_wren(rcon_rdf_wren), .rdf_data(rdf_data), .rdf_rden(rcon_rdf_rden),
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
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));
    assign bid = 1'b0;
    assign rid = 1'b0;

    axi4_slave_rand #(.MEM_AW(MEM_AW), .STALL(STALL), .SEED(32'h9E37_79B9 * (SEED + 1)),
                      .RLAT_MIN(RLAT_MIN), .RLAT_MAX(RLAT_MAX),
                      .BLAT_MIN(BLAT_MIN), .BLAT_MAX(BLAT_MAX)) u_mem (
        .clk(axi_clk), .rst(axi_rst),
        .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    // ---------------- reference model ----------------
    reg [255:0] refm [0:NLINES-1];
    function [255:0] genline(input integer line, input integer ver);
        integer w;
        reg [255:0] t;
        begin
            for (w = 0; w < 8; w = w + 1)
                t[w*32 +: 32] = (ver * 32'h9E37_79B1) ^ {line[15:0], 8'h5A, w[7:0]} ^ (ver << 20);
            genline = t;
        end
    endfunction
    // line image as the slave memory sees it: bytes 0..15 = first 128-bit half
    task poke_line(input integer line, input [255:0] l);
        integer b;
        reg [31:0] a;
        begin
            for (b = 0; b < 32; b = b + 1) begin
                a = (BASE + line * 32 + b) & ((1 << MEM_AW) - 1);
                u_mem.mem[a] = (b < 16) ? l[128 + b*8 +: 8] : l[(b-16)*8 +: 8];
            end
        end
    endtask
    function [255:0] peek_line(input integer line);
        integer b;
        reg [31:0] a;
        reg [255:0] t;
        begin
            for (b = 0; b < 32; b = b + 1) begin
                a = (BASE + line * 32 + b) & ((1 << MEM_AW) - 1);
                if (b < 16) t[128 + b*8 +: 8] = u_mem.mem[a];
                else        t[(b-16)*8 +: 8]  = u_mem.mem[a];
            end
            peek_line = t;
        end
    endfunction

    // ---------------- random numbers (tb side) ----------------
    reg [31:0] trng;
    function [31:0] nxt(input [31:0] x);
        reg [31:0] y;
        begin y = x ^ (x << 13); y = y ^ (y >> 17); nxt = y ^ (y << 5); end
    endfunction
    always @(posedge clk) trng <= nxt(trng);

    // ---------------- data-port client (Cache.v handshake) ----------------
    localparam D_IDLE = 0, D_W1 = 1, D_W2 = 2, D_F = 3, D_R1 = 4, D_R2 = 5, D_GAP = 6;
    integer dcs, d_ops, d_gap, d_line, d_seq, wver;
    reg [255:0] d_L, d_exp, d_half;
    reg         d_done;
    integer     errors, wr_cmds, rd_cmds_d, rd_cmds_p, hz_raw, hz_war;
    reg [255:0] d_got;

    // pixf client
    integer p_issued, p_got, p_gap, p_line;
    reg     p_half;
    reg [127:0] p_e0;
    reg     p_busy;
    reg [255:0] expq [0:262143];
    integer qh, qt;
    integer p_total;
    reg started;
    integer t0, t1, cyc;

    function integer wr_line(input integer k);
        begin
            if (MODE == 0)      wr_line = (trng[23:8] % HOT);
            else if (MODE == 1 || MODE == 3) wr_line = (NLINES/2) + (k % (NLINES/2));
            else                wr_line = (k % (NLINES/2));
        end
    endfunction
    function integer rd_line(input integer k);
        begin
            if (MODE == 0)      rd_line = (trng[27:12] % HOT);
            else                rd_line = (k % (NLINES/2));
        end
    endfunction

    // reference-model update / expectation capture: at the accept cycle
    always @(posedge clk) if (!rst && rcon_caf_wren) begin : acc
        integer ln;
        ln = (rcon_caf_cadr[30:0] >> 2) & (NLINES - 1);
        if (rcon_caf_cadr[33:31] == 3'b000) begin
            refm[ln] = d_L;                       // only the data port writes
            wr_cmds = wr_cmds + 1;
        end else if (rc.fifo_access == 3'b001) begin
            d_exp = refm[ln];                     // data-port read
            rd_cmds_d = rd_cmds_d + 1;
        end else begin
            expq[qt % 262144] = refm[ln];         // pixf read
            qt = qt + 1;
            rd_cmds_p = rd_cmds_p + 1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            dcs <= D_IDLE; d_ops <= 0; d_done <= 1'b0; d_seq = 0; wver = 0;
            data_caf_wren <= 1'b0; data_wdf_wren <= 1'b0; data_rdf_rden <= 1'b0;
            data_caf_cadr <= 34'd0; data_wdf_mdat <= 144'd0; d_gap = 0;
        end else begin
            case (dcs)
            D_IDLE: if (started && !d_done) begin
                if (d_ops >= N) d_done <= 1'b1;
                else begin
                    d_line = wr_line(d_ops);
                    if (MODE == 0 && trng[3]) begin     // read
                        data_caf_cadr <= {3'b001, d_line[22:0] << 2 | 31'd0};
                        data_caf_wren <= 1'b1;
                        dcs <= D_F;
                    end else begin                      // write
                        wver = wver + 1;
                        d_L = genline(d_line, wver);
                        data_caf_cadr <= {3'b000, 31'(d_line << 2)};
                        data_caf_wren <= 1'b1;
                        data_wdf_wren <= 1'b1;
                        data_wdf_mdat <= {16'h0000, genline(d_line, wver) >> 128};
                        dcs <= D_W1;
                    end
                end
            end
            D_W1: if (!data_caf_full && !data_wdf_full) begin
                data_caf_wren <= 1'b0;
                data_wdf_mdat <= {16'h0000, d_L[127:0]};
                dcs <= D_W2;
            end
            D_W2: if (!data_wdf_full) begin
                data_wdf_wren <= 1'b0;
                d_ops <= d_ops + 1;
                d_gap = (MODE == 0) ? (trng[31:29] % (GAP + 1)) : 0;
                dcs <= (d_gap > 0) ? D_GAP : D_IDLE;
            end
            D_F: if (!data_caf_full) begin
                data_caf_wren <= 1'b0;
                data_rdf_rden <= 1'b1;
                dcs <= D_R1;
            end
            D_R1: if (data_rdf_wren) begin
                d_half <= {rdf_data, 128'd0};
                dcs <= D_R2;
            end
            D_R2: if (data_rdf_wren) begin
                data_rdf_rden <= 1'b0;
                d_got = d_half | rdf_data;
                if (d_got !== d_exp) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("MISMATCH data-port read line %0d t=%0d\n   got %h\n   exp %h", d_line, cyc, d_got, d_exp);
                end
                d_ops <= d_ops + 1;
                d_gap = (MODE == 0) ? (trng[31:29] % (GAP + 1)) : 0;
                dcs <= (d_gap > 0) ? D_GAP : D_IDLE;
            end
            D_GAP: begin
                d_gap = d_gap - 1;
                if (d_gap <= 0) dcs <= D_IDLE;
            end
            endcase
        end
    end

    // pixf client: issues reads back to back (random pauses in MODE 0), keeps
    // pixf_rdf_rden high, and checks each returned line against the queue.
    always @(posedge clk) begin
        if (rst) begin
            p_issued = 0; p_got = 0; p_gap = 0; p_busy = 0; p_half = 0;
            pixf_raf_wren <= 1'b0; pixf_rdf_rden <= 1'b0; pixf_raf_addr <= 31'd0;
            qh = 0;
        end else begin
            pixf_rdf_rden <= started;
            if (pixf_raf_wren && !pixf_raf_full) begin   // accepted this cycle
                pixf_raf_wren <= 1'b0;
                p_issued = p_issued + 1;
                p_gap = (MODE == 0) ? (trng[30:28] % (GAP + 1)) : (MODE == 3) ? PIXP - 1 : 0;
            end else if (!pixf_raf_wren && started && p_issued < N) begin
                if (p_gap > 0) p_gap = p_gap - 1;
                else begin
                    p_line = rd_line(p_issued);
                    pixf_raf_addr <= 31'(p_line << 2);
                    pixf_raf_wren <= 1'b1;
                    p_t0[p_issued % 4096] = cyc;
                end
            end
            if (pixf_rdf_wren) begin
                if (!p_half) begin p_e0 = rdf_data; p_half = 1; end
                else begin
                    p_half = 0;
                    if ({p_e0, rdf_data} !== expq[qh % 262144]) begin
                        errors = errors + 1;
                        if (errors < 10)
                            $display("MISMATCH pixf read #%0d t=%0d\n   got %h\n   exp %h", p_got, cyc,
                                     {p_e0, rdf_data}, expq[qh % 262144]);
                    end
                    p_lat = cyc - p_t0[qh % 4096];
                    if (p_lat > p_lat_max) p_lat_max = p_lat;
                    p_lat_sum = p_lat_sum + p_lat;
                    qh = qh + 1; p_got = p_got + 1;
                end
            end
        end
    end

    always @(posedge clk) cyc <= rst ? 0 : cyc + 1;
    integer p_t0 [0:4095];
    integer p_lat, p_lat_max = 0;
    real    p_lat_sum = 0.0;
    // hazard statistics (cycles the head command is held by the conflict check);
    // only with the address-conflict adapter (-DHAVE_HZ)
    integer held_raw, held_war;
    always @(posedge clk) if (!rst) begin
`ifdef HAVE_HZ
        if (u_adapter.raw_hz && u_adapter.is_rd && u_adapter.caf_v) held_raw = held_raw + 1;
        if (u_adapter.war_hz && u_adapter.is_wr && u_adapter.caf_v) held_war = held_war + 1;
`endif
    end

    // ---------------- sequencing ----------------
    integer i, f;
    reg [255:0] pk;
    initial begin
        trng = 32'hC001_D00D ^ (SEED * 32'h1357_9BDF);
        errors = 0; wr_cmds = 0; rd_cmds_d = 0; rd_cmds_p = 0; qt = 0;
        held_raw = 0; held_war = 0;
        started = 0; clr_err = 0; rst = 1; axi_rst = 1;
        for (i = 0; i < NLINES; i = i + 1) begin
            refm[i] = genline(i, 0);
            poke_line(i, refm[i]);
        end
        repeat (10) @(posedge clk);
        rst <= 0; axi_rst <= 0;
        // clients may only start once the adapter's FIFOs are out of reset recovery
        // (fb_core holds the RequestController in reset until a_ready)
        f = 0;
        while (!a_ready && f < 5000) begin @(posedge clk); f = f + 1; end
        if (!a_ready) begin errors = errors + 1; $display("TIMEOUT waiting for adapter ready"); end
        repeat (20) @(posedge clk);
        started <= 1;
        t0 = cyc;
        // wait for both clients and all read data
        f = 0;
        while (!(d_done && p_got >= N) && f < 400000) begin
            @(posedge clk); f = f + 1;
        end
        t1 = cyc;
        if (f >= 400000) begin
            errors = errors + 1;
            $display("TIMEOUT: d_ops=%0d p_issued=%0d p_got=%0d", d_ops, p_issued, p_got);
        end
        // let writes complete
        f = 0;
        while (!a_idle && f < 2000) begin @(posedge clk); f = f + 1; end
        repeat (50) @(posedge clk);
        for (i = 0; i < NLINES; i = i + 1) begin
            pk = peek_line(i);
            if (pk !== refm[i]) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH final memory line %0d got %h exp %h", i, pk, refm[i]);
            end
        end
        if (axi_err || bad_cmd) begin errors = errors + 1; $display("adapter flags: axi_err=%b bad_cmd=%b", axi_err, bad_cmd); end
        $display("RESULT mode=%0d seed=%0d lat R%0d-%0d B%0d-%0d: writes=%0d dport_reads=%0d pixf_reads=%0d peak W=%0d R=%0d held raw=%0d war=%0d",
                 MODE, SEED, RLAT_MIN, RLAT_MAX, BLAT_MIN, BLAT_MAX, wr_cmds, rd_cmds_d, rd_cmds_p, peak_wr, peak_rd, held_raw, held_war);
        $display("TIME %0d RC cycles, %0d lines moved (%0d writes + %0d reads): %0.2f cyc/line, %0.0f MB/s (32 B lines, cycles of the 50 MHz RC clock; AXI at 100 MHz)",
                 t1 - t0, wr_cmds + rd_cmds_d + rd_cmds_p, wr_cmds, rd_cmds_d + rd_cmds_p,
                 1.0 * (t1 - t0) / (wr_cmds + rd_cmds_d + rd_cmds_p),
                 1600.0 * (wr_cmds + rd_cmds_d + rd_cmds_p) / (t1 - t0));
        $display("PIXF_LAT mode=%0d: max %0d RC cycles, mean %0.1f over %0d pixf reads", MODE, p_lat_max,
                 p_lat_sum / (p_got > 0 ? p_got : 1), p_got);
        if (errors == 0) $display("MIXED TEST PASSED");
        else $display("MIXED TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
