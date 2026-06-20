// tb_chain_flt.sv — self-checking TB for chain_flt (RTL mem_chain_flt filter stage). Loads each
// weighted+sorted chain set, runs, checks per-chain `kept` (0/1/2/3) bit-exact vs
// gen_chain_flt_vectors (= chain.h::c_chain_flt_post).
`timescale 1ns/1ps

module tb_chain_flt ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] max_chain_gap, min_seed_len, max_chain_extend;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [31:0] ld_w, ld_cbeg, ld_cend; logic ld_isalt;
    logic        start; logic [15:0] n_in;
    logic        busy, done; logic [15:0] n_out;
    logic [15:0] rd_idx; logic [1:0] o_kept;

    chain_flt #(.NMAX(64)) dut(.clk,.rst_n,
        .max_chain_gap,.min_seed_len,.max_chain_extend,
        .ld_en,.ld_idx,.ld_w,.ld_cbeg,.ld_cend,.ld_isalt,
        .start,.n_in,.busy,.done,.n_out,
        .rd_idx,.o_kept);

    integer fd,got,cnt,ci,k,fails,guard,t_n,t_gap,t_msl,t_mce;
    integer cw[0:63],cbg[0:63],cnd[0:63],calt[0:63],ek[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainflt_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d", t_n,t_gap,t_msl,t_mce);
            for (k=0;k<t_n;k=k+1) got=$fscanf(fd,"%d %d %d %d", cw[k],cbg[k],cnd[k],calt[k]);
            for (k=0;k<t_n;k=k+1) got=$fscanf(fd,"%d", ek[k]);

            for (k=0;k<t_n;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
                ld_w<=cw[k]; ld_cbeg<=cbg[k]; ld_cend<=cnd[k]; ld_isalt<=calt[k][0];
            end
            @(posedge clk); ld_en<=0;
            max_chain_gap<=t_gap; min_seed_len<=t_msl; max_chain_extend<=t_mce; n_in<=t_n[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            for (k=0;k<t_n;k=k+1) begin
                rd_idx<=k[15:0]; @(posedge clk); #1;
                if (o_kept !== ek[k][1:0]) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH[%0d] chain %0d: kept %0d/%0d (n=%0d gap=%0d msl=%0d mce=%0d)",
                        ci,k,o_kept,ek[k],t_n,t_gap,t_msl,t_mce);
                end
            end
        end
        $fclose(fd);
        $display("tb_chain_flt: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
