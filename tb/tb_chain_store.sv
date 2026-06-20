// tb_chain_store.sv — self-checking TB for chain_store (RTL mem_chain). Loads each seed
// stream, runs, then checks fallback + n_chains + every chain (pos/rid/is_alt/n_seeds and
// the full seed list, walked via head->next in the pool) bit-exact vs gen_chainstore_vectors
// (= chain.h::c_mem_chain). Same sorted-array algorithm -> must match on ALL cases incl. fb.
`timescale 1ns/1ps

module tb_chain_store ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] w, max_chain_gap;
    logic signed [63:0] l_pac;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rbeg; logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt;
    logic        start; logic [15:0] n_in;
    logic        busy, done, fallback; logic [15:0] n_chains;
    logic [15:0] rd_cidx;
    logic signed [63:0] o_pos; logic signed [31:0] o_rid, o_isalt; logic [15:0] o_nseeds, o_head;
    logic [15:0] rd_sidx;
    logic signed [63:0] s_rbeg; logic signed [31:0] s_qbeg, s_len, s_score; logic [15:0] s_next;

    chain_store #(.NCHAIN(64), .NSEED(64)) dut(.clk,.rst_n,
        .w,.max_chain_gap,.l_pac,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .start,.n_in,.busy,.done,.fallback,.n_chains,
        .rd_cidx,.o_pos,.o_rid,.o_isalt,.o_nseeds,.o_head,
        .rd_sidx,.s_rbeg,.s_qbeg,.s_len,.s_score,.s_next);

    // second, small-capacity instance (NCHAIN=8) to exercise the capacity-overflow guard
    // (F1). Shares the input nets with `dut` (its output is only checked in the directed
    // overflow test below; ignored during the main equivalence loop).
    logic o2_busy, o2_done, o2_fallback; logic [15:0] o2_n_chains;
    logic signed [63:0] o2_o_pos; logic signed [31:0] o2_o_rid, o2_o_isalt; logic [15:0] o2_o_nseeds, o2_o_head;
    logic signed [63:0] o2_s_rbeg; logic signed [31:0] o2_s_qbeg, o2_s_len, o2_s_score; logic [15:0] o2_s_next;
    chain_store #(.NCHAIN(8), .NSEED(64)) dut_ovf(.clk,.rst_n,
        .w,.max_chain_gap,.l_pac,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .start,.n_in,.busy(o2_busy),.done(o2_done),.fallback(o2_fallback),.n_chains(o2_n_chains),
        .rd_cidx,.o_pos(o2_o_pos),.o_rid(o2_o_rid),.o_isalt(o2_o_isalt),.o_nseeds(o2_o_nseeds),.o_head(o2_o_head),
        .rd_sidx,.s_rbeg(o2_s_rbeg),.s_qbeg(o2_s_qbeg),.s_len(o2_s_len),.s_score(o2_s_score),.s_next(o2_s_next));

    integer fd,got,cnt,ci,k,c,fails,guard,t_w,t_gap,t_lpac,t_ns,e_fb,e_nch,sidx;
    integer srb[0:63],sqb[0:63],sln[0:63],ssc[0:63],srid[0:63],sal[0:63];
    integer e_pos[0:63],e_rid[0:63],e_al[0:63],e_ns[0:63];
    integer es_rb[0:63][0:63],es_qb[0:63][0:63],es_ln[0:63][0:63],es_sc[0:63][0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainstore_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0; rd_cidx=0; rd_sidx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d", t_w,t_gap,t_lpac,t_ns);
            for (k=0;k<t_ns;k=k+1)
                got=$fscanf(fd,"%d %d %d %d %d %d", srb[k],sqb[k],sln[k],ssc[k],srid[k],sal[k]);
            got=$fscanf(fd,"%d %d", e_fb, e_nch);
            for (c=0;c<e_nch;c=c+1) begin
                got=$fscanf(fd,"%d %d %d %d", e_pos[c],e_rid[c],e_al[c],e_ns[c]);
                for (k=0;k<e_ns[c];k=k+1)
                    got=$fscanf(fd,"%d %d %d %d", es_rb[c][k],es_qb[c][k],es_ln[c][k],es_sc[c][k]);
            end

            // load seeds
            for (k=0;k<t_ns;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
                ld_rbeg<=srb[k]; ld_qbeg<=sqb[k]; ld_len<=sln[k]; ld_score<=ssc[k]; ld_rid<=srid[k]; ld_isalt<=sal[k];
            end
            @(posedge clk); ld_en<=0;
            // config + run
            w<=t_w; max_chain_gap<=t_gap; l_pac<=t_lpac; n_in<=t_ns[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (fallback !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] fallback %0b/%0b (n_seeds=%0d)", ci, fallback, e_fb[0], t_ns);
            end
            if (n_chains !== e_nch[15:0]) begin
                fails=fails+1;
                if (fails<=2) begin
                    $display("MISMATCH[%0d] n_chains %0d/%0d (n_seeds=%0d) w=%0d gap=%0d lpac=%0d", ci, n_chains, e_nch, t_ns, t_w, t_gap, t_lpac);
                    for (k=0;k<t_ns;k=k+1) $display("   seed %0d: rb=%0d qb=%0d ln=%0d sc=%0d rid=%0d alt=%0d", k,srb[k],sqb[k],sln[k],ssc[k],srid[k],sal[k]);
                    for (c=0;c<n_chains;c=c+1) begin rd_cidx<=c[15:0]; @(posedge clk); #1;
                        $display("   RTL chain %0d: pos=%0d rid=%0d alt=%0d ns=%0d", c,o_pos,o_rid,o_isalt,o_nseeds); end
                    for (c=0;c<e_nch;c=c+1) $display("   EXP chain %0d: pos=%0d rid=%0d alt=%0d ns=%0d", c,e_pos[c],e_rid[c],e_al[c],e_ns[c]);
                end
            end else begin
                for (c=0;c<e_nch;c=c+1) begin
                    rd_cidx<=c[15:0]; @(posedge clk); #1;
                    if (o_pos!==e_pos[c] || o_rid!==e_rid[c] || o_isalt!==e_al[c] || o_nseeds!==e_ns[c][15:0]) begin
                        fails=fails+1;
                        if (fails<=12) $display("MISMATCH[%0d] chain %0d: pos %0d/%0d rid %0d/%0d alt %0d/%0d ns %0d/%0d",
                            ci,c,o_pos,e_pos[c],o_rid,e_rid[c],o_isalt,e_al[c],o_nseeds,e_ns[c]);
                    end else begin
                        sidx = o_head;          // walk the chain's seed list
                        for (k=0;k<e_ns[c];k=k+1) begin
                            rd_sidx<=sidx[15:0]; @(posedge clk); #1;
                            if (s_rbeg!==es_rb[c][k] || s_qbeg!==es_qb[c][k] || s_len!==es_ln[c][k] || s_score!==es_sc[c][k]) begin
                                fails=fails+1;
                                if (fails<=12) $display("MISMATCH[%0d] chain %0d seed %0d: rb %0d/%0d qb %0d/%0d ln %0d/%0d sc %0d/%0d",
                                    ci,c,k,s_rbeg,es_rb[c][k],s_qbeg,es_qb[c][k],s_len,es_ln[c][k],s_score,es_sc[c][k]);
                            end
                            sidx = s_next;
                        end
                    end
                end
            end
        end
        $fclose(fd);

        // ---- directed capacity-overflow test (F1 guard) ----
        // 16 distinct-pos forward-strand seeds that never merge (rbeg far apart, qbeg flat ->
        // not colinear, not contained) -> wants 16 chains, but dut_ovf has NCHAIN=8. The guard
        // must raise fallback (host SW redo) rather than write OOB or hang.
        w<=32'sd100; max_chain_gap<=32'sd10000; l_pac<=64'sd1000000;
        for (k=0;k<16;k=k+1) begin
            @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
            ld_rbeg<=k*1000; ld_qbeg<=0; ld_len<=20; ld_score<=20; ld_rid<=0; ld_isalt<=0;
        end
        @(posedge clk); ld_en<=0; n_in<=16'd16;
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        guard=0; while (!o2_done && guard<2000000) begin @(posedge clk); guard=guard+1; end
        if (o2_fallback !== 1'b1) begin
            fails=fails+1;
            $display("OVF-TEST FAIL: fallback=%0b (expected 1), n_chains=%0d", o2_fallback, o2_n_chains);
        end else
            $display("OVF-TEST PASS: capacity guard raised fallback (n_chains=%0d, cap=8)", o2_n_chains);

        $display("tb_chain_store: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
