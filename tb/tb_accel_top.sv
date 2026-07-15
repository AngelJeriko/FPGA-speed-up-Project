// tb_accel_top.sv — end-to-end self-checking TB for accel_top. Drives a read's
// inputs (host-fed reference), collects the AXI-Stream output, and checks it vs
// orchestrate()->compact->v2_dedup(). Fallback reads (equal-re tie / n>1024) are
// expected to raise `fallback`; their output is not compared.
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_accel_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic read_start, read_finish, ch_ready, ch_go;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3;
    logic q_ld_en,r_ld_en,s_ld_en; logic [15:0] q_ld_addr,r_ld_addr;
    base_t q_ld_data,r_ld_data;
    logic [7:0] s_ld_idx,ch_n; logic signed [63:0] s_ld_rbeg,ch_rmax0,ch_rmax1;
    logic signed [31:0] s_ld_qbeg,s_ld_len,s_ld_score,ch_rid;
    logic m_tvalid,m_tlast,m_tready; rec_t m_tdata;
    logic fallback, busy, done;

    accel_top dut(.clk,.rst_n,
        .read_start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .q_ld_en,.q_ld_addr,.q_ld_data,.r_ld_en,.r_ld_addr,.r_ld_data,
        .s_ld_en,.s_ld_idx,.s_ld_rbeg,.s_ld_qbeg,.s_ld_len,.s_ld_score,
        .ch_go,.ch_n,.ch_rid,.ch_rmax0,.ch_rmax1,.ch_ready,.read_finish,
        .m_axis_tvalid(m_tvalid),.m_axis_tdata(m_tdata),.m_axis_tlast(m_tlast),.m_axis_tready(m_tready),
        .fallback,.busy,.done);

    assign m_tready = 1'b1;   // always ready

    integer fd,got,nreads,ri,cj,i,b,fails,guard,nbeat;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav,t_fb,t_nout;
    integer c_rid,c_n,reflen; longint c_rmax0,c_rmax1;
    longint sd_rb; integer sd_qb,sd_ln,sd_sc;
    integer qbytes[0:255], rbytes[0:1023];
    longint e_rb[0:1023],e_re[0:1023]; integer e_qb[0:1023],e_qe[0:1023],e_rid[0:1023],e_sc[0:1023];
    longint g_rb[0:1023],g_re[0:1023]; integer g_qb[0:1023],g_qe[0:1023],g_rid[0:1023],g_sc[0:1023];
    string path;

    task automatic qld(input int addr,input int dat);
        @(posedge clk); q_ld_en<=1; q_ld_addr<=addr[15:0]; q_ld_data<=base_t'(dat); @(posedge clk); q_ld_en<=0;
    endtask
    task automatic rld(input int addr,input int dat);
        @(posedge clk); r_ld_en<=1; r_ld_addr<=addr[15:0]; r_ld_data<=base_t'(dat); @(posedge clk); r_ld_en<=0;
    endtask
    task automatic sld(input int idx,input longint rb_,input int qb_,input int ln_,input int sc_);
        @(posedge clk); s_ld_en<=1; s_ld_idx<=idx[7:0]; s_ld_rbeg<=rb_; s_ld_qbeg<=qb_; s_ld_len<=ln_; s_ld_score<=sc_;
        @(posedge clk); s_ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/accel_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        read_start=0; read_finish=0; ch_go=0; q_ld_en=0; r_ld_en=0; s_ld_en=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",nreads); fails=0;
        for (ri=0; ri<nreads; ri=ri+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav);
            for (b=0;b<t_lq;b=b+1) got=$fscanf(fd,"%d",qbytes[b]);

            l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3;
            @(posedge clk); read_start<=1; @(posedge clk); read_start<=0;
            wait(ch_ready);
            for (b=0;b<t_lq;b=b+1) qld(b,qbytes[b]);

            for (cj=0; cj<t_nch; cj=cj+1) begin
                got=$fscanf(fd,"%d %d %d %d %d", c_rid,c_rmax0,c_rmax1,c_n,reflen);
                wait(ch_ready);
                for (i=0;i<c_n;i=i+1) begin
                    got=$fscanf(fd,"%d %d %d %d", sd_rb,sd_qb,sd_ln,sd_sc);
                    sld(i,sd_rb,sd_qb,sd_ln,sd_sc);
                end
                for (b=0;b<reflen;b=b+1) got=$fscanf(fd,"%d",rbytes[b]);
                for (b=0;b<reflen;b=b+1) rld(b,rbytes[b]);
                @(posedge clk); ch_n<=c_n[7:0]; ch_rid<=c_rid; ch_rmax0<=c_rmax0; ch_rmax1<=c_rmax1;
                ch_go<=1; @(posedge clk); ch_go<=0; @(posedge clk); wait(ch_ready);
            end

            got=$fscanf(fd,"%d %d", t_fb, t_nout);
            for (i=0;i<t_nout;i=i+1)
                got=$fscanf(fd,"%d %d %d %d %d %d", e_rb[i],e_re[i],e_qb[i],e_qe[i],e_rid[i],e_sc[i]);

            // finish -> run pipeline; collect AXIS output until done
            wait(ch_ready); @(posedge clk); read_finish<=1; @(posedge clk); read_finish<=0;
            nbeat=0; guard=0;
            while (!done && guard<20000000) begin
                @(posedge clk); guard=guard+1;
                if (m_tvalid && m_tready) begin
                    g_rb[nbeat]=m_tdata.rb; g_re[nbeat]=m_tdata.re; g_qb[nbeat]=m_tdata.qb;
                    g_qe[nbeat]=m_tdata.qe; g_rid[nbeat]=m_tdata.rid; g_sc[nbeat]=m_tdata.score;
                    nbeat=nbeat+1;
                end
            end

            if (t_fb) begin
                if (fallback !== 1'b1) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d expected fallback but got %0b", ri, fallback);
                end
            end else begin
                if (fallback !== 1'b0 || nbeat != t_nout) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d fb=%0b nbeat=%0d/%0d", ri, fallback, nbeat, t_nout);
                end else begin
                    for (i=0;i<t_nout;i=i+1)
                        if (g_rb[i]!==e_rb[i]||g_re[i]!==e_re[i]||g_qb[i]!==e_qb[i]||
                            g_qe[i]!==e_qe[i]||g_rid[i]!==e_rid[i]||g_sc[i]!==e_sc[i]) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH read=%0d out=%0d qb %0d/%0d qe %0d/%0d sc %0d/%0d rbOK=%0b reOK=%0b",
                                ri,i,g_qb[i],e_qb[i],g_qe[i],e_qe[i],g_sc[i],e_sc[i],(g_rb[i]===e_rb[i]),(g_re[i]===e_re[i]));
                        end
                end
            end
        end
        $fclose(fd);
        $display("tb_accel_top: %0d reads, %0d failures -> %s",
                 nreads, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd20000000000); $display("[FATAL] timeout"); $finish; end
endmodule
