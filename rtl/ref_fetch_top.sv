// ref_fetch_top.sv — Decision A1 + D2 of docs/genome_fetch_options.md: the on-chip reference-window
// fetch, with the memory reads PIPELINED (D2 — hide the latency).
//
// It REPLACES THE HOST behind the existing ref_req/ref_in_* seam. Because BWA-MEM2 pre-materialises
// the whole 2*l_pac coordinate space at ONE BYTE PER BASE in .0123 (fwd+RC spelled out), the fetch is
// a flat byte read: read ref_len bytes at byte address ref_rbeg — no unpack/mirror/complement (those
// are only for the packed .pac layout, Decision A2). The window is already contig-clamped by
// bns_clamp_top upstream, so the address never runs off a contig.
//
// D2 — WHY PIPELINED. The naive A1 (D1) was single-outstanding: issue one byte address, stall for the
// whole memory round trip, then issue the next. A ~280-byte window then costs ~280 * latency — the
// blocking cost is exactly what moving the genome on chip was meant to remove. Here the engine keeps
// up to DEPTH reads IN FLIGHT: it issues addresses back-to-back (as fast as mem_arready allows) and
// collects the replies in order. With DEPTH >= memory latency the pipe stays full, so a window costs
// ~latency + len cycles (≈ 1 byte/cycle) instead of len * latency. Bandwidth is <1% of HBM (measured),
// so byte-granular pipelined reads are fine — bursting (wider reads) is an optional later optimisation.
// Cross-chain prefetch (issue chain k+1's window during chain k's Smith-Waterman) is the remaining D2
// step and builds on this same memory port.
//
// The memory port is a simple IN-ORDER read (valid/ready): responses return in request order, so the
// j-th reply is byte j of the window. A real AXI/HBM read adapter (in-order, or reordered by id) drops
// in behind this port unchanged.
`include "bsw_pkg.sv"

module ref_fetch_top
    import bsw_pkg::*;
#(
    parameter int DEPTH = 32           // max outstanding reads; set >= memory latency to stay full
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- request from chaining_extend_top (ref_req held until ref_in_done) ----
    input  logic               ref_req,
    input  logic signed [63:0] ref_rbeg,
    input  logic [15:0]        ref_len,

    // ---- byte stream back to chaining_extend_top (drives its ref_in_* / accel r_ld) ----
    output logic               ref_in_en,
    output logic [15:0]        ref_in_addr,
    output base_t              ref_in_data,
    output logic               ref_in_done,

    // ---- HBM read master: simple in-order read (valid/ready), one reply per accepted address ----
    output logic               mem_arvalid,   // read-address valid
    output logic signed [63:0] mem_araddr,    // byte address into the .0123 array
    input  logic               mem_arready,   // memory accepts the address
    input  logic [7:0]         mem_rdata,     // returned byte (base 0..4), in request order
    input  logic               mem_rvalid     // rdata valid
);
    typedef enum logic [1:0] { F_IDLE, F_ACTIVE, F_DONE, F_SETTLE } st_t;
    st_t state;

    logic signed [63:0] rbeg;
    logic [15:0]        len, i_issue, i_recv;      // addresses issued / replies collected

    // Keep the read pipe full: present the next address whenever there is one to issue and fewer than
    // DEPTH are outstanding. mem_araddr walks rbeg + i_issue; i_issue advances only on an accepted beat.
    wire [15:0] outstanding = i_issue - i_recv;
    assign mem_arvalid = (state == F_ACTIVE) && (i_issue < len) && (outstanding < DEPTH[15:0]);
    assign mem_araddr  = rbeg + $signed({48'd0, i_issue});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= F_IDLE; i_issue <= 16'd0; i_recv <= 16'd0;
            ref_in_en <= 1'b0; ref_in_done <= 1'b0;
        end else begin
            ref_in_en   <= 1'b0;
            ref_in_done <= 1'b0;
            case (state)
                F_IDLE: if (ref_req) begin
                    rbeg <= ref_rbeg; len <= ref_len; i_issue <= 16'd0; i_recv <= 16'd0;
                    state <= (ref_len == 16'd0) ? F_DONE : F_ACTIVE;   // empty window: no bytes
                end
                F_ACTIVE: begin
                    if (mem_arvalid && mem_arready) i_issue <= i_issue + 16'd1;   // address accepted
                    if (mem_rvalid) begin                                          // reply (in order)
                        ref_in_en   <= 1'b1;
                        ref_in_addr <= i_recv;
                        ref_in_data <= base_t'(mem_rdata[BASE_WIDTH-1:0]);
                        i_recv <= i_recv + 16'd1;
                        if (i_recv + 16'd1 == len) state <= F_DONE;               // last byte collected
                    end
                end
                F_DONE:   begin ref_in_done <= 1'b1; state <= F_SETTLE; end
                F_SETTLE: if (!ref_req) state <= F_IDLE;
                default:  state <= F_IDLE;
            endcase
        end
    end
endmodule
