// tb_chain_flt_top.sv — self-checking TB for chain_flt_top (RTL full mem_chain_flt). Loads each
// read's chains+seeds, runs, checks fallback + surviving chain-id sequence bit-exact vs
// gen_chain_flt_top_vectors (= chain.h::c_mem_chain_flt). fb (combsort) cases expect fallback
// and skip the output check (host SW redo).
`timescale 1ns/1ps

module tb_chain_flt_top ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] max_chain_gap, min_seed_len, max_chain_extend;
    logic        ld_seed_en;  logic [15:0] ld_seed_idx;
    logic signed [63:0] ld_seed_rbeg; logic signed [31:0] ld_seed_qbeg, ld_seed_len;
    logic        ld_chain_en; logic [15:0] ld_chain_idx, ld_chain_off, ld_chain_ns; logic ld_chain_isalt;
    logic        start; logic [15:0] n_in;
    logic        busy, done, fallback; logic [15:0] n_out;
    logic [15:0] rd_idx, o_id;

    chain_flt_top #(.NCHAIN(64), .NSEED(256), .CWSEED(64)) dut(.clk,.rst_n,
        .max_chain_gap,.min_seed_len,.max_chain_extend,
        .ld_seed_en,.ld_seed_idx,.ld_seed_rbeg,.ld_seed_qbeg,.ld_seed_len,
        .ld_chain_en,.ld_chain_idx,.ld_chain_off,.ld_chain_ns,.ld_chain_isalt,
        .start,.n_in,.busy,.done,.fallback,.n_out,.rd_idx,.o_id);

    integer fd,got,cnt,ci,k,fails,guard,t_nc,t_gap,t_msl,t_mce,t_tot,e_fb,e_nout;
    integer off[0:63],nsv[0:63],alt[0:63];
    integer srb[0:255],sqb[0:255],sln[0:255];
    integer eid[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainflttop_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_seed_en=0; ld_chain_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d", t_nc,t_gap,t_msl,t_mce,t_tot);
            for (k=0;k<t_nc;k=k+1) got=$fscanf(fd,"%d %d %d", off[k],nsv[k],alt[k]);
            for (k=0;k<t_tot;k=k+1) got=$fscanf(fd,"%d %d %d", srb[k],sqb[k],sln[k]);
            got=$fscanf(fd,"%d %d", e_fb, e_nout);
            for (k=0;k<e_nout;k=k+1) got=$fscanf(fd,"%d", eid[k]);

            // load seeds
            for (k=0;k<t_tot;k=k+1) begin
                @(posedge clk); ld_seed_en<=1; ld_seed_idx<=k[15:0];
                ld_seed_rbeg<=srb[k]; ld_seed_qbeg<=sqb[k]; ld_seed_len<=sln[k];
            end
            @(posedge clk); ld_seed_en<=0;
            // load chains
            for (k=0;k<t_nc;k=k+1) begin
                @(posedge clk); ld_chain_en<=1; ld_chain_idx<=k[15:0];
                ld_chain_off<=off[k][15:0]; ld_chain_ns<=nsv[k][15:0]; ld_chain_isalt<=alt[k][0];
            end
            @(posedge clk); ld_chain_en<=0;
            // config + run
            max_chain_gap<=t_gap; min_seed_len<=t_msl; max_chain_extend<=t_mce; n_in<=t_nc[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<4000000) begin @(posedge clk); guard=guard+1; end

            if (fallback !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] fallback %0b/%0b (nc=%0d)", ci, fallback, e_fb[0], t_nc);
            end else if (e_fb == 0) begin
                if (n_out !== e_nout[15:0]) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH[%0d] n_out %0d/%0d (nc=%0d gap=%0d mce=%0d)", ci, n_out, e_nout, t_nc, t_gap, t_mce);
                end else begin
                    for (k=0;k<e_nout;k=k+1) begin
                        rd_idx<=k[15:0]; @(posedge clk); #1;
                        if (o_id !== eid[k][15:0]) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH[%0d] out %0d: id %0d/%0d (nc=%0d)", ci,k,o_id,eid[k],t_nc);
                        end
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_chain_flt_top: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #4000000000; $display("[FATAL] timeout"); $finish; end
endmodule
