// tb_chain_weight.sv — self-checking TB for chain_weight (RTL mem_chain_weight). Loads each
// seed stream, runs, checks w bit-exact vs gen_chain_weight_vectors (= chain.h::c_chain_weight).
`timescale 1ns/1ps

module tb_chain_weight ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en; logic [15:0] ld_idx;
    logic signed [31:0] ld_qbeg, ld_len; logic signed [63:0] ld_rbeg;
    logic        start; logic [15:0] n_in;
    logic        busy, done; logic signed [31:0] w;

    chain_weight #(.NSEED(64)) dut(.clk,.rst_n,
        .ld_en,.ld_idx,.ld_qbeg,.ld_rbeg,.ld_len,
        .start,.n_in,.busy,.done,.w);

    integer fd,got,cnt,ci,k,fails,guard,t_ns,e_w;
    integer qb[0:63],ln[0:63]; longint rb[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainweight_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d", t_ns);
            for (k=0;k<t_ns;k=k+1) got=$fscanf(fd,"%d %d %d", qb[k],rb[k],ln[k]);
            got=$fscanf(fd,"%d", e_w);

            for (k=0;k<t_ns;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
                ld_qbeg<=qb[k]; ld_rbeg<=rb[k]; ld_len<=ln[k];
            end
            @(posedge clk); ld_en<=0; n_in<=t_ns[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (w !== e_w) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] w %0d/%0d (n_seeds=%0d)", ci, w, e_w, t_ns);
            end
        end
        $fclose(fd);
        $display("tb_chain_weight: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
