// tb_chaining_top.sv — self-checking TB for chaining_top (RTL full chaining stage =
// chain_store -> chain_flt_top). Loads each read's raw seed stream, runs, checks fallback +
// the surviving chains' pos-sorted index sequence bit-exact vs gen_chaining_top_vectors
// (= chain.h::c_mem_chain_flt(c_mem_chain(...))). fb cases (dup-pos OR combsort) expect
// fallback and skip the output check (host SW redo).
`timescale 1ns/1ps

module tb_chaining_top ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] w, max_chain_gap, min_seed_len, max_chain_extend;
    logic signed [63:0] l_pac;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rbeg; logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt;
    logic        start; logic [15:0] n_in;
    logic        busy, done, fallback; logic [15:0] n_out;
    logic [15:0] rd_idx, o_cidx;
    logic [15:0] rd_cidx; logic signed [63:0] o_pos; logic signed [31:0] o_rid, o_isalt; logic [15:0] o_nseeds, o_head;
    logic [15:0] rd_sidx; logic signed [63:0] s_rbeg; logic signed [31:0] s_qbeg, s_len, s_score; logic [15:0] s_next;

    chaining_top #(.NCHAIN(64), .NSEED(64), .CWSEED(64)) dut(.clk,.rst_n,
        .w,.max_chain_gap,.l_pac,.min_seed_len,.max_chain_extend,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .start,.n_in,.busy,.done,.fallback,.n_out,
        .rd_idx,.o_cidx,
        .rd_cidx,.o_pos,.o_rid,.o_isalt,.o_nseeds,.o_head,
        .rd_sidx,.s_rbeg,.s_qbeg,.s_len,.s_score,.s_next);

    integer fd,got,cnt,ci,k,fails,guard,t_w,t_gap,t_lpac,t_msl,t_mce,t_ns,e_fb,e_nout;
    integer srb[0:63],sqb[0:63],sln[0:63],ssc[0:63],srid[0:63],sal[0:63],eid[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainingtop_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0; rd_idx=0; rd_cidx=0; rd_sidx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d", t_w,t_gap,t_lpac,t_msl,t_mce,t_ns);
            for (k=0;k<t_ns;k=k+1)
                got=$fscanf(fd,"%d %d %d %d %d %d", srb[k],sqb[k],sln[k],ssc[k],srid[k],sal[k]);
            got=$fscanf(fd,"%d %d", e_fb, e_nout);
            for (k=0;k<e_nout;k=k+1) got=$fscanf(fd,"%d", eid[k]);

            // load raw seeds
            for (k=0;k<t_ns;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
                ld_rbeg<=srb[k]; ld_qbeg<=sqb[k]; ld_len<=sln[k]; ld_score<=ssc[k]; ld_rid<=srid[k]; ld_isalt<=sal[k];
            end
            @(posedge clk); ld_en<=0;
            w<=t_w; max_chain_gap<=t_gap; l_pac<=t_lpac; min_seed_len<=t_msl; max_chain_extend<=t_mce; n_in<=t_ns[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<4000000) begin @(posedge clk); guard=guard+1; end

            if (fallback !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] fallback %0b/%0b (ns=%0d)", ci, fallback, e_fb[0], t_ns);
            end else if (e_fb == 0) begin
                if (n_out !== e_nout[15:0]) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH[%0d] n_out %0d/%0d (ns=%0d gap=%0d mce=%0d)", ci, n_out, e_nout, t_ns, t_gap, t_mce);
                end else begin
                    for (k=0;k<e_nout;k=k+1) begin
                        rd_idx<=k[15:0]; @(posedge clk); #1;
                        if (o_cidx !== eid[k][15:0]) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH[%0d] out %0d: cidx %0d/%0d (ns=%0d)", ci,k,o_cidx,eid[k],t_ns);
                        end
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_chaining_top: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #4000000000; $display("[FATAL] timeout"); $finish; end
endmodule
