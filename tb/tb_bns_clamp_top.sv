// tb_bns_clamp_top.sv — self-checking TB for bns_clamp_top (the C2 contig clamp). Loads each
// block's contig table, then drives every (beg_in, midpos, end_in) record and checks
// beg_out/end_out/rid/is_rev/len bit-exact vs gen_clamp_vectors (= bns_clamp.h, itself proven
// bit-exact vs real bwa-mem2: 400k real chr1-5 + 16 synthetic firing events). Multiple blocks
// exercise the synthetic firing table, a deep 64-contig table (full binary-search depth), and —
// when present — the real chr1-5 distribution.
`timescale 1ns/1ps

module tb_bns_clamp_top ();
    localparam int NCTG = 128;
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        tbl_we; logic [15:0] tbl_idx; logic signed [63:0] tbl_offset, tbl_len;
    logic [15:0] n_seqs; logic signed [63:0] l_pac;
    logic        start;  logic signed [63:0] beg_in, midpos, end_in;
    logic        done;   logic signed [63:0] beg_out, end_out, out_len;
    logic [31:0] rid;    logic is_rev;

    bns_clamp_top #(.NCTG(NCTG)) dut(.clk,.rst_n,
        .tbl_we,.tbl_idx,.tbl_offset,.tbl_len,.n_seqs,.l_pac,
        .start,.beg_in,.midpos,.end_in,
        .done,.beg_out,.end_out,.rid,.is_rev,.out_len);

    integer fd, got, nb, b, i, ncontig, nrec, r, guard, fails, checks;
    longint lpac_v, off_v, len_v, bi, mi, ei, bo, eo, ln;
    integer rd_v, rev_v;
    string  path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/clamp_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        tbl_we=0; start=0; fails=0; checks=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d", nb);
        for (b=0; b<nb; b=b+1) begin
            got=$fscanf(fd,"%d %d", lpac_v, ncontig);
            @(posedge clk); l_pac<=lpac_v; n_seqs<=ncontig[15:0];
            for (i=0; i<ncontig; i=i+1) begin
                got=$fscanf(fd,"%d %d", off_v, len_v);
                @(posedge clk); tbl_we<=1; tbl_idx<=i[15:0]; tbl_offset<=off_v; tbl_len<=len_v;
            end
            @(posedge clk); tbl_we<=0;

            got=$fscanf(fd,"%d", nrec);
            for (r=0; r<nrec; r=r+1) begin
                got=$fscanf(fd,"%d %d %d %d %d %d %d %d", bi,mi,ei,bo,eo,rd_v,rev_v,ln);
                @(posedge clk); beg_in<=bi; midpos<=mi; end_in<=ei;
                @(posedge clk); start<=1;
                @(posedge clk); start<=0;
                guard=0; while (!done && guard<1000) begin @(posedge clk); guard=guard+1; end

                checks=checks+1;
                if (beg_out!==bo || end_out!==eo || rid!==rd_v[31:0] ||
                    is_rev!==rev_v[0] || out_len!==ln) begin
                    fails=fails+1;
                    if (fails<=20) $display(
                        "MISMATCH blk %0d rec %0d: in[%0d %0d %0d] got[b=%0d e=%0d rid=%0d rev=%0d len=%0d] want[b=%0d e=%0d rid=%0d rev=%0d len=%0d]",
                        b, r, bi, mi, ei, beg_out, end_out, rid, is_rev, out_len, bo, eo, rd_v, rev_v, ln);
                end
                @(posedge clk); @(posedge clk);   // settle back to S_IDLE before next request
            end
        end
        $fclose(fd);
        $display("tb_bns_clamp_top: %0d checks, %0d failures -> %s", checks, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #200000000; $display("[FATAL] timeout"); $finish; end
endmodule
