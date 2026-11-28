// rc_axi_fifo_adapter: the MIG-shaped slot under the cs150 RequestController,
// rebuilt as in cs150/proj150 (Memory150.v / MemoryDDR.v): RequestController
// -> mig_caf / mig_wdf FIFOs -> "DDR" -> mig_rdf FIFO -> RequestController.
// "DDR" here is an AXI4 master on PS7 S_AXI_HP0 (64-bit, FCLK0 100 MHz) instead of MIG, so
// commands, write data and reads can overlap. The RequestController side
// of the FIFOs runs on clk (FCLK1, 50 MHz); the AXI side on axi_clk.
//
// The three FIFOs are the proj150 FIFO Generator IPs, unmodified
// (ip/mig_{caf,wdf,rdf}.tcl; Icarus stand-ins in sim/models/): independent-
// clock builtin FIFOs, 512 deep, FIRST-WORD-FALL-THROUGH with a valid flag.
//   mig_caf  31 bits {cmd[2:0], addr[27:0]}   prog_full @24  (caf_backlog)
//   mig_wdf 144 bits {mask[15:0], data[127:0]}
//   mig_rdf 128 bits                           prog_full @400 (read credit)
// The RequestController itself is the byte-identical cs150 one (34-bit
// caf_cadr, no caf_backlog input, rdf_wren = "MIG rd_data_valid" pulse):
//  * caf_cadr[30:28] (address bits above 2**28 x 8 B) are not stored in
//    mig_caf; the AXI window wraps in WIN_AW bits anyway.
//  * 12: prog_full of mig_caf is the caf_backlog output (wr_clk domain), for the
//    RequestController's backlog gate (proj150 port, see 12_mem_harden PLAN.md).
//  * 12: mig_caf's head is registered (hd_*) before the address-conflict check and
//    AW/AR issue (100 MHz timing); +1 axi_clk latency only when the queue was empty.
//  * FWFT valid stays high while a beat sits in mig_rdf, but the unmodified
//    RequestController counts every cycle rdf_wren is high as a serviced
//    read. So the beat is handed over as a one-cycle pulse exactly when it is
//    popped:  rdf_wren = mig_rdf.valid & rdf_rden  (proj150's rdf_pop).
//    A beat waits in the FIFO until its client raises rden, like cs150.
//
// RequestController master port            MIG v3.61 equivalent
//   caf_full   (out) "!ready"  mig_caf.full   app_af_afull
//   caf_wren/caf_cadr[33:0]    -> mig_caf     app_af_wren, app_af_cmd/addr
//   wdf_full   (out) "!ready"  mig_wdf.full   app_wdf_afull
//   wdf_wren/wdf_mdat[143:0]   -> mig_wdf     app_wdf_wren/mask/data
//   rdf_wren/rdf_data/rdf_rden <- mig_rdf     rd_data_valid / rd_data_fifo_out
//
// AXI side (single ID 0, all bursts 4 x 64 bit = one 32-byte block, INCR):
//  * commands leave mig_caf strictly in order. cmd 000 = write (AW), cmd 001
//    = read (AR), anything else sets bad_cmd and is dropped.
//  * up to MAX_WR_OUT writes and MAX_RD_OUT reads in flight (counted from
//    issue to BRESP / RLAST). They overlap because AW, W and B, and AR and
//    R, are independent channels fed by the FIFOs.
//  * ORDERING: MIG executes commands in order, AXI (HP0) does not order reads
//    against writes. Reads and writes overlap freely, except that the command
//    at the head of mig_caf is held while it touches the same 32-byte line as
//    an in-flight transaction of the OPPOSITE direction:
//      read-after-write: the AR waits until that write's BRESP has arrived
//      write-after-read: the AW waits until that read's RLAST has arrived
//    (same-direction hazards need no check: one ID, in-order responses).
//    The check compares the line index addr[WIN_AW-4:2] against a tag per
//    in-flight command (tags are kept in issue order and freed in response
//    order, since all responses are in order). Because every command is a
//    whole aligned 32-byte block, equal tags means overlap and different tags
//    means no overlap, so the check is exact (window wrapping is part of the
//    tag). Commands still leave mig_caf in order, so a held command also
//    holds the ones behind it.
//  * W: a write burst takes two mig_wdf entries (first entry = bytes 0..15,
//    each entry = two 64-bit beats, lower first; WSTRB = ~mask). W beats are
//    sent only for AWs that have already handshaked (credit counter).
//  * R: rready is always 1; beat pairs are assembled into 128-bit entries
//    and written to mig_rdf (MIG has no back-pressure either). To keep
//    mig_rdf from overflowing no AR is issued while mig_rdf.prog_full (400 of
//    512) is high; at most MAX_RD_OUT x 2 beats can still arrive (<< 112).
//    An overflow would set bad_cmd (sticky).
//
// Address: addr is in 8-byte units (as in Cache.v); addr[1:0] is forced 0 so
// a command is one 32-byte-aligned block (never crosses 4 KB). The block goes
// to base_addr + {addr[WIN_AW-4:2], 5'b0}: addresses wrap inside a
// 2**WIN_AW-byte window at base_addr.
module rc_axi_fifo_adapter #(
    parameter WIN_AW     = 20,           // window size = 2**WIN_AW bytes
    parameter MAX_WR_OUT = 8,            // outstanding AXI writes (<= 15)
    parameter MAX_RD_OUT = 8             // outstanding AXI reads  (<= 15)
) (
    input  wire          clk,            // RC / clients / UART (FCLK1, 50 MHz)
    input  wire          rst,            // sync-deassert, clk
    input  wire          axi_clk,        // AXI master / HP0 (FCLK0, 100 MHz)
    input  wire          axi_rst,        // sync-deassert, axi_clk
    input  wire [31:0]   base_addr,      // from clk; used on axi_clk (2FF)
    input  wire          clr_err,        // pulse on clk; cleared on axi_clk
    output reg           axi_err,        // sticky, clk (synced from axi_clk)
    output reg           bad_cmd,        // sticky, clk
    output reg  [3:0]    peak_wr,        // clk
    output reg  [3:0]    peak_rd,        // clk
    output reg           ready,          // clk: FIFOs out of reset and settled; hold
                                         // the RequestController + clients in reset
                                         // until this is 1 (FIFO Generator ignores
                                         // writes during its reset recovery)
    output wire          idle,           // clk: every accepted command has completed
                                         // (B / RLAST): data is in DDR

    // RequestController master port (MIG-style)
    output wire          caf_full,
    output wire          caf_backlog,    // 12: mig_caf prog_full (>= 24 commands queued)
    input  wire          caf_wren,
    input  wire [33:0]   caf_cadr,
    output wire          wdf_full,
    input  wire          wdf_wren,
    input  wire [143:0]  wdf_mdat,
    output wire          rdf_wren,       // one-cycle pulse per popped beat
    output wire [127:0]  rdf_data,
    input  wire          rdf_rden,

    // AXI4 master
    output wire [0:0]    m_axi_awid,
    output reg  [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output wire [2:0]    m_axi_awsize,
    output wire [1:0]    m_axi_awburst,
    output wire          m_axi_awlock,
    output wire [3:0]    m_axi_awcache,
    output wire [2:0]    m_axi_awprot,
    output wire [3:0]    m_axi_awqos,
    output wire [3:0]    m_axi_awregion,
    output reg           m_axi_awvalid,
    input  wire          m_axi_awready,
    output wire [63:0]   m_axi_wdata,
    output wire [7:0]    m_axi_wstrb,
    output wire          m_axi_wlast,
    output wire          m_axi_wvalid,
    input  wire          m_axi_wready,
    input  wire [0:0]    m_axi_bid,
    input  wire [1:0]    m_axi_bresp,
    input  wire          m_axi_bvalid,
    output wire          m_axi_bready,
    output wire [0:0]    m_axi_arid,
    output reg  [31:0]   m_axi_araddr,
    output wire [7:0]    m_axi_arlen,
    output wire [2:0]    m_axi_arsize,
    output wire [1:0]    m_axi_arburst,
    output wire          m_axi_arlock,
    output wire [3:0]    m_axi_arcache,
    output wire [2:0]    m_axi_arprot,
    output wire [3:0]    m_axi_arqos,
    output wire [3:0]    m_axi_arregion,
    output reg           m_axi_arvalid,
    input  wire          m_axi_arready,
    input  wire [0:0]    m_axi_rid,
    input  wire [63:0]   m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready
);

    // ---------------- AXI constants: one INCR burst of 4 x 8 bytes --------
    assign m_axi_awid = 1'b0;      assign m_axi_arid = 1'b0;
    assign m_axi_awlen = 8'd3;     assign m_axi_arlen = 8'd3;
    assign m_axi_awsize = 3'd3;    assign m_axi_arsize = 3'd3;
    assign m_axi_awburst = 2'b01;  assign m_axi_arburst = 2'b01;
    assign m_axi_awlock = 1'b0;    assign m_axi_arlock = 1'b0;
    assign m_axi_awcache = 4'b0011; assign m_axi_arcache = 4'b0011;
    assign m_axi_awprot = 3'b000;  assign m_axi_arprot = 3'b000;
    assign m_axi_awqos = 4'b0000;  assign m_axi_arqos = 4'b0000;
    assign m_axi_awregion = 4'b0000; assign m_axi_arregion = 4'b0000;

    // ---------------- the three proj150 FIFOs ----------------------------
    // Independent-clock (as on the ML505 / Arty: CPU clock vs MIG ui_clk).
    //   caf / wdf: written on clk (RC), read on axi_clk (AXI issue / W data)
    //   rdf:       written on axi_clk (R data), read on clk (RC)
    // fifo_rst is asserted with either domain reset and held for 16 clk
    // cycles after both have been released (FIFO Generator async reset).
    (* ASYNC_REG = "TRUE" *) reg axi_rst_s1, axi_rst_s2;
    always @(posedge clk) begin
        if (rst) begin axi_rst_s1 <= 1'b1; axi_rst_s2 <= 1'b1; end
        else     begin axi_rst_s1 <= axi_rst; axi_rst_s2 <= axi_rst_s1; end
    end
    wire fifo_hold = rst | axi_rst_s2;
    reg [4:0] fifo_rst_cnt;
    always @(posedge clk) begin
        if (fifo_hold) fifo_rst_cnt <= 5'd16;
        else if (fifo_rst_cnt != 5'd0) fifo_rst_cnt <= fifo_rst_cnt - 5'd1;
    end
    wire fifo_rst = fifo_hold | (fifo_rst_cnt != 5'd0);
    reg [6:0] settle_cnt;
    always @(posedge clk) begin
        if (fifo_rst) begin settle_cnt <= 7'd0; ready <= 1'b0; end
        else if (settle_cnt != 7'd127) settle_cnt <= settle_cnt + 7'd1;
        else ready <= 1'b1;
    end

    wire [30:0]  caf_d;
    wire         caf_v;
    wire         caf_rd;
    wire [143:0] wdf_d;
    wire         wdf_v;
    wire         wdf_rd;
    wire [127:0] rdf_d;
    wire         rdf_v;
    reg          rdf_wr_en;
    reg  [127:0] rdf_din;
    wire         rdf_ffull, rdf_pf;

    mig_caf u_caf (
        .rst(fifo_rst),
        .wr_clk(clk), .full(caf_full), .prog_full(caf_backlog),
        .wr_en(caf_wren), .din({caf_cadr[33:31], caf_cadr[27:0]}), .wr_ack(),
        .rd_clk(axi_clk), .empty(), .rd_en(caf_rd), .valid(caf_v), .dout(caf_d),
        .underflow());

    mig_wdf u_wdf (
        .rst(fifo_rst),
        .wr_clk(clk), .full(wdf_full), .wr_en(wdf_wren), .din(wdf_mdat), .wr_ack(),
        .rd_clk(axi_clk), .empty(), .rd_en(wdf_rd), .valid(wdf_v), .dout(wdf_d),
        .underflow());

    mig_rdf u_rdf (
        .rst(fifo_rst),
        .wr_clk(axi_clk), .full(rdf_ffull), .wr_en(rdf_wr_en), .din(rdf_din),
        .wr_ack(), .prog_full(rdf_pf),
        .rd_clk(clk), .empty(), .rd_en(rdf_rden), .valid(rdf_v), .dout(rdf_d),
        .underflow());

    assign rdf_data = rdf_d;
    assign rdf_wren = rdf_v & rdf_rden;      // pop pulse, see header

    // ---------------- command side (mig_caf -> AW / AR) -------------------
    reg  [3:0] wr_out, rd_out;               // in flight: issue -> B / RLAST
    wire       wr_done = m_axi_bvalid;       // bready is always 1

    (* ASYNC_REG = "TRUE" *) reg [31:0] base_s1, base_a;
    always @(posedge axi_clk) begin
        if (axi_rst) begin base_s1 <= 32'd0; base_a <= 32'd0; end
        else         begin base_s1 <= base_addr; base_a <= base_s1; end
    end

    wire       rd_done = m_axi_rvalid && m_axi_rlast;

    // ---- 12: command head register. mig_caf's FWFT output is popped into the hd_*
    // flops and the address-conflict check / AW-AR issue work from those flops, so
    // the FIFO18 clock-to-out and its fanout-33 dout routing are no longer in front
    // of the hazard compare -> issue -> tag-CE path (100 MHz worst path in 12's first
    // build). Same check, same order: a command issues only when its hazard check
    // (against the live in-flight tags) is clear. Cost: +1 axi_clk when the queue
    // was empty; back-to-back commands keep full rate (refill in the consume cycle).
    localparam TAGW = WIN_AW - 4 - 2 + 1;           // addr[WIN_AW-4:2]
    reg             hd_v;
    reg  [2:0]      hd_cmd;
    reg  [TAGW-1:0] hd_tag;
    reg  [31:0]     hd_blk;
    (* ASYNC_REG = "TRUE" *) reg [1:0] frst_a;     // fifo_rst (clk) -> axi_clk: drop hd
    always @(posedge axi_clk) frst_a <= {frst_a[0], fifo_rst};

    wire [2:0]  cmd   = hd_cmd;
    wire [31:0] blk   = hd_blk;
    wire        is_wr = hd_v && (cmd == 3'b000);
    wire        is_rd = hd_v && (cmd == 3'b001);
    wire        is_bad = hd_v && !is_wr && !is_rd;

    // ---- address-conflict check against in-flight opposite-direction tags
    reg  [TAGW-1:0] wtag [0:MAX_WR_OUT-1];          // writes: AW issued, B not yet seen
    reg  [TAGW-1:0] rtag [0:MAX_RD_OUT-1];          // reads: AR issued, RLAST not yet seen
    reg  [MAX_WR_OUT-1:0] wtv;
    reg  [MAX_RD_OUT-1:0] rtv;
    reg  [3:0] wt_head, wt_tail, rt_head, rt_tail;  // slots used in issue order
    reg        raw_hz, war_hz;
    integer    ci;
    always @(*) begin
        raw_hz = 1'b0;                              // head read vs in-flight writes
        for (ci = 0; ci < MAX_WR_OUT; ci = ci + 1)
            if (wtv[ci] && (wtag[ci] == hd_tag)) raw_hz = 1'b1;
        war_hz = 1'b0;                              // head write vs in-flight reads
        for (ci = 0; ci < MAX_RD_OUT; ci = ci + 1)
            if (rtv[ci] && (rtag[ci] == hd_tag)) war_hz = 1'b1;
    end

    wire aw_free = !m_axi_awvalid || m_axi_awready;
    wire ar_free = !m_axi_arvalid || m_axi_arready;
    wire wr_ok = is_wr && !war_hz && (wr_out < MAX_WR_OUT) && aw_free;
    wire rd_ok = is_rd && !raw_hz && (rd_out < MAX_RD_OUT) && ar_free
                 && !rdf_pf;
    wire hd_take  = wr_ok || rd_ok || is_bad;     // head consumed this cycle
    assign caf_rd = caf_v && (!hd_v || hd_take) && !frst_a[1];

    wire issue_wr = wr_ok;
    wire issue_rd = rd_ok;

    always @(posedge axi_clk) begin
        if (axi_rst || frst_a[1]) begin
            hd_v <= 1'b0; hd_cmd <= 3'd0; hd_tag <= {TAGW{1'b0}}; hd_blk <= 32'd0;
        end else if (caf_rd) begin
            hd_v   <= 1'b1;
            hd_cmd <= caf_d[30:28];
            hd_tag <= caf_d[WIN_AW-4:2];
            hd_blk <= base_a + {{(32-WIN_AW){1'b0}}, caf_d[WIN_AW-4:2], 5'b00000};
        end else if (hd_take) begin
            hd_v <= 1'b0;
        end
    end

    // commands accepted from the RequestController (caf_wren, clk) and not
    // yet completed (B / RLAST / dropped bad cmd on axi_clk). Completions are
    // counted in three +1-per-cycle gray counters (wr, rd, bad can all fire
    // in one axi_clk cycle, so a single +2 gray step would be unsafe) and
    // subtracted from pend on clk.
    // clr_err is a one-cycle pulse on clk; toggle-sync it into axi_clk.
    reg clr_tog;
    always @(posedge clk) begin
        if (rst) clr_tog <= 1'b0;
        else if (clr_err) clr_tog <= ~clr_tog;
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] clr_s;
    always @(posedge axi_clk) begin
        if (axi_rst) clr_s <= 3'd0;
        else         clr_s <= {clr_s[1:0], clr_tog};
    end
    wire clr_err_a = clr_s[2] ^ clr_s[1];

    function [10:0] bin2gray;
        input [10:0] b;
        begin bin2gray = b ^ {1'b0, b[10:1]}; end
    endfunction
    function [10:0] gray2bin;
        input [10:0] g;
        integer i;
        begin
            gray2bin[10] = g[10];
            for (i = 9; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    reg [10:0] wrd_a, rdd_a, bad_a;
    reg [10:0] wrd_a_g, rdd_a_g, bad_a_g;
    always @(posedge axi_clk) begin
        if (axi_rst) begin
            wrd_a <= 11'd0; rdd_a <= 11'd0; bad_a <= 11'd0;
            wrd_a_g <= 11'd0; rdd_a_g <= 11'd0; bad_a_g <= 11'd0;
        end else begin
            wrd_a <= wrd_a + {10'd0, wr_done};
            rdd_a <= rdd_a + {10'd0, rd_done};
            bad_a <= bad_a + {10'd0, is_bad};
            // gray-encode on the source clock (one bit changes per increment)
            wrd_a_g <= bin2gray(wrd_a + {10'd0, wr_done});
            rdd_a_g <= bin2gray(rdd_a + {10'd0, rd_done});
            bad_a_g <= bin2gray(bad_a + {10'd0, is_bad});
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [10:0] wrd_g1, wrd_g2, rdd_g1, rdd_g2, bad_g1, bad_g2;
    always @(posedge clk) begin
        if (rst) begin
            wrd_g1 <= 11'd0; wrd_g2 <= 11'd0;
            rdd_g1 <= 11'd0; rdd_g2 <= 11'd0;
            bad_g1 <= 11'd0; bad_g2 <= 11'd0;
        end else begin
            wrd_g1 <= wrd_a_g; wrd_g2 <= wrd_g1;
            rdd_g1 <= rdd_a_g; rdd_g2 <= rdd_g1;
            bad_g1 <= bad_a_g; bad_g2 <= bad_g1;
        end
    end
    // The gray word lags the increment by one axi_clk, which only delays idle.
    wire [10:0] wrd_c = gray2bin(wrd_g2);
    wire [10:0] rdd_c = gray2bin(rdd_g2);
    wire [10:0] bad_c = gray2bin(bad_g2);
    reg  [10:0] wrd_p, rdd_p, bad_p;
    reg  [10:0] pend;
    assign idle = (pend == 11'd0);
    always @(posedge clk) begin
        if (rst) begin
            wrd_p <= 11'd0; rdd_p <= 11'd0; bad_p <= 11'd0; pend <= 11'd0;
        end else begin
            wrd_p <= wrd_c; rdd_p <= rdd_c; bad_p <= bad_c;
            pend  <= pend + {10'd0, caf_wren}
                          - (wrd_c - wrd_p) - (rdd_c - rdd_p) - (bad_c - bad_p);
        end
    end

    // sticky flags and peaks live on axi_clk, then 2FF to clk for the UART FSM
    reg        axi_err_a, bad_cmd_a;
    reg  [3:0] peak_wr_a, peak_rd_a;
    (* ASYNC_REG = "TRUE" *) reg err_s1, err_s2, bad_s1, bad_s2;
    (* ASYNC_REG = "TRUE" *) reg [3:0] pwr_s1, pwr_s2, prd_s1, prd_s2;
    always @(posedge clk) begin
        if (rst) begin
            err_s1 <= 1'b0; err_s2 <= 1'b0; axi_err <= 1'b0;
            bad_s1 <= 1'b0; bad_s2 <= 1'b0; bad_cmd <= 1'b0;
            pwr_s1 <= 4'd0; pwr_s2 <= 4'd0; peak_wr <= 4'd0;
            prd_s1 <= 4'd0; prd_s2 <= 4'd0; peak_rd <= 4'd0;
        end else begin
            err_s1 <= axi_err_a; err_s2 <= err_s1; axi_err <= err_s2;
            bad_s1 <= bad_cmd_a; bad_s2 <= bad_s1; bad_cmd <= bad_s2;
            pwr_s1 <= peak_wr_a; pwr_s2 <= pwr_s1; peak_wr <= pwr_s2;
            prd_s1 <= peak_rd_a; prd_s2 <= prd_s1; peak_rd <= prd_s2;
        end
    end

    // ---------------- write data side (mig_wdf -> W) ----------------------
    reg  [3:0]   wcr;                        // AWs handshaked, burst not yet started
    reg          ld_idx;                     // next mig_wdf entry is #0/#1 of its burst
    reg          wh_valid, wh_half, wh_idx;
    reg  [143:0] wh_data;

    wire w_fire  = m_axi_wvalid && m_axi_wready;
    wire w_slot  = !wh_valid || (w_fire && wh_half);
    assign wdf_rd = wdf_v && w_slot && (ld_idx || (wcr != 4'd0));
    wire aw_hs   = m_axi_awvalid && m_axi_awready;

    assign m_axi_wvalid = wh_valid;
    assign m_axi_wdata  = wh_half ? wh_data[127:64]  : wh_data[63:0];
    assign m_axi_wstrb  = ~(wh_half ? wh_data[143:136] : wh_data[135:128]);
    assign m_axi_wlast  = wh_idx && wh_half;
    assign m_axi_bready = 1'b1;
    assign m_axi_rready = 1'b1;

    // ---------------- read data side (R -> mig_rdf) -----------------------
    reg          rbeat;
    reg  [63:0]  r_lo;

    reg [MAX_WR_OUT-1:0] wtv_n;
    reg [MAX_RD_OUT-1:0] rtv_n;

    always @(posedge axi_clk) begin
        if (axi_rst) begin
            wtv           <= {MAX_WR_OUT{1'b0}};
            rtv           <= {MAX_RD_OUT{1'b0}};
            wt_head       <= 4'd0;
            wt_tail       <= 4'd0;
            rt_head       <= 4'd0;
            rt_tail       <= 4'd0;
            wr_out        <= 4'd0;
            rd_out        <= 4'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_awaddr  <= 32'd0;
            m_axi_araddr  <= 32'd0;
            wcr           <= 4'd0;
            ld_idx        <= 1'b0;
            wh_valid      <= 1'b0;
            wh_half       <= 1'b0;
            wh_idx        <= 1'b0;
            wh_data       <= 144'd0;
            rbeat         <= 1'b0;
            r_lo          <= 64'd0;
            rdf_wr_en     <= 1'b0;
            rdf_din       <= 128'd0;
            axi_err_a       <= 1'b0;
            bad_cmd_a       <= 1'b0;
            peak_wr_a       <= 4'd0;
            peak_rd_a       <= 4'd0;
        end else begin
            if (clr_err_a) begin
                axi_err_a <= 1'b0;
                bad_cmd_a <= 1'b0;
                peak_wr_a <= 4'd0;
                peak_rd_a <= 4'd0;
            end
            // ---- AW / AR issue
            if (aw_hs) m_axi_awvalid <= 1'b0;
            if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
            if (issue_wr) begin
                m_axi_awaddr  <= {blk[31:5], 5'b0};
                m_axi_awvalid <= 1'b1;
            end
            if (issue_rd) begin
                m_axi_araddr  <= {blk[31:5], 5'b0};
                m_axi_arvalid <= 1'b1;
            end
            if (is_bad) bad_cmd_a <= 1'b1;

            // ---- in-flight tags: allocated at issue, freed by the (in-order) response
            wtv_n = wtv;
            rtv_n = rtv;
            if (wr_done) begin
                wtv_n[wt_head] = 1'b0;
                wt_head <= (wt_head == MAX_WR_OUT - 1) ? 4'd0 : wt_head + 4'd1;
            end
            if (rd_done) begin
                rtv_n[rt_head] = 1'b0;
                rt_head <= (rt_head == MAX_RD_OUT - 1) ? 4'd0 : rt_head + 4'd1;
            end
            if (issue_wr) begin
                wtag[wt_tail]   <= hd_tag;
                wtv_n[wt_tail]   = 1'b1;
                wt_tail <= (wt_tail == MAX_WR_OUT - 1) ? 4'd0 : wt_tail + 4'd1;
            end
            if (issue_rd) begin
                rtag[rt_tail]   <= hd_tag;
                rtv_n[rt_tail]   = 1'b1;
                rt_tail <= (rt_tail == MAX_RD_OUT - 1) ? 4'd0 : rt_tail + 4'd1;
            end
            wtv <= wtv_n;
            rtv <= rtv_n;

            // ---- in-flight counters (+ peak tracking)
            wr_out <= wr_out + {3'b0, issue_wr} - {3'b0, wr_done};
            rd_out <= rd_out + {3'b0, issue_rd} - {3'b0, rd_done};
            if (issue_wr && !wr_done && (wr_out + 4'd1 > peak_wr_a) && !clr_err_a)
                peak_wr_a <= wr_out + 4'd1;
            if (issue_rd && !rd_done && (rd_out + 4'd1 > peak_rd_a) && !clr_err_a)
                peak_rd_a <= rd_out + 4'd1;
            if (wr_done && m_axi_bresp != 2'b00) axi_err_a <= 1'b1;

            // ---- W channel
            wcr <= wcr + {3'b0, aw_hs} - {3'b0, (wdf_rd && !ld_idx)};
            if (wdf_rd) begin
                wh_data  <= wdf_d;
                wh_valid <= 1'b1;
                wh_half  <= 1'b0;
                wh_idx   <= ld_idx;
                ld_idx   <= ~ld_idx;
            end else if (w_fire) begin
                if (!wh_half) wh_half  <= 1'b1;
                else          wh_valid <= 1'b0;
            end

            // ---- R channel -> mig_rdf
            rdf_wr_en <= 1'b0;
            if (m_axi_rvalid) begin
                if (m_axi_rresp != 2'b00) axi_err_a <= 1'b1;
                rbeat <= ~rbeat;
                if (!rbeat) begin
                    r_lo <= m_axi_rdata;
                end else begin
                    rdf_din   <= {m_axi_rdata, r_lo};
                    rdf_wr_en <= 1'b1;
                end
            end
            if (rdf_wr_en && rdf_ffull) bad_cmd_a <= 1'b1;   // MIG-style: no back-pressure
        end
    end

endmodule
