// AXI4 slave memory for the mixed read/write hazard test (tb_adapter_mixed).
// Like axi4_slave_pipe (single ID, in-order B and R, INCR, WSTRB, queued AW/AR)
// but made hostile on purpose, the way HP0 may legally behave:
//   * read and write paths are completely independent: nothing orders a read
//     against a write (or the reverse) except the master waiting for B / RLAST
//   * a write is COMMITTED to memory only when its B is presented
//     (BLAT_MIN..BLAT_MAX cycles after the last W beat)
//   * a read SAMPLES memory (all 4 beats at once) when its burst starts, which
//     is RLAT_MIN..RLAT_MAX cycles after the AR was accepted (or later, if the
//     previous burst is still being delivered)
// So an AR issued before an earlier same-line write's B can see old data, and an
// AW issued before an earlier same-line read's RLAST can overwrite the data that
// read is about to sample. A master that waits for B (RAW) / RLAST (WAR) always
// sees the right data; one that does not will read stale or too-new data.
// Latencies are drawn per transaction from an xorshift generator (SEED).
`timescale 1ns / 1ps
module axi4_slave_rand #(
    parameter MEM_AW   = 16,
    parameter QD       = 16,
    parameter RLAT_MIN = 4,
    parameter RLAT_MAX = 60,
    parameter BLAT_MIN = 2,
    parameter BLAT_MAX = 60,
    parameter STALL    = 1,                   // 1: random ready de-assertion (~25 %)
    parameter SEED     = 32'h1234_5678
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [63:0] s_axi_wdata,
    input  wire [7:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output wire [63:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rlast,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);
    localparam DEPTH = (1 << MEM_AW);
    reg [7:0] mem [0:DEPTH-1];
    integer k;
    initial for (k = 0; k < DEPTH; k = k + 1) mem[k] = 8'hCC;

    reg [31:0] rng;
    function [31:0] nxt(input [31:0] x);
        reg [31:0] y;
        begin y = x ^ (x << 13); y = y ^ (y >> 17); nxt = y ^ (y << 5); end
    endfunction
    function integer rrange(input integer lo, input integer hi, input [31:0] x);
        begin rrange = lo + ((hi > lo) ? (x[30:0] % (hi - lo + 1)) : 0); end
    endfunction

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // ---- AW queue / W burst assembly ----
    reg [31:0] awq_a [0:QD-1];
    reg [7:0]  awq_l [0:QD-1];
    integer awq_wp, awq_rp, awq_n;
    reg [31:0] wa;  reg [7:0] wl, wc;  reg wact;
    reg [63:0] wbd [0:255];  reg [7:0] wbs [0:255];        // current burst buffer
    // ---- B queue: completed bursts waiting for their commit/B time ----
    reg [31:0] bq_a [0:QD*2-1];
    reg [7:0]  bq_l [0:QD*2-1];
    reg [63:0] bq_d [0:QD*2-1][0:3];
    reg [7:0]  bq_s [0:QD*2-1][0:3];
    integer    bq_t [0:QD*2-1];
    integer bq_wp, bq_rp, bq_n;
    integer now;
    // ---- AR queue ----
    reg [31:0] arq_a [0:QD-1];
    reg [7:0]  arq_l [0:QD-1];
    integer    arq_t [0:QD-1];
    integer arq_wp, arq_rp, arq_n;
    // ---- R burst ----
    reg [63:0] rbuf [0:255];
    reg [7:0]  rl, rc;  reg ract;
    reg [63:0] rd_q;  reg rv_q, rlast_q;
    assign s_axi_rdata = rd_q;  assign s_axi_rvalid = rv_q;  assign s_axi_rlast = rlast_q;

    integer i, j;
    reg [31:0] a_t;
    reg [31:0] ra;
    reg        stall, bv_next, bhead_done;

    always @(posedge clk) begin
        if (rst) begin
            rng = SEED;
            awq_wp = 0; awq_rp = 0; awq_n = 0; wact = 0; wa = 0; wl = 0; wc = 0;
            bq_wp = 0; bq_rp = 0; bq_n = 0; now = 0; bhead_done = 0;
            arq_wp = 0; arq_rp = 0; arq_n = 0; ract = 0; rl = 0; rc = 0;
            rv_q <= 1'b0; rlast_q <= 1'b0; rd_q <= 64'd0;
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_arready <= 1'b0;
        end else begin
            now = now + 1;
            rng = nxt(rng);
            stall = (STALL != 0) && (rng[9:8] == 2'b00);
            // B handshake
            if (s_axi_bvalid && s_axi_bready) begin
                bq_rp = bq_rp + 1; bq_n = bq_n - 1; bhead_done = 0;
            end
            // AW accept
            if (s_axi_awvalid && s_axi_awready) begin
                awq_a[awq_wp % QD] = s_axi_awaddr;
                awq_l[awq_wp % QD] = s_axi_awlen;
                awq_wp = awq_wp + 1; awq_n = awq_n + 1;
            end
            // W accept: buffer the burst, memory is NOT updated yet
            if (s_axi_wvalid && s_axi_wready) begin
                if (!wact) begin
                    wa = awq_a[awq_rp % QD]; wl = awq_l[awq_rp % QD]; wc = 0;
                    awq_rp = awq_rp + 1; awq_n = awq_n - 1;
                    wact = 1;
                end
                wbd[wc] = s_axi_wdata; wbs[wc] = s_axi_wstrb;
                if (s_axi_wlast || wc == wl) begin
                    wact = 0;
                    bq_a[bq_wp % (QD*2)] = wa;
                    bq_l[bq_wp % (QD*2)] = wl;
                    for (j = 0; j <= 3; j = j + 1) begin
                        bq_d[bq_wp % (QD*2)][j] = wbd[j];
                        bq_s[bq_wp % (QD*2)][j] = wbs[j];
                    end
                    bq_t[bq_wp % (QD*2)] = now + rrange(BLAT_MIN, BLAT_MAX, rng);
                    bq_wp = bq_wp + 1; bq_n = bq_n + 1;
                end else
                    wc = wc + 1;
            end
            // AR accept
            if (s_axi_arvalid && s_axi_arready) begin
                arq_a[arq_wp % QD] = s_axi_araddr;
                arq_l[arq_wp % QD] = s_axi_arlen;
                arq_t[arq_wp % QD] = now + rrange(RLAT_MIN, RLAT_MAX, nxt(rng));
                arq_wp = arq_wp + 1; arq_n = arq_n + 1;
            end
            // R channel
            if (rv_q && s_axi_rready) begin
                rv_q <= 1'b0; rlast_q <= 1'b0;
            end
            if (!rv_q || s_axi_rready) begin
                if (!ract && arq_n > 0 && now >= arq_t[arq_rp % QD]) begin
                    ra = arq_a[arq_rp % QD]; rl = arq_l[arq_rp % QD]; rc = 0;
                    arq_rp = arq_rp + 1; arq_n = arq_n - 1;
                    ract = 1;
                    for (j = 0; j <= rl; j = j + 1)       // sample the whole burst now
                        for (i = 0; i < 8; i = i + 1)
                            rbuf[j][i*8 +: 8] = mem[(ra + j*8 + i) & (DEPTH - 1)];
                end
                if (ract) begin
                    rd_q    <= rbuf[rc];
                    rv_q    <= 1'b1;
                    rlast_q <= (rc == rl);
                    if (rc == rl) ract = 0; else rc = rc + 1;
                end
            end
            s_axi_awready <= (awq_n < QD) && !stall;
            s_axi_wready  <= (wact || awq_n > 0) && !stall;
            s_axi_arready <= (arq_n < QD) && !stall;
            // B: the head write is committed to memory in the cycle before its B
            // is first presented (bready is assumed 1, as in the adapter)
            bv_next = (bq_n > 0) && ((now + 1) >= bq_t[bq_rp % (QD*2)]);
            if (bv_next && !bhead_done) begin
                bhead_done = 1;
                for (j = 0; j <= 3; j = j + 1)
                    for (i = 0; i < 8; i = i + 1)
                        if (bq_s[bq_rp % (QD*2)][j][i])
                            mem[(bq_a[bq_rp % (QD*2)] + j*8 + i) & (DEPTH - 1)] =
                                bq_d[bq_rp % (QD*2)][j][i*8 +: 8];
            end
            s_axi_bvalid  <= bv_next;
        end
    end
endmodule
