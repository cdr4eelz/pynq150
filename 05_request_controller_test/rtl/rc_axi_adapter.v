// rc_axi_adapter: sits exactly where the ML505 DDR2 MIG (mig_v3_61 user
// interface) used to sit under the cs150 RequestController, and masters an
// AXI4 bus (PS7 S_AXI_HP0, 64-bit) instead. There is no MIG model and no
// command/write/read FIFO layer: RequestController's master port is
// connected straight to this module (in cs150 Memory150.v the same port
// went through the mig_caf/mig_wdf/mig_rdf clock-crossing FIFOs to MIG;
// here everything is on one clock, FCLK0).
//
// RequestController master port            MIG v3.61 equivalent
//   caf_full   (out) "!ready"              app_af_afull
//   caf_wren/caf_cadr[33:0] {cmd,addr}     app_af_wren, app_af_cmd, app_af_addr
//   wdf_full   (out) "!ready"              app_wdf_afull
//   wdf_wren/wdf_mdat[143:0] {mask,data}   app_wdf_wren, app_wdf_mask_data, app_wdf_data
//   rdf_wren   (out) one-cycle pulse/beat  rd_data_valid
//   rdf_data   (out) 128 bits              rd_data_fifo_out
//   rdf_rden   (in)  ignored               (MIG has no read-enable; the
//                                           cs150 RDF FIFO did. The waiting
//                                           client always has rden high.)
//
// Like MIG, read data is pushed with no backpressure: each 128-bit beat is
// a single rdf_wren pulse, which is exactly what RequestController's
// serviced_reads counter expects.
//
// Commands: cmd 000 = write (one caf entry + two wdf beats, the second may
// come later), 001 = read (two rdf beats returned). One command is handled
// at a time, in order; a write's BRESP is received before the next command
// is accepted, so read-after-write to the same address is always ordered.
// While busy, caf_full and wdf_full are both high (RequestController ORs
// them into ff_full). Between the two wdf beats of a write, both are low so
// the second beat can enter; a caf_wren then is a protocol error (bad_cmd).
//
// Address: addr is in 8-byte (64-bit DDR word) units, as in Cache.v
// ({6'b0, line_addr, 2'b0}). One command = BL4 x 64 bits = 32 bytes.
// addr[1:0] is forced to 0, so a command is one 32-byte-aligned block (never
// crosses 4 KB). The block goes to base_addr + {addr[WIN_AW-4:2], 5'b0}:
// addresses wrap inside a 2**WIN_AW-byte window at base_addr, so the PL
// cannot write outside the holder's CMA buffer (base_addr[4:0] ignored).
//
// Data layout: wdf beat 0 -> bytes +0..+15 of the block, beat 1 -> +16..+31
// (first MIG beat = lowest DDR address). In a 128-bit beat data[63:0] is the
// lower AXI beat; mask bit i (active high = do NOT write) covers data byte
// i, so WSTRB = ~mask. Reads return the same order.
module rc_axi_adapter #(
    parameter WIN_AW = 20                // window size = 2**WIN_AW bytes
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [31:0]   base_addr,
    input  wire          clr_err,
    output reg           axi_err,        // sticky: BRESP/RRESP != OKAY
    output reg           bad_cmd,        // sticky: unknown cmd / protocol error

    // RequestController master port (MIG-style)
    output wire          caf_full,
    input  wire          caf_wren,
    input  wire [33:0]   caf_cadr,
    output wire          wdf_full,
    input  wire          wdf_wren,
    input  wire [143:0]  wdf_mdat,
    output reg           rdf_wren,
    output reg  [127:0]  rdf_data,
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

    localparam S_IDLE = 3'd0,   // ready for a command (+ first wdf beat)
               S_WD2  = 3'd1,   // write: waiting for the second wdf beat
               S_AW   = 3'd2,
               S_W    = 3'd3,
               S_B    = 3'd4,
               S_AR   = 3'd5,
               S_R    = 3'd6;

    reg [2:0]   st;
    reg [1:0]   beat;
    reg [143:0] wd0, wd1;            // the two {mask,data} beats of a write
    reg [63:0]  r_lo;

    wire [2:0]  cmd = caf_cadr[33:31];
    wire [31:0] blk = base_addr +
                      {{(32-WIN_AW){1'b0}}, caf_cadr[WIN_AW-4:2], 5'b00000};

    wire ready_in = (st == S_IDLE) || (st == S_WD2);
    assign caf_full = !ready_in;
    assign wdf_full = !ready_in;

    wire [143:0] wd_cur = beat[1] ? wd1 : wd0;
    assign m_axi_wvalid = (st == S_W);
    assign m_axi_wlast  = (beat == 2'd3);
    assign m_axi_wdata  = beat[0] ? wd_cur[127:64]  : wd_cur[63:0];
    assign m_axi_wstrb  = ~(beat[0] ? wd_cur[143:136] : wd_cur[135:128]);
    assign m_axi_bready = (st == S_B);
    assign m_axi_rready = (st == S_R);

    always @(posedge clk) begin
        rdf_wren <= 1'b0;
        if (rst) begin
            st            <= S_IDLE;
            beat          <= 2'd0;
            wd0           <= 144'd0;
            wd1           <= 144'd0;
            r_lo          <= 64'd0;
            rdf_data      <= 128'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_awaddr  <= 32'd0;
            m_axi_araddr  <= 32'd0;
            axi_err       <= 1'b0;
            bad_cmd       <= 1'b0;
        end else begin
            if (clr_err) begin
                axi_err <= 1'b0;
                bad_cmd <= 1'b0;
            end
            case (st)
            S_IDLE: begin
                beat <= 2'd0;
                if (caf_wren) begin
                    if (cmd == 3'b000) begin
                        m_axi_awaddr <= {blk[31:5], 5'b0};
                        if (wdf_wren) begin
                            wd0 <= wdf_mdat;
                            st  <= S_WD2;
                        end else begin
                            bad_cmd <= 1'b1;     // write cmd without data
                        end
                    end else if (cmd == 3'b001) begin
                        m_axi_araddr  <= {blk[31:5], 5'b0};
                        m_axi_arvalid <= 1'b1;
                        st            <= S_AR;
                    end else begin
                        bad_cmd <= 1'b1;
                    end
                end else if (wdf_wren) begin
                    bad_cmd <= 1'b1;             // data without a command
                end
            end
            S_WD2: begin
                if (caf_wren)
                    bad_cmd <= 1'b1;             // cmd inside a write pair
                if (wdf_wren) begin
                    wd1           <= wdf_mdat;
                    m_axi_awvalid <= 1'b1;
                    st            <= S_AW;
                end
            end
            S_AW: if (m_axi_awready) begin
                m_axi_awvalid <= 1'b0;
                st            <= S_W;
            end
            S_W: if (m_axi_wready) begin
                beat <= beat + 2'd1;
                if (beat == 2'd3)
                    st <= S_B;
            end
            S_B: if (m_axi_bvalid) begin
                if (m_axi_bresp != 2'b00) axi_err <= 1'b1;
                st <= S_IDLE;
            end
            S_AR: if (m_axi_arready) begin
                m_axi_arvalid <= 1'b0;
                st            <= S_R;
            end
            S_R: if (m_axi_rvalid) begin
                if (m_axi_rresp != 2'b00) axi_err <= 1'b1;
                beat <= beat + 2'd1;
                if (!beat[0]) begin
                    r_lo <= m_axi_rdata;
                end else begin
                    rdf_data <= {m_axi_rdata, r_lo};
                    rdf_wren <= 1'b1;            // like MIG rd_data_valid
                end
                if (m_axi_rlast)
                    st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
