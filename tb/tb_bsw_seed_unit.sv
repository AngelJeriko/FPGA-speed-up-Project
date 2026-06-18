// tb_bsw_seed_unit.sv — self-checking TB for bsw_seed_unit. For each seed vector
// (host/extend_orchestrator/vectors/seedext_vectors.txt) it loads the query and
// reference window into the unit's memories, fires one extension, and checks the
// assembled alnreg (rb/re/qb/qe/score/truesc/w) bit-exact vs extend_only().
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_seed_unit
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en, ld_sel;
    logic [15:0] ld_addr;
    base_t       ld_data;
    logic        start, busy, done_o;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3,qbeg,len,rid;
    logic signed [63:0] rbeg,rmax0,rmax1;
    logic signed [63:0] rb,re;
    logic signed [31:0] qb,qe,score,truesc,w_out,rid_out;

    bsw_seed_unit dut(.clk,.rst_n,.ld_en,.ld_sel,.ld_addr,.ld_data,
        .start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .rbeg,.qbeg,.len,.rid,.rmax0,.rmax1,
        .busy,.done_o,.rb,.re,.qb,.qe,.score,.truesc,.w_out,.rid_out);

    integer fd, got, cnt, i, b, fails, reflen, guard;
    longint t_rbeg,t_rmax0,t_rmax1,e_rb,e_re;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_qbeg,t_len,t_rid;
    integer e_qb,e_qe,e_score,e_truesc,e_w;
    integer qbytes [0:255];
    integer rbytes [0:1023];
    string path;

    task automatic load_mem(input bit sel, input int addr, input int dat);
        @(posedge clk);
        ld_en<=1; ld_sel<=sel; ld_addr<=addr[15:0]; ld_data<=base_t'(dat);
        @(posedge clk); ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path))
            path = "host/extend_orchestrator/vectors/seedext_vectors.txt";
        fd = $fopen(path, "r");
        if (fd==0) begin $display("FATAL: cannot open %s", path); $finish; end
        ld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (i=0;i<cnt;i=i+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,
                t_rbeg,t_qbeg,t_len,t_rid,t_rmax0,t_rmax1,reflen,
                e_rb,e_re,e_qb,e_qe,e_score,e_truesc,e_w);
            for (b=0;b<t_lq;b=b+1)   got=$fscanf(fd,"%d",qbytes[b]);
            for (b=0;b<reflen;b=b+1) got=$fscanf(fd,"%d",rbytes[b]);

            // load memories
            for (b=0;b<t_lq;b=b+1)   load_mem(1'b0,b,qbytes[b]);
            for (b=0;b<reflen;b=b+1) load_mem(1'b1,b,rbytes[b]);

            // drive request
            l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3;
            rbeg<=t_rbeg; qbeg<=t_qbeg; len<=t_len; rid<=t_rid; rmax0<=t_rmax0; rmax1<=t_rmax1;
            @(posedge clk);
            start<=1; @(posedge clk); start<=0;

            guard=0;
            while (!done_o && guard<100000) begin @(posedge clk); guard=guard+1; end

            if (rb!==e_rb || re!==e_re || qb!==e_qb || qe!==e_qe ||
                score!==e_score || truesc!==e_truesc || w_out!==e_w) begin
                fails=fails+1;
                if (fails<=12) begin
                    $display("MISMATCH[%0d] qbeg=%0d len=%0d lq=%0d  rbOK=%0b reOK=%0b",
                        i, t_qbeg, t_len, t_lq, (rb===e_rb), (re===e_re));
                    $display("            qb %0d/%0d qe %0d/%0d sc %0d/%0d tsc %0d/%0d w %0d/%0d",
                        qb, e_qb, qe, e_qe, score, e_score, truesc, e_truesc, w_out, e_w);
                end
            end
        end
        $fclose(fd);
        $display("tb_bsw_seed_unit: %0d seeds, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end

    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule
