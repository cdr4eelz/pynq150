// cache_ex: the cs150 instruction and data caches (two instances of the
// unmodified cs150 Cache.v, LITTLEWORDIAN=1) as the inst_* and data_* clients
// of the cs150 RequestController, plus a small sequencer that runs one UART
// cache command at a time against them.
//
// CPU-side handshake used for every access (matches how Cache.v samples its
// inputs: it latches addr/din/we/re on every cycle in which ns == IDLE):
//   ISSUE  (1 cycle) drive addr, din, re or we on the selected cache
//   WAIT   drive re = we = 0, keep addr; the first WAIT cycle samples tag_hit
//          (hit for reads and writes); finish in the first cycle stall == 0,
//          when dout is valid (read hit: first WAIT cycle; read miss: the
//          CWRITEB cycle; write: the WRITE2 -> IDLE cycle)
//   NEXT   one idle cycle, then the next access
// cyc = cycles in WAIT (read hit = 1).
//
// Ops (addresses are window-relative byte addresses, [1:0] forced 0):
//   OP_DR   D-cache read  count words at addr, addr+4, ...
//   OP_JR   I-cache read  count words
//   OP_DW   D-cache write one word (we = 4'hF)
//   OP_FILL D-cache write count words, word i = data + i
//   OP_VER  D-cache read  count words, compare word i with data + i (stop at
//           the first mismatch)
//   OP_E    D read A^0x2000 (evict A's index), D write A (write miss: no
//           allocate), D read A (re-miss -> DDR fetch right behind the write);
//           compare with data
//   OP_EX   D read A (fill), D write A (hit, write-through), D read A^0x2000
//           (conflict miss replaces the line), D read A (re-miss); compare
//   OP_O    I read A^0x2000 (evict), D write A, I read A at once; compare
// The cs150 Cache is write-through and never dirty, so OP_E / OP_O are the
// "write then same-line re-miss" races the adapter has to order.
module cache_ex (
    input  wire          clk,
    input  wire          rst,
    // command
    input  wire          start,
    input  wire [2:0]    op,
    input  wire [31:0]   addr,
    input  wire [31:0]   data,
    input  wire [31:0]   count,
    input  wire          clr_cnt,
    output wire          busy,
    output reg           done,
    // results of the last command
    output reg  [31:0]   r_first,       // loops: first word read; DW: unused
    output reg  [31:0]   r_last,
    output reg           r_hit_first,   // hit of the first (or only) access
    output reg  [31:0]   r_cyc_first,
    output reg  [31:0]   r_hits,        // hits / misses within this command
    output reg  [31:0]   r_miss,
    output reg           r_pass,        // VER / E / EX / O
    output reg  [31:0]   r_got,
    output reg  [31:0]   r_exp,
    output reg  [31:0]   r_faddr,
    output reg  [31:0]   r_cyc_a,       // E / EX / O: write cycles
    output reg  [31:0]   r_cyc_b,       //             final read cycles
    output reg           r_final_miss,  //             final read missed (valid race test)
    // running counters (clr_cnt clears)
    output reg  [31:0]   cnt_ih, cnt_im, cnt_ic,
    output reg  [31:0]   cnt_dh, cnt_dm, cnt_dc,
    // RequestController inst_* / data_* ports
    output wire          inst_caf_wren,
    output wire [33:0]   inst_caf_cadr,
    output wire          inst_wdf_wren,
    output wire [143:0]  inst_wdf_mdat,
    output wire          inst_rdf_rden,
    output wire          inst_stall,
    input  wire          inst_caf_full,
    input  wire          inst_wdf_full,
    input  wire          inst_rdf_wren,
    output wire          data_caf_wren,
    output wire [33:0]   data_caf_cadr,
    output wire          data_wdf_wren,
    output wire [143:0]  data_wdf_mdat,
    output wire          data_rdf_rden,
    output wire          data_stall,
    input  wire          data_caf_full,
    input  wire          data_wdf_full,
    input  wire          data_rdf_wren,
    input  wire [127:0]  rdf_data
);
    localparam OP_DR = 3'd0, OP_JR = 3'd1, OP_DW = 3'd2, OP_FILL = 3'd3,
               OP_VER = 3'd4, OP_E = 3'd5, OP_EX = 3'd6, OP_O = 3'd7;
    localparam [31:0] CONFLICT = 32'h0000_2000;   // 8 KiB: same index, other tag

    localparam S_IDLE = 2'd0, S_ISSUE = 2'd1, S_WAIT = 2'd2, S_NEXT = 2'd3;
    reg  [1:0]  st;
    reg  [2:0]  o;
    reg  [31:0] a0, d0, n0, i;
    reg  [1:0]  s;                               // step within E / EX / O
    reg  [31:0] cyc;
    reg         first_w, hit_c;

    // ---- current access (combinational from op / step / index)
    reg         c_sel_i, c_we, c_check, c_last;
    reg  [31:0] c_addr, c_din;
    always @(*) begin
        c_sel_i = 1'b0; c_we = 1'b0; c_check = 1'b0; c_last = 1'b0;
        c_addr  = a0;   c_din = d0;
        case (o)
        OP_DR, OP_VER: begin c_addr = a0 + {i[29:0], 2'b00}; c_last = (i + 32'd1 == n0); end
        OP_JR:   begin c_sel_i = 1'b1; c_addr = a0 + {i[29:0], 2'b00}; c_last = (i + 32'd1 == n0); end
        OP_DW:   begin c_we = 1'b1; c_last = 1'b1; end
        OP_FILL: begin c_we = 1'b1; c_addr = a0 + {i[29:0], 2'b00}; c_din = d0 + i;
                       c_last = (i + 32'd1 == n0); end
        OP_E: case (s)
            2'd0: c_addr = a0 ^ CONFLICT;
            2'd1: c_we = 1'b1;
            default: begin c_check = 1'b1; c_last = 1'b1; end
            endcase
        OP_EX: case (s)
            2'd0: ;
            2'd1: c_we = 1'b1;
            2'd2: c_addr = a0 ^ CONFLICT;
            default: begin c_check = 1'b1; c_last = 1'b1; end
            endcase
        OP_O: case (s)
            2'd0: begin c_sel_i = 1'b1; c_addr = a0 ^ CONFLICT; end
            2'd1: c_we = 1'b1;
            default: begin c_sel_i = 1'b1; c_check = 1'b1; c_last = 1'b1; end
            endcase
        default: c_last = 1'b1;
        endcase
        c_addr[1:0] = 2'b00;
    end

    // ---- the two caches
    wire        issue = (st == S_ISSUE);
    wire        i_stall, d_stall, i_hit, d_hit;
    wire [31:0] i_dout, d_dout;

    Cache #(.LITTLEWORDIAN(1)) icache (
        .clk(clk), .rst(rst),
        .addr(c_addr), .din(32'd0), .we(4'b0000), .re(issue && c_sel_i),
        .caf_full(inst_caf_full), .wdf_full(inst_wdf_full),
        .rdf_wren(inst_rdf_wren), .rdf_data(rdf_data),
        .stall(i_stall), .dout(i_dout), .rdf_rden(inst_rdf_rden),
        .caf_cadr(inst_caf_cadr), .caf_wren(inst_caf_wren),
        .wdf_mdat(inst_wdf_mdat), .wdf_wren(inst_wdf_wren),
        .tag_hit(i_hit), .tag_valid(), .state());

    Cache #(.LITTLEWORDIAN(1)) dcache (
        .clk(clk), .rst(rst),
        .addr(c_addr), .din(c_din), .we((issue && !c_sel_i && c_we) ? 4'hF : 4'h0),
        .re(issue && !c_sel_i && !c_we),
        .caf_full(data_caf_full), .wdf_full(data_wdf_full),
        .rdf_wren(data_rdf_wren), .rdf_data(rdf_data),
        .stall(d_stall), .dout(d_dout), .rdf_rden(data_rdf_rden),
        .caf_cadr(data_caf_cadr), .caf_wren(data_caf_wren),
        .wdf_mdat(data_wdf_mdat), .wdf_wren(data_wdf_wren),
        .tag_hit(d_hit), .tag_valid(), .state());

    assign inst_stall = i_stall;
    assign data_stall = d_stall;

    wire        sel_stall = c_sel_i ? i_stall : d_stall;
    wire        sel_hit   = c_sel_i ? i_hit   : d_hit;
    wire [31:0] sel_dout  = c_sel_i ? i_dout  : d_dout;
    wire        hit_now   = first_w ? sel_hit : hit_c;   // hit of this access
    wire [31:0] cyc_now   = cyc + 32'd1;

    assign busy = (st != S_IDLE);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; o <= 3'd0; a0 <= 32'd0; d0 <= 32'd0; n0 <= 32'd1; i <= 32'd0; s <= 2'd0;
            cyc <= 32'd0; first_w <= 1'b0; hit_c <= 1'b0;
            r_first <= 32'd0; r_last <= 32'd0; r_hit_first <= 1'b0; r_cyc_first <= 32'd0;
            r_hits <= 32'd0; r_miss <= 32'd0; r_pass <= 1'b0; r_got <= 32'd0; r_exp <= 32'd0;
            r_faddr <= 32'd0; r_cyc_a <= 32'd0; r_cyc_b <= 32'd0; r_final_miss <= 1'b0;
            cnt_ih <= 32'd0; cnt_im <= 32'd0; cnt_ic <= 32'd0;
            cnt_dh <= 32'd0; cnt_dm <= 32'd0; cnt_dc <= 32'd0;
        end else begin
            if (clr_cnt) begin
                cnt_ih <= 32'd0; cnt_im <= 32'd0; cnt_ic <= 32'd0;
                cnt_dh <= 32'd0; cnt_dm <= 32'd0; cnt_dc <= 32'd0;
            end
            case (st)
            S_IDLE: if (start) begin
                o <= op; a0 <= addr; d0 <= data; n0 <= (count == 32'd0) ? 32'd1 : count;
                i <= 32'd0; s <= 2'd0;
                r_hits <= 32'd0; r_miss <= 32'd0; r_pass <= 1'b1;
                r_got <= 32'd0; r_exp <= 32'd0; r_faddr <= 32'd0;
                r_cyc_a <= 32'd0; r_cyc_b <= 32'd0; r_final_miss <= 1'b0;
                st <= S_ISSUE;
            end
            S_ISSUE: begin
                cyc <= 32'd0; first_w <= 1'b1;
                st <= S_WAIT;
            end
            S_WAIT: begin
                first_w <= 1'b0;
                if (first_w) hit_c <= sel_hit;
                cyc <= cyc_now;
                if (!sel_stall) begin
                    // counters
                    if (c_sel_i) begin
                        if (hit_now) cnt_ih <= cnt_ih + 32'd1; else cnt_im <= cnt_im + 32'd1;
                        cnt_ic <= cnt_ic + cyc_now;
                    end else begin
                        if (hit_now) cnt_dh <= cnt_dh + 32'd1; else cnt_dm <= cnt_dm + 32'd1;
                        cnt_dc <= cnt_dc + cyc_now;
                    end
                    if (hit_now) r_hits <= r_hits + 32'd1; else r_miss <= r_miss + 32'd1;
                    if (i == 32'd0 && s == 2'd0) begin
                        r_first <= sel_dout; r_hit_first <= hit_now; r_cyc_first <= cyc_now;
                    end
                    r_last <= sel_dout;
                    if (c_we && (o == OP_E || o == OP_EX || o == OP_O)) r_cyc_a <= cyc_now;
                    if (o == OP_VER && sel_dout != d0 + i) begin
                        r_pass <= 1'b0; r_got <= sel_dout; r_exp <= d0 + i; r_faddr <= c_addr;
                    end
                    if (c_check) begin
                        r_cyc_b <= cyc_now; r_got <= sel_dout; r_exp <= d0; r_faddr <= c_addr;
                        r_final_miss <= !hit_now;
                        r_pass <= (sel_dout == d0);
                    end
                    if (c_last || (o == OP_VER && sel_dout != d0 + i)) begin
                        done <= 1'b1;
                        st   <= S_IDLE;
                    end else
                        st <= S_NEXT;
                end
            end
            S_NEXT: begin
                if (o == OP_E || o == OP_EX || o == OP_O) s <= s + 2'd1;
                else i <= i + 32'd1;
                st <= S_ISSUE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
