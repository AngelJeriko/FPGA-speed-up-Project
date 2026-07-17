// ref_fetch_top.sv — Decision A1 of docs/genome_fetch_options.md: the on-chip reference-window
// fetch. It REPLACES THE HOST behind the existing ref_req/ref_in_* seam — the interface
// chaining_extend_top already raises when a chain's (clamped) window is ready. Instead of the host
// streaming the bytes back, this engine reads them from an HBM-resident byte array and streams them
// on ref_in_*, unchanged.
//
// Why this is a flat byte read (§3.3): BWA-MEM2 pre-materialises the whole 2*l_pac coordinate space
// at ONE BYTE PER BASE into the .0123 array (forward AND reverse-complement already spelled out), so
// bns_get_seq_v2 reduces to `seq = ref_string + beg`. On chip that means: read ref_len bytes starting
// at byte address ref_rbeg. No unpack, no mirror, no complement — those would be needed only for the
// packed .pac layout (Decision A2, a later measured follow-up). The window is already contig-clamped
// upstream by bns_clamp_top, so ref_rbeg/ref_len never run off a contig.
//
// This is the D1 (blocking, single-outstanding) bring-up: issue one byte read, wait, stream it, next.
// It is functionally exact but latency-bound; Decision D2 keeps many reads in flight (prefetch on
// rmax) to hide the latency. The memory port is a simple in-order read (valid/ready) to keep D2/D3
// and the real AXI/HBM adapter a drop-in behind it.
`include "bsw_pkg.sv"

module ref_fetch_top
    import bsw_pkg::*;
(
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

    // ---- HBM read master: simple in-order byte read (valid/ready) ----
    output logic               mem_arvalid,   // read-address valid
    output logic signed [63:0] mem_araddr,    // byte address into the .0123 array
    input  logic               mem_arready,   // memory accepts the address
    input  logic [7:0]         mem_rdata,     // returned byte (base 0..4)
    input  logic               mem_rvalid     // rdata valid (one per accepted address, in order)
);
    typedef enum logic [2:0] { F_IDLE, F_AR, F_R, F_DONE, F_SETTLE } st_t;
    st_t state;

    logic signed [63:0] rbeg;
    logic [15:0]        len, cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= F_IDLE;
            ref_in_en <= 1'b0; ref_in_done <= 1'b0; mem_arvalid <= 1'b0;
        end else begin
            ref_in_en   <= 1'b0;      // one-cycle strobes by default
            ref_in_done <= 1'b0;
            case (state)
                F_IDLE: begin
                    mem_arvalid <= 1'b0;
                    if (ref_req) begin
                        rbeg <= ref_rbeg; len <= ref_len; cnt <= 16'd0;
                        if (ref_len == 16'd0) state <= F_DONE;   // empty window (e.g. bridging): no bytes
                        else                  state <= F_AR;
                    end
                end
                F_AR: begin                                      // present the byte address
                    mem_arvalid <= 1'b1;
                    mem_araddr  <= rbeg + $signed({48'd0, cnt});
                    if (mem_arvalid && mem_arready) begin         // accepted
                        mem_arvalid <= 1'b0;
                        state <= F_R;
                    end
                end
                F_R: if (mem_rvalid) begin                        // capture + stream the byte
                    ref_in_en   <= 1'b1;
                    ref_in_addr <= cnt;
                    ref_in_data <= base_t'(mem_rdata[BASE_WIDTH-1:0]);
                    cnt <= cnt + 16'd1;
                    state <= (cnt + 16'd1 >= len) ? F_DONE : F_AR;
                end
                F_DONE: begin ref_in_done <= 1'b1; state <= F_SETTLE; end
                F_SETTLE: if (!ref_req) state <= F_IDLE;          // wait for the request to drop
                default: state <= F_IDLE;
            endcase
        end
    end
endmodule
