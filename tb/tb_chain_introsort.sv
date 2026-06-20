// tb_chain_introsort.sv — self-checking TB for chain_introsort (RTL ks_introsort(mem_flt)).
// Loads each (w,id) array, runs, and checks the sorted (w,id) sequence bit-exact vs
// gen_chain_introsort_vectors (= chain.h::ks_introsort_memflt) — including the UNSTABLE
// equal-weight tie order via the id tags. fb cases (combsort would fire) expect `fallback`
// raised and skip the order check (host SW redo).
`timescale 1ns/1ps

module tb_chain_introsort ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en; logic [15:0] ld_idx;
    logic signed [31:0] ld_w; logic [15:0] ld_id;
    logic        start; logic [15:0] n_in;
    logic        busy, done, fallback; logic [15:0] n_out;
    logic [15:0] rd_idx;
    logic signed [31:0] o_w; logic [15:0] o_id;

    chain_introsort #(.NMAX(64), .STACKD(48)) dut(.clk,.rst_n,
        .ld_en,.ld_idx,.ld_w,.ld_id,
        .start,.n_in,.busy,.done,.fallback,.n_out,
        .rd_idx,.o_w,.o_id);

    integer fd,got,cnt,ci,k,fails,guard,t_n,e_fb;
    integer iw[0:63],iid[0:63],ew[0:63],eid[0:63];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/chaining/vectors/chainintro_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d", t_n);
            for (k=0;k<t_n;k=k+1) got=$fscanf(fd,"%d %d", iw[k], iid[k]);
            got=$fscanf(fd,"%d", e_fb);
            for (k=0;k<t_n;k=k+1) got=$fscanf(fd,"%d %d", ew[k], eid[k]);

            for (k=0;k<t_n;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0]; ld_w<=iw[k]; ld_id<=iid[k][15:0];
            end
            @(posedge clk); ld_en<=0; n_in<=t_n[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (fallback !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] fallback %0b/%0b (n=%0d)", ci, fallback, e_fb[0], t_n);
            end else if (e_fb == 0) begin
                // non-fallback: check the full sorted (w,id) sequence
                for (k=0;k<t_n;k=k+1) begin
                    rd_idx<=k[15:0]; @(posedge clk); #1;
                    if (o_w!==ew[k] || o_id!==eid[k][15:0]) begin
                        fails=fails+1;
                        if (fails<=12) $display("MISMATCH[%0d] pos %0d: w %0d/%0d id %0d/%0d (n=%0d)",
                            ci,k,o_w,ew[k],o_id,eid[k],t_n);
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_chain_introsort: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
