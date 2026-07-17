// tb_ref_fetch_top.sv — self-checking TB for ref_fetch_top (Decision A1 on-chip byte fetch).
// Models the HBM byte array with g(addr)=addr&3 — the SAME function the host ref-server streams in
// tb_chaining_extend_top — and checks that for each request {rbeg,len} the engine emits exactly len
// bytes with ref_in_addr = 0..len-1 and ref_in_data = (rbeg+i)&3, then pulses ref_in_done. If this
// is bit-exact, dropping ref_fetch_top in behind the ref_req/ref_in_* seam reproduces the host's
// byte stream and the whole pipeline is unchanged (verified separately in tb_chaining_extend_fetch).
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_ref_fetch_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic               ref_req; logic signed [63:0] ref_rbeg; logic [15:0] ref_len;
    logic               ref_in_en; logic [15:0] ref_in_addr; base_t ref_in_data; logic ref_in_done;
    logic               mem_arvalid; logic signed [63:0] mem_araddr;
    logic               mem_arready; logic [7:0] mem_rdata; logic mem_rvalid;

    ref_fetch_top dut(.clk,.rst_n,
        .ref_req,.ref_rbeg,.ref_len,
        .ref_in_en,.ref_in_addr,.ref_in_data,.ref_in_done,
        .mem_arvalid,.mem_araddr,.mem_arready,.mem_rdata,.mem_rvalid);

    // ---- HBM model: PIPELINED in-order read, fixed latency MEM_LAT, one accept/cycle, g(addr)=addr&3.
    //      Multiple reads in flight (a delay line) — this is what lets ref_fetch_top's outstanding
    //      reads actually overlap. A single-outstanding model would hide the D2 speedup. ----
    localparam int MEM_LAT = 8;
    logic       pv [MEM_LAT];
    logic [1:0] pa [MEM_LAT];
    integer pi;
    assign mem_arready = 1'b1;                         // always accept: 1 address/cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rvalid<=1'b0; mem_rdata<=8'd0;
            for (pi=0; pi<MEM_LAT; pi=pi+1) pv[pi]<=1'b0;
        end else begin
            for (pi=MEM_LAT-1; pi>0; pi=pi-1) begin pv[pi]<=pv[pi-1]; pa[pi]<=pa[pi-1]; end
            pv[0] <= (mem_arvalid && mem_arready);
            pa[0] <= mem_araddr[1:0];
            mem_rvalid <= pv[MEM_LAT-1];
            mem_rdata  <= {6'd0, pa[MEM_LAT-1]};
        end
    end

    // free-running cycle counter for fetch-latency measurement
    integer cyc; always_ff @(posedge clk or negedge rst_n) if(!rst_n) cyc<=0; else cyc<=cyc+1;
    integer tot_cyc, tot_bytes, big_cyc;

    // ---- collect one request's stream and check it ----
    integer nbytes; logic signed [63:0] cur_rbeg; integer fails, checks, guard;
    logic [2:0] got_data [0:2047]; integer got_addr [0:2047];

    task automatic do_request(input longint rbeg, input int len);
        integer i; logic ok; integer t0, t1;
        begin
            cur_rbeg = rbeg; nbytes = 0;
            @(posedge clk); ref_rbeg<=rbeg; ref_len<=len[15:0]; ref_req<=1'b1; t0=cyc;
            // collect until done
            guard=0;
            while (!ref_in_done && guard<20000) begin
                @(posedge clk);
                if (ref_in_en) begin got_addr[nbytes]=ref_in_addr; got_data[nbytes]=ref_in_data; nbytes=nbytes+1; end
                guard=guard+1;
            end
            t1=cyc; tot_cyc=tot_cyc+(t1-t0); tot_bytes=tot_bytes+len;
            if (len==811) big_cyc=t1-t0;                 // the max real window, for the report
            @(posedge clk); ref_req<=1'b0;               // release; engine settles on !ref_req
            @(posedge clk); @(posedge clk);
            // check
            ok = (nbytes == len);
            for (i=0; i<len; i=i+1) begin
                if (got_addr[i] !== i)                      ok = 1'b0;
                if (got_data[i] !== ((rbeg + i) & 64'd3))   ok = 1'b0;
            end
            checks = checks + 1;
            if (!ok) begin
                fails = fails + 1;
                if (fails<=15) $display("FAIL rbeg=%0d len=%0d: got %0d bytes (want %0d)", rbeg, len, nbytes, len);
            end
        end
    endtask

    // ---- deterministic pseudo-random driver ----
    integer t; longint rbeg; int len; longint lfsr;
    initial begin
        ref_req=0; ref_rbeg=0; ref_len=0; fails=0; checks=0; lfsr=64'h1234_5678_9abc_def1;
        tot_cyc=0; tot_bytes=0; big_cyc=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        // directed edges
        do_request(64'd0,      1);
        do_request(64'd0,      0);          // empty window: 0 bytes, immediate done
        do_request(64'd1000,   811);        // max real window
        do_request(64'sd17179869183, 130);  // near 2*l_pac(chr1-5)≈2.12e9 region, large address

        // randomized
        for (t=0; t<600; t=t+1) begin
            lfsr = lfsr*64'd6364136223846793005 + 64'd1442695040888963407;
            rbeg = (lfsr >> 20) & 64'h7_FFFF_FFFF;         // 0 .. ~2^35
            lfsr = lfsr*64'd6364136223846793005 + 64'd1442695040888963407;
            len  = 1 + ((lfsr >> 33) % 811);               // 1..811
            do_request(rbeg, len);
        end

        // D2 evidence: pipelined reads -> ~1 cycle/byte + a fixed latency amortised over the window.
        // Single-outstanding (D1) would be ~ (MEM_LAT+overhead) cycles PER byte.
        $display("tb_ref_fetch_top: fetch cost mem_lat=%0d: %0d bytes in %0d cyc = %0d.%02d cyc/byte; 811B window = %0d cyc",
                 MEM_LAT, tot_bytes, tot_cyc, tot_cyc/tot_bytes, (tot_cyc*100/tot_bytes)%100, big_cyc);
        $display("tb_ref_fetch_top: %0d checks, %0d failures -> %s", checks, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #50000000; $display("[FATAL] timeout"); $finish; end
endmodule
