// tb_chain2aln_setup.sv — self-checking TB for chain2aln_setup (RTL rmax computation). Loads
// each chain's seeds + cfg, runs, checks rmax0/rmax1 bit-exact vs gen_chain2aln_vectors
// (= chain2aln.h::c_compute_rmax, itself validated 241018/0 against real captured rmax).
`timescale 1ns/1ps

module tb_chain2aln_setup ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] a, o_del, e_del, o_ins, e_ins, wband, l_query;
    logic signed [63:0] l_pac;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rbeg; logic signed [31:0] ld_qbeg, ld_len;
    logic        start; logic [15:0] n_in;
    logic        busy, done; logic signed [63:0] rmax0, rmax1;

    chain2aln_setup #(.NSEED(64)) dut(.clk,.rst_n,
        .a,.o_del,.e_del,.o_ins,.e_ins,.wband,.l_query,.l_pac,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,
        .start,.n_in,.busy,.done,.rmax0,.rmax1);

    integer fd,got,cnt,ci,k,fails,guard,t_a,t_od,t_ed,t_oi,t_ei,t_w,t_lq,t_ns;
    longint t_lpac, e_r0, e_r1, srb[0:63]; integer sqb[0:63], sln[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/chain2aln_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d", t_a,t_od,t_ed,t_oi,t_ei,t_w,t_lq,t_lpac,t_ns);
            for (k=0;k<t_ns;k=k+1) got=$fscanf(fd,"%d %d %d", srb[k],sqb[k],sln[k]);
            got=$fscanf(fd,"%d %d", e_r0, e_r1);

            for (k=0;k<t_ns;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0]; ld_rbeg<=srb[k]; ld_qbeg<=sqb[k]; ld_len<=sln[k];
            end
            @(posedge clk); ld_en<=0;
            a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei; wband<=t_w; l_query<=t_lq; l_pac<=t_lpac; n_in<=t_ns[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<200000) begin @(posedge clk); guard=guard+1; end

            if (rmax0 !== e_r0 || rmax1 !== e_r1) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] rmax [%0d,%0d] / [%0d,%0d] (ns=%0d lpac=%0d)",
                    ci, rmax0, rmax1, e_r0, e_r1, t_ns, t_lpac);
            end
        end
        $fclose(fd);
        $display("tb_chain2aln_setup: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
