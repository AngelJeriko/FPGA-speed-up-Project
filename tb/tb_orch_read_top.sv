// tb_orch_read_top.sv — self-checking TB for orch_read_top. Plays the host for
// each read (host-fed reference): load query, then per chain load ref+seeds and
// fire it, then finish (purge), then read back the post-purge alnregs and check
// them bit-exact vs orchestrate() (HW model + integer purge).
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_orch_read_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        read_start, read_finish, read_done, busy, ch_ready, ch_go;
    logic        dut_overflow;   // no vector read overflows NAV; must stay low
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3;
    logic        q_ld_en, r_ld_en, s_ld_en; logic [15:0] q_ld_addr, r_ld_addr;
    base_t       q_ld_data, r_ld_data;
    logic [7:0]  s_ld_idx, ch_n; logic signed [63:0] s_ld_rbeg, ch_rmax0, ch_rmax1;
    logic signed [31:0] s_ld_qbeg, s_ld_len, s_ld_score, ch_rid;
    logic [15:0] rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_score,o_truesc,o_w,o_seedcov,o_seedlen0,o_rid;

    orch_read_top dut(.clk,.rst_n,
        .read_start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .q_ld_en,.q_ld_addr,.q_ld_data,.r_ld_en,.r_ld_addr,.r_ld_data,
        .s_ld_en,.s_ld_idx,.s_ld_rbeg,.s_ld_qbeg,.s_ld_len,.s_ld_score,
        .ch_go,.ch_n,.ch_rid,.ch_rmax0,.ch_rmax1,.ch_ready,
        .read_finish,.read_done,.busy,.o_nav(),.overflow(dut_overflow),
        .rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_score,.o_truesc,.o_w,.o_seedcov,.o_seedlen0,.o_rid);

    integer fd,got,nreads,ri,cj,i,b,fails,guard;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav;
    integer c_rid,c_n,reflen; longint c_rmax0,c_rmax1;
    longint sd_rb; integer sd_qb,sd_ln,sd_sc;
    integer qbytes[0:255], rbytes[0:1023];
    longint e_rb[0:1023], e_re[0:1023];
    integer e_qb[0:1023],e_qe[0:1023],e_sc[0:1023],e_ts[0:1023],e_w[0:1023],e_scov[0:1023],e_sl0[0:1023],e_rid[0:1023];
    string path;

    task automatic qld(input int addr, input int dat);
        @(posedge clk); q_ld_en<=1; q_ld_addr<=addr[15:0]; q_ld_data<=base_t'(dat);
        @(posedge clk); q_ld_en<=0;
    endtask
    task automatic rld(input int addr, input int dat);
        @(posedge clk); r_ld_en<=1; r_ld_addr<=addr[15:0]; r_ld_data<=base_t'(dat);
        @(posedge clk); r_ld_en<=0;
    endtask
    task automatic sld(input int idx, input longint rb_, input int qb_, input int ln_, input int sc_);
        @(posedge clk); s_ld_en<=1; s_ld_idx<=idx[7:0]; s_ld_rbeg<=rb_; s_ld_qbeg<=qb_; s_ld_len<=ln_; s_ld_score<=sc_;
        @(posedge clk); s_ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/read_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        read_start=0; read_finish=0; ch_go=0; q_ld_en=0; r_ld_en=0; s_ld_en=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",nreads); fails=0;
        for (ri=0; ri<nreads; ri=ri+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav);
            for (b=0;b<t_lq;b=b+1) got=$fscanf(fd,"%d",qbytes[b]);

            // begin read + drive cfg
            l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3;
            @(posedge clk); read_start<=1; @(posedge clk); read_start<=0;
            wait(ch_ready);
            for (b=0;b<t_lq;b=b+1) qld(b,qbytes[b]);

            for (cj=0; cj<t_nch; cj=cj+1) begin
                got=$fscanf(fd,"%d %d %d %d %d", c_rid,c_rmax0,c_rmax1,c_n,reflen);
                wait(ch_ready);
                // seeds: read + drive
                for (i=0;i<c_n;i=i+1) begin
                    got=$fscanf(fd,"%d %d %d %d", sd_rb,sd_qb,sd_ln,sd_sc);
                    sld(i,sd_rb,sd_qb,sd_ln,sd_sc);
                end
                // ref window: read + drive
                for (b=0;b<reflen;b=b+1) got=$fscanf(fd,"%d",rbytes[b]);
                for (b=0;b<reflen;b=b+1) rld(b,rbytes[b]);
                // go
                @(posedge clk); ch_n<=c_n[7:0]; ch_rid<=c_rid; ch_rmax0<=c_rmax0; ch_rmax1<=c_rmax1;
                ch_go<=1; @(posedge clk); ch_go<=0;
                @(posedge clk); wait(ch_ready);   // chain collected
            end

            for (i=0;i<t_nav;i=i+1)
                got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",
                    e_rb[i],e_re[i],e_qb[i],e_qe[i],e_sc[i],e_ts[i],e_w[i],e_scov[i],e_sl0[i],e_rid[i]);

            // finish -> purge
            wait(ch_ready); @(posedge clk); read_finish<=1; @(posedge clk); read_finish<=0;
            guard=0; while (!read_done && guard<20000000) begin @(posedge clk); guard=guard+1; end

            // readback + check
            for (i=0;i<t_nav;i=i+1) begin
                rd_idx<=i[15:0]; @(posedge clk); #1;
                if (o_rb!==e_rb[i] || o_re!==e_re[i] || o_qb!==e_qb[i] || o_qe!==e_qe[i] ||
                    o_score!==e_sc[i] || o_truesc!==e_ts[i] || o_w!==e_w[i] ||
                    o_seedcov!==e_scov[i] || o_seedlen0!==e_sl0[i] || o_rid!==e_rid[i]) begin
                    fails=fails+1;
                    if (fails<=12) begin
                        $display("MISMATCH read=%0d av=%0d  qb %0d/%0d qe %0d/%0d sc %0d/%0d",
                            ri,i,o_qb,e_qb[i],o_qe,e_qe[i],o_score,e_sc[i]);
                        $display("   ts %0d/%0d w %0d/%0d scov %0d/%0d sl0 %0d/%0d rid %0d/%0d rbOK=%0b reOK=%0b",
                            o_truesc,e_ts[i],o_w,e_w[i],o_seedcov,e_scov[i],o_seedlen0,e_sl0[i],
                            o_rid,e_rid[i],(o_rb===e_rb[i]),(o_re===e_re[i]));
                    end
                end
            end
            // real-data reads here stay well under NAV: the capacity guard must not fire
            if (dut_overflow !== 1'b0) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH read=%0d overflow raised (nav<NAV expected)", ri);
            end
        end
        $fclose(fd);
        $display("tb_orch_read_top: %0d reads, %0d failures -> %s",
                 nreads, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd20000000000); $display("[FATAL] timeout"); $finish; end
endmodule
