// dcache_tester: a fake data cache for the cs150 RequestController's
// "data_*" port. It drives exactly the handshake of cs150
// hardware/src/base_mem/Cache.v (states WRITE1/WRITE2/FETCH/READ1/READ2):
//
//   WRITE1  caf_wren=1, caf_cadr={3'b000, addr}, wdf_wren=1,
//           wdf_mdat={mask, line[255:128]}; leave when !caf_full && !wdf_full
//   WRITE2  wdf_wren=1, wdf_mdat={mask, line[127:0]}; leave when !wdf_full
//   FETCH   caf_wren=1, caf_cadr={3'b001, addr}; leave when !caf_full
//   READ1   rdf_rden=1; on rdf_wren capture line[255:128]
//   READ2   rdf_rden=1; on rdf_wren capture line[127:0] (CWRITEB in Cache.v)
//
// addr = {6'b0, line_index[22:0], 2'b0} like Cache.v's f_addr (8-byte
// units, 32-byte lines). Writes are full lines (mask 16'h0000 = all bytes
// written; MIG mask is active-high "do not write").
//
// start_w writes LINES lines of the pattern for `seed`; start_r reads them
// back and compares every line. done pulses when finished.
//
// Pattern, 32-bit word k (0..7, bits [32k+31:32k]) of line i:
//   v = {i[28:0], k[2:0]} ^ {4{seed}};  word = k[0] ? ~v : v
module dcache_tester #(
    parameter LINES = 32768
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start_w,
    input  wire          start_r,
    input  wire [7:0]    seed,
    output reg           done,
    output wire          busy,
    output reg  [31:0]   mism,           // mismatching lines in the last read
    output reg  [31:0]   first_bad,      // first mismatching line index

    // RequestController data_* port (directions as seen by the cache)
    output wire          caf_wren,
    output wire [33:0]   caf_cadr,
    input  wire          caf_full,
    output wire          wdf_wren,
    output wire [143:0]  wdf_mdat,
    input  wire          wdf_full,
    output wire          rdf_rden,
    input  wire          rdf_wren,
    input  wire [127:0]  rdf_data
);

    localparam IDLE = 3'd0, WRITE1 = 3'd1, WRITE2 = 3'd2, FETCH = 3'd3,
               READ1 = 3'd4, READ2 = 3'd5;

    reg [2:0]   cs;
    reg [31:0]  li;
    reg [127:0] first_read;

    function [255:0] line_pat;
        input [31:0] i;
        input [7:0]  s;
        integer k;
        reg [31:0] v;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                v = {i[28:0], k[2:0]} ^ {4{s}};
                line_pat[32*k +: 32] = k[0] ? ~v : v;
            end
        end
    endfunction

    wire [255:0] line = line_pat(li, seed);
    wire [30:0]  f_addr = {6'b0, li[22:0], 2'b0};

    assign busy     = (cs != IDLE);
    assign caf_wren = (cs == WRITE1) || (cs == FETCH);
    assign caf_cadr = {((cs == WRITE1) ? 3'b000 : 3'b001), f_addr};
    assign wdf_wren = (cs == WRITE1) || (cs == WRITE2);
    assign wdf_mdat = (cs == WRITE1) ? {16'h0000, line[255:128]}
                                     : {16'h0000, line[127:0]};
    assign rdf_rden = (cs == READ1) || (cs == READ2);

    wire last = (li == LINES - 1);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            cs         <= IDLE;
            li         <= 32'd0;
            mism       <= 32'd0;
            first_bad  <= 32'd0;
            first_read <= 128'd0;
        end else begin
            case (cs)
            IDLE: begin
                li <= 32'd0;
                if (start_w)
                    cs <= WRITE1;
                else if (start_r) begin
                    mism      <= 32'd0;
                    first_bad <= 32'd0;
                    cs        <= FETCH;
                end
            end
            WRITE1: if (!wdf_full && !caf_full) cs <= WRITE2;
            WRITE2: if (!wdf_full) begin
                if (last) begin
                    cs   <= IDLE;
                    done <= 1'b1;
                end else begin
                    li <= li + 32'd1;
                    cs <= WRITE1;
                end
            end
            FETCH: if (!caf_full) cs <= READ1;
            READ1: if (rdf_wren) begin
                first_read <= rdf_data;
                cs         <= READ2;
            end
            READ2: if (rdf_wren) begin
                if ({first_read, rdf_data} != line) begin
                    if (mism == 32'd0) first_bad <= li;
                    mism <= mism + 32'd1;
                end
                if (last) begin
                    cs   <= IDLE;
                    done <= 1'b1;
                end else begin
                    li <= li + 32'd1;
                    cs <= FETCH;
                end
            end
            default: cs <= IDLE;
            endcase
        end
    end

endmodule
