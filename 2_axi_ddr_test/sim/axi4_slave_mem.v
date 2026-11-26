// Simple AXI4 slave memory for Icarus tests of uart_axi_ddr_test.
// Byte-addressable, 64 KB, indexed by addr[15:0]. Supports INCR bursts,
// WSTRB, and optional ready/valid backpressure. hold_arready lets the
// testbench park the read address channel (used to corrupt memory between
// the DUT write and the DUT read).
`timescale 1ns / 1ps

module axi4_slave_mem #(
    parameter ADDR_W  = 32,
    parameter DATA_W  = 64,
    parameter ID_W    = 1,
    parameter MEM_AW  = 16,
    parameter STALL   = 1           // 1 = occasional backpressure
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    hold_arready,

    input  wire [ID_W-1:0]         s_axi_awid,
    input  wire [ADDR_W-1:0]       s_axi_awaddr,
    input  wire [7:0]              s_axi_awlen,
    input  wire [2:0]              s_axi_awsize,
    input  wire [1:0]              s_axi_awburst,
    input  wire                    s_axi_awvalid,
    output reg                     s_axi_awready,

    input  wire [DATA_W-1:0]       s_axi_wdata,
    input  wire [DATA_W/8-1:0]     s_axi_wstrb,
    input  wire                    s_axi_wlast,
    input  wire                    s_axi_wvalid,
    output reg                     s_axi_wready,

    output wire [ID_W-1:0]         s_axi_bid,
    output wire [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    input  wire [ID_W-1:0]         s_axi_arid,
    input  wire [ADDR_W-1:0]       s_axi_araddr,
    input  wire [7:0]              s_axi_arlen,
    input  wire [2:0]              s_axi_arsize,
    input  wire [1:0]              s_axi_arburst,
    input  wire                    s_axi_arvalid,
    output reg                     s_axi_arready,

    output wire [ID_W-1:0]         s_axi_rid,
    output reg  [DATA_W-1:0]       s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output reg                     s_axi_rlast,
    output reg                     s_axi_rvalid,
    input  wire                    s_axi_rready
);

    localparam STRB_W = DATA_W / 8;
    localparam DEPTH  = (1 << MEM_AW);

    reg [7:0] mem [0:DEPTH-1];

    reg [ID_W-1:0]   awid_r, arid_r;
    reg [ADDR_W-1:0] awaddr_r, araddr_r;
    reg [7:0]        awlen_r, arlen_r;
    reg [2:0]        awsize_r, arsize_r;
    reg [7:0]        w_cnt, r_cnt;
    reg              wr_active, rd_active, rd_pending;

    reg [7:0] lfsr;

    integer i;
    reg [ADDR_W-1:0] next_ar;

    assign s_axi_bid   = awid_r;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rid   = arid_r;
    assign s_axi_rresp = 2'b00;

    wire stall = STALL && (lfsr[1:0] == 2'b00);

    function [ADDR_W-1:0] beat_incr;
        input [ADDR_W-1:0] addr;
        input [2:0]        size;
        begin
            beat_incr = addr + ({{(ADDR_W-8){1'b0}}, 8'b1} << size);
        end
    endfunction

    integer k;
    initial begin
        for (k = 0; k < DEPTH; k = k + 1)
            mem[k] = 8'hCC;
    end

    always @(posedge clk) begin
        if (rst)
            lfsr <= 8'hA5;
        else
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    end

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rlast   <= 1'b0;
            s_axi_rdata   <= {DATA_W{1'b0}};
            wr_active     <= 1'b0;
            rd_active     <= 1'b0;
            rd_pending    <= 1'b0;
            w_cnt         <= 8'd0;
            r_cnt         <= 8'd0;
            awid_r        <= {ID_W{1'b0}};
            arid_r        <= {ID_W{1'b0}};
            awaddr_r      <= {ADDR_W{1'b0}};
            araddr_r      <= {ADDR_W{1'b0}};
            awlen_r       <= 8'd0;
            arlen_r       <= 8'd0;
            awsize_r      <= 3'd0;
            arsize_r      <= 3'd0;
        end else begin
            // ---- write address ----
            if (!wr_active && !s_axi_bvalid) begin
                s_axi_awready <= !stall;
                if (s_axi_awvalid && s_axi_awready) begin
                    awid_r        <= s_axi_awid;
                    awaddr_r      <= s_axi_awaddr;
                    awlen_r       <= s_axi_awlen;
                    awsize_r      <= s_axi_awsize;
                    w_cnt         <= 8'd0;
                    wr_active     <= 1'b1;
                    s_axi_awready <= 1'b0;
                    s_axi_wready  <= 1'b1;
                end
            end else begin
                s_axi_awready <= 1'b0;
            end

            // ---- write data ----
            if (wr_active) begin
                s_axi_wready <= !stall;
                if (s_axi_wvalid && s_axi_wready) begin
                    for (i = 0; i < STRB_W; i = i + 1) begin
                        if (s_axi_wstrb[i])
                            mem[awaddr_r[MEM_AW-1:0] + i[MEM_AW-1:0]] <= s_axi_wdata[i*8 +: 8];
                    end
                    if (s_axi_wlast || (w_cnt == awlen_r)) begin
                        wr_active    <= 1'b0;
                        s_axi_wready <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                    end else begin
                        w_cnt    <= w_cnt + 8'd1;
                        awaddr_r <= beat_incr(awaddr_r, awsize_r);
                    end
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // ---- read address ----
            if (!rd_active && !rd_pending) begin
                s_axi_arready <= (!hold_arready && !stall);
                if (s_axi_arvalid && s_axi_arready) begin
                    arid_r        <= s_axi_arid;
                    araddr_r      <= s_axi_araddr;
                    arlen_r       <= s_axi_arlen;
                    arsize_r      <= s_axi_arsize;
                    r_cnt         <= 8'd0;
                    rd_pending    <= 1'b1;
                    s_axi_arready <= 1'b0;
                end
            end else begin
                s_axi_arready <= 1'b0;
            end

            // ---- read data ----
            if (rd_pending && !rd_active) begin
                if (!stall) begin
                    rd_pending  <= 1'b0;
                    rd_active   <= 1'b1;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rlast  <= (arlen_r == 8'd0);
                    for (i = 0; i < STRB_W; i = i + 1)
                        s_axi_rdata[i*8 +: 8] <= mem[araddr_r[MEM_AW-1:0] + i[MEM_AW-1:0]];
                end
            end else if (rd_active && s_axi_rvalid && s_axi_rready) begin
                if (s_axi_rlast) begin
                    rd_active    <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast  <= 1'b0;
                end else if (stall) begin
                    s_axi_rvalid <= 1'b0;
                    araddr_r     <= beat_incr(araddr_r, arsize_r);
                    r_cnt        <= r_cnt + 8'd1;
                end else begin
                    next_ar = beat_incr(araddr_r, arsize_r);
                    araddr_r <= next_ar;
                    r_cnt    <= r_cnt + 8'd1;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rlast  <= (r_cnt + 8'd1 == arlen_r);
                    for (i = 0; i < STRB_W; i = i + 1)
                        s_axi_rdata[i*8 +: 8] <= mem[next_ar[MEM_AW-1:0] + i[MEM_AW-1:0]];
                end
            end else if (rd_active && !s_axi_rvalid && !stall) begin
                // resume after a stall between beats; araddr_r already advanced
                s_axi_rvalid <= 1'b1;
                s_axi_rlast  <= (r_cnt == arlen_r);
                for (i = 0; i < STRB_W; i = i + 1)
                    s_axi_rdata[i*8 +: 8] <= mem[araddr_r[MEM_AW-1:0] + i[MEM_AW-1:0]];
            end
        end
    end

endmodule
