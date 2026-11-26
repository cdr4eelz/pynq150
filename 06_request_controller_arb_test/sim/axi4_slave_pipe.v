// Pipelined AXI4 slave memory for the 06 Icarus test (the 03 model handles
// one transaction at a time, which hides any overlap). Single ID, in-order
// responses, INCR bursts, WSTRB. Byte memory indexed by addr[MEM_AW-1:0].
//   - up to QD outstanding AWs / ARs are queued (awready / arready low when full)
//   - W data is accepted only while an AW is queued (like HP0)
//   - BRESP follows the last W beat by BLAT cycles
//   - read data for an AR starts RLAT cycles after the AR was accepted, then
//     one beat per cycle; reads are served in order
//   - STALL=1: pseudo-random 25 % ready de-assertion on AW/W/AR (as in 03)
`timescale 1ns / 1ps
module axi4_slave_pipe #(
    parameter MEM_AW = 16,
    parameter QD     = 16,
    parameter RLAT   = 40,
    parameter BLAT   = 30,
    parameter STALL  = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
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
    input  wire [2:0]  s_axi_arsize,
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

    reg [7:0] lfsr;
    always @(posedge clk)
        if (rst) lfsr <= 8'hA5;
        else lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    wire stall = (STALL != 0) && (lfsr[1:0] == 2'b00);

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // ---- write address queue ----
    reg [31:0] awq_a [0:QD-1];
    reg [7:0]  awq_l [0:QD-1];
    integer awq_wp, awq_rp, awq_n;

    // ---- write data ----
    reg [31:0] wa;               // current address
    reg [7:0]  wl, wc;           // len, beats so far
    reg        wact;

    // ---- B queue (cycle at which each B may be given) ----
    integer bq [0:QD*2-1];
    integer bq_wp, bq_rp, bq_n;
    integer now;

    // ---- read address queue ----
    reg [31:0] arq_a [0:QD-1];
    reg [7:0]  arq_l [0:QD-1];
    integer    arq_t [0:QD-1];
    integer arq_wp, arq_rp, arq_n;

    // ---- read data ----
    reg [31:0] ra;
    reg [7:0]  rl, rc;
    reg        ract;
    reg [63:0] rd_q;
    reg        rv_q, rlast_q;
    assign s_axi_rdata  = rd_q;
    assign s_axi_rvalid = rv_q;
    assign s_axi_rlast  = rlast_q;

    integer i;
    reg [31:0] a_t;
    reg        start_burst;
    reg [31:0] wa_n;
    reg [31:0] ra_n;
    integer out_aw, out_ar;
    // All DUT-visible outputs are registers updated with <= at the end of the
    // block, so the DUT never races the blocking model state above.

    always @(posedge clk) begin
        if (rst) begin
            awq_wp = 0; awq_rp = 0; awq_n = 0; wact = 0; wa = 0; wl = 0; wc = 0;
            bq_wp = 0; bq_rp = 0; bq_n = 0; now = 0;
            arq_wp = 0; arq_rp = 0; arq_n = 0; ract = 0; rv_q <= 1'b0; rlast_q <= 1'b0; rd_q <= 64'd0;
            ra = 0; rl = 0; rc = 0; out_aw = 0; out_ar = 0;
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_arready <= 1'b0;
        end else begin
            now = now + 1;
            // B handshake
            if (s_axi_bvalid && s_axi_bready) begin
                bq_rp = bq_rp + 1; bq_n = bq_n - 1;
            end
            // AW accept
            if (s_axi_awvalid && s_axi_awready) begin
                awq_a[awq_wp % QD] = s_axi_awaddr;
                awq_l[awq_wp % QD] = s_axi_awlen;
                awq_wp = awq_wp + 1; awq_n = awq_n + 1;
            end
            // W accept
            if (s_axi_wvalid && s_axi_wready) begin
                if (!wact) begin
                    wa = awq_a[awq_rp % QD]; wl = awq_l[awq_rp % QD]; wc = 0;
                    awq_rp = awq_rp + 1; awq_n = awq_n - 1;
                    wact = 1;
                end
                for (i = 0; i < 8; i = i + 1)
                    if (s_axi_wstrb[i])
                        mem[(wa + i) & (DEPTH - 1)] = s_axi_wdata[i*8 +: 8];
                wa = wa + 8;
                if (s_axi_wlast || wc == wl) begin
                    wact = 0;
                    bq[bq_wp % (QD*2)] = now + BLAT;
                    bq_wp = bq_wp + 1; bq_n = bq_n + 1;
                end else
                    wc = wc + 1;
            end
            // AR accept
            if (s_axi_arvalid && s_axi_arready) begin
                arq_a[arq_wp % QD] = s_axi_araddr;
                arq_l[arq_wp % QD] = s_axi_arlen;
                arq_t[arq_wp % QD] = now + RLAT;
                arq_wp = arq_wp + 1; arq_n = arq_n + 1;
            end
            // R channel: one beat per cycle once the head AR's latency has passed
            if (rv_q && s_axi_rready) begin
                rv_q <= 1'b0; rlast_q <= 1'b0;
            end
            if ((!rv_q || s_axi_rready)) begin
                start_burst = 0;
                if (!ract && arq_n > 0 && now >= arq_t[arq_rp % QD]) begin
                    ra = arq_a[arq_rp % QD]; rl = arq_l[arq_rp % QD]; rc = 0;
                    arq_rp = arq_rp + 1; arq_n = arq_n - 1;
                    ract = 1; start_burst = 1;
                end
                if (ract) begin
                    for (i = 0; i < 8; i = i + 1)
                        rd_q[i*8 +: 8] <= mem[(ra + i) & (DEPTH - 1)];
                    rv_q    <= 1'b1;
                    rlast_q <= (rc == rl);
                    ra = ra + 8;
                    if (rc == rl) ract = 0;
                    else rc = rc + 1;
                end
            end
            s_axi_awready <= (awq_n < QD) && !stall;
            s_axi_wready  <= (wact || awq_n > 0) && !stall;
            s_axi_arready <= (arq_n < QD) && !stall;
            s_axi_bvalid  <= (bq_n > 0) && ((now + 1) >= bq[bq_rp % (QD*2)]);
        end
    end
endmodule
