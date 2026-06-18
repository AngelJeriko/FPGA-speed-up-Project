// tb_orch_chain_unit.sv — self-checking TB for orch_chain_unit. For each chain
// vector (host/extend_orchestrator/vectors/chain_vectors.txt) it loads the query,
// ref window, and seeds, fires the chain, and checks the emitted alnreg stream
// (rb/re/qb/qe/score/truesc/w/seedcov/seedlen0/rid, in append order) bit-exact vs
// extend_only()'s per-chain slice.
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_orch_chain_unit
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en, ld_sel; logic [15:0] ld_addr; base_t ld_data;
    logic        sld_en; logic [7:0] sld_idx;
    logic signed [63:0] sld_rbeg; logic signed [31:0] sld_qbeg, sld_len, sld_score;
    logic        start; logic [7:0] n_seeds;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3,rid;
    logic signed [63:0] rmax0,rmax1;
    logic        busy,out_valid,out_last,done;
    logic signed [63:0] o_rb,o_re;
    logic signed [31:0] o_qb,o_qe,o_score,o_truesc,o_w,o_seedcov,o_seedlen0,o_rid;

    orch_chain_unit dut(.clk,.rst_n,.ld_en,.ld_sel,.ld_addr,.ld_data,
        .sld_en,.sld_idx,.sld_rbeg,.sld_qbeg,.sld_len,.sld_score,
        .start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .n_seeds,.rid,.rmax0,.rmax1,
        .busy,.out_valid,.out_last,.done,
        .o_rb,.o_re,.o_qb,.o_qe,.o_score,.o_truesc,.o_w,.o_seedcov,.o_seedlen0,.o_rid);

    integer fd,got,cnt,ci,i,b,fails,reflen,nseed,nout,guard,ek;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_rid;
    longint t_rmax0,t_rmax1;
    longint sd_rbeg; integer sd_qbeg,sd_len,sd_score;
    integer qbytes[0:255], rbytes[0:1023];
    longint e_rb[0:255], e_re[0:255];
    integer e_qb[0:255],e_qe[0:255],e_sc[0:255],e_ts[0:255],e_w[0:255],e_scov[0:255],e_sl0[0:255],e_rid[0:255];
    string path;

    task automatic mem(input bit sel, input int addr, input int dat);
        @(posedge clk); ld_en<=1; ld_sel<=sel; ld_addr<=addr[15:0]; ld_data<=base_t'(dat);
        @(posedge clk); ld_en<=0;
    endtask
    task automatic seed(input int idx, input longint rb_, input int qb_, input int ln_, input int sc_);
        @(posedge clk); sld_en<=1; sld_idx<=idx[7:0]; sld_rbeg<=rb_; sld_qbeg<=qb_; sld_len<=ln_; sld_score<=sc_;
        @(posedge clk); sld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/chain_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; sld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_rid,
                t_rmax0,t_rmax1,nseed,reflen,nout);
            for (i=0;i<nseed;i=i+1) begin
                got=$fscanf(fd,"%d %d %d %d", sd_rbeg,sd_qbeg,sd_len,sd_score);
                seed(i, sd_rbeg, sd_qbeg, sd_len, sd_score);
            end
            for (b=0;b<t_lq;b=b+1)   got=$fscanf(fd,"%d",qbytes[b]);
            for (b=0;b<reflen;b=b+1) got=$fscanf(fd,"%d",rbytes[b]);
            for (i=0;i<nout;i=i+1)
                got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",
                    e_rb[i],e_re[i],e_qb[i],e_qe[i],e_sc[i],e_ts[i],e_w[i],e_scov[i],e_sl0[i],e_rid[i]);

            for (b=0;b<t_lq;b=b+1)   mem(1'b0,b,qbytes[b]);
            for (b=0;b<reflen;b=b+1) mem(1'b1,b,rbytes[b]);

            l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3; rid<=t_rid;
            rmax0<=t_rmax0; rmax1<=t_rmax1; n_seeds<=nseed[7:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;

            ek=0; guard=0;
            while (!done && guard<2000000) begin
                @(posedge clk); guard=guard+1;
                if (out_valid) begin
                    if (o_rb!==e_rb[ek] || o_re!==e_re[ek] || o_qb!==e_qb[ek] || o_qe!==e_qe[ek] ||
                        o_score!==e_sc[ek] || o_truesc!==e_ts[ek] || o_w!==e_w[ek] ||
                        o_seedcov!==e_scov[ek] || o_seedlen0!==e_sl0[ek] || o_rid!==e_rid[ek]) begin
                        fails=fails+1;
                        if (fails<=12) begin
                            $display("MISMATCH chain=%0d k=%0d nseed=%0d  qb %0d/%0d qe %0d/%0d",
                                ci, ek, nseed, o_qb,e_qb[ek], o_qe,e_qe[ek]);
                            $display("   sc %0d/%0d ts %0d/%0d w %0d/%0d scov %0d/%0d rbOK=%0b reOK=%0b",
                                o_score,e_sc[ek], o_truesc,e_ts[ek], o_w,e_w[ek],
                                o_seedcov,e_scov[ek], (o_rb===e_rb[ek]), (o_re===e_re[ek]));
                        end
                    end
                    ek=ek+1;
                end
            end
            if (ek != nout) begin fails=fails+1;
                if (fails<=12) $display("CHAIN %0d emitted %0d expected %0d", ci, ek, nout); end
        end
        $fclose(fd);
        $display("tb_orch_chain_unit: %0d chains, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #4000000000; $display("[FATAL] timeout"); $finish; end
endmodule
