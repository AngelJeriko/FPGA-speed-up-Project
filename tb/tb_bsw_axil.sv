// tb_bsw_axil.sv  (board-bringup track)
// -----------------------------------------------------------------------------
// Self-checking testbench for bsw_axil_regs: proves the AXI4-Lite wrapper is a
// TRANSPARENT front-end to bsw_top. For each vector it runs the SAME query/
// target/config two ways -- directly into a bare bsw_top (REF), and through the
// AXI-Lite register file (DUT) -- and asserts the results are identical. No
// external golden vectors: the property under test is "the wrapper marshals data
// and control without changing the engine's answer."
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_axil
    import bsw_pkg::*;
;
    localparam int ADDR_W = 16, DATA_W = 32;
    localparam int QRY_BITS = MAX_QLEN*BASE_WIDTH,  TGT_BITS = MAX_TLEN*BASE_WIDTH;
    localparam int CFG_BITS = $bits(bsw_config_t),  RES_BITS = $bits(bsw_result_t);
    localparam int QRY_WORDS = (QRY_BITS+DATA_W-1)/DATA_W;  // 15
    localparam int TGT_WORDS = (TGT_BITS+DATA_W-1)/DATA_W;  // 96
    localparam int CFG_WORDS = (CFG_BITS+DATA_W-1)/DATA_W;  // 5
    localparam int RES_WORDS = (RES_BITS+DATA_W-1)/DATA_W;  // 4

    // region bases (byte offsets)
    localparam [15:0] A_CTRL=16'h000, A_STAT=16'h004, A_CFG=16'h010,
                      A_QRY=16'h100, A_TGT=16'h200, A_RES=16'h400;

    logic clk=0, rst_n=0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- AXI-Lite bus to the DUT ----
    logic [ADDR_W-1:0] awaddr, araddr;
    logic [DATA_W-1:0] wdata, rdata;
    logic [DATA_W/8-1:0] wstrb;
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic arvalid, arready, rvalid, rready;
    logic [1:0] bresp, rresp;

    bsw_axil_regs #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready)
    );

    // ---- bare reference engine ----
    logic                 rf_reqv, rf_reqr, rf_resv, rf_resr;
    base_t [MAX_QLEN-1:0] rf_q;
    base_t [MAX_TLEN-1:0] rf_t;
    bsw_config_t          rf_cfg;
    bsw_result_t          rf_res;

    bsw_top ref_i (
        .clk(clk), .rst_n(rst_n), .restart_mode(1'b0),
        .req_valid_i(rf_reqv), .req_ready_o(rf_reqr),
        .query_i(rf_q), .target_i(rf_t), .cfg_i(rf_cfg),
        .result_valid_o(rf_resv), .result_ready_i(rf_resr), .result_o(rf_res)
    );

    // ---- AXI-Lite master tasks (wait()-based, blocking drive: matches the
    //      proven bsw_top handshake idiom in tb_bsw_top / submit_and_wait) ----
    task automatic axil_write(input [15:0] addr, input [31:0] data);
        @(posedge clk); awaddr = addr; awvalid = 1'b1;
        wait (awready); @(posedge clk); awvalid = 1'b0;
        wdata = data; wstrb = 4'hF; wvalid = 1'b1;
        wait (wready);  @(posedge clk); wvalid = 1'b0;
        bready = 1'b1;
        wait (bvalid);  @(posedge clk); bready = 1'b0;
    endtask

    task automatic axil_read(input [15:0] addr, output [31:0] data);
        @(posedge clk); araddr = addr; arvalid = 1'b1;
        wait (arready); @(posedge clk); arvalid = 1'b0;
        rready = 1'b1;
        wait (rvalid);  data = rdata; @(posedge clk); rready = 1'b0;
    endtask

    // ---- run one alignment on the REF (result_ready held high, see initial) ----
    task automatic run_ref(input base_t [MAX_QLEN-1:0] q, input base_t [MAX_TLEN-1:0] t,
                           input bsw_config_t c, output bsw_result_t r);
        @(posedge clk); rf_q = q; rf_t = t; rf_cfg = c;
        @(posedge clk); wait (rf_reqr); @(posedge clk);
        rf_reqv = 1'b1; @(posedge clk); rf_reqv = 1'b0;
        wait (rf_resv); @(posedge clk);
        r = rf_res;
    endtask

    // ---- run one alignment through the AXI-Lite DUT ----
    task automatic run_dut(input base_t [MAX_QLEN-1:0] q, input base_t [MAX_TLEN-1:0] t,
                           input bsw_config_t c, output bsw_result_t r);
        logic [CFG_WORDS*DATA_W-1:0] cf;
        logic [QRY_WORDS*DATA_W-1:0] qf;
        logic [TGT_WORDS*DATA_W-1:0] tf;
        logic [RES_WORDS*DATA_W-1:0] rf;
        logic [31:0] w;
        cf = c; qf = q; tf = t;
        for (int i = 0; i < CFG_WORDS; i++) axil_write(A_CFG + i*4, cf[i*DATA_W +: DATA_W]);
        for (int i = 0; i < QRY_WORDS; i++) axil_write(A_QRY + i*4, qf[i*DATA_W +: DATA_W]);
        for (int i = 0; i < TGT_WORDS; i++) axil_write(A_TGT + i*4, tf[i*DATA_W +: DATA_W]);
        axil_write(A_CTRL, 32'h1);                 // GO
        forever begin axil_read(A_STAT, w); if (w[1]) break; end   // poll done
        rf = '0;
        for (int i = 0; i < RES_WORDS; i++) axil_read(A_RES + i*4, rf[i*DATA_W +: DATA_W]);
        r = rf[RES_BITS-1:0];
    endtask

    // ---- default config (bwa-mem2 defaults) ----
    function automatic bsw_config_t mk_cfg(input len_t qlen, input len_t tlen);
        bsw_config_t c;
        // h0=1: bwa-mem2 is seed-EXTENSION; h0 is the seed carry-in. With h0=0 the
        // gate kills every cell (see tb_bsw_top load_config). w=BAND_WIDTH matches
        // the proven driver so scores are meaningful.
        c.h0 = score_t'(1); c.o_del = W_O_DEL; c.e_del = W_E_DEL; c.o_ins = W_O_INS;
        c.e_ins = W_E_INS; c.zdrop = '0; c.end_bonus = '0;
        c.w = len_t'(BAND_WIDTH); c.qlen = qlen; c.tlen = tlen;
        return c;
    endfunction

    integer pass=0, fail=0;

    task automatic check(input base_t [MAX_QLEN-1:0] q, input base_t [MAX_TLEN-1:0] t,
                         input bsw_config_t c, input string name);
        bsw_result_t rr, rd;
        run_ref(q, t, c, rr);
        run_dut(q, t, c, rd);
        if (rr === rd) begin
            pass++;
            $display("[ OK ] %-22s score=%0d qle=%0d tle=%0d gscore=%0d",
                     name, rd.score, rd.qle, rd.tle, rd.gscore);
        end else begin
            fail++;
            $display("[FAIL] %-22s REF{score=%0d qle=%0d tle=%0d gscore=%0d err=%0b}  DUT{score=%0d qle=%0d tle=%0d gscore=%0d err=%0b}",
                     name, rr.score, rr.qle, rr.tle, rr.gscore, rr.error,
                     rd.score, rd.qle, rd.tle, rd.gscore, rd.error);
        end
    endtask

    // ---- vectors ----
    base_t [MAX_QLEN-1:0] q; base_t [MAX_TLEN-1:0] t; bsw_config_t c;

    initial begin
        awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; wstrb=0;
        rf_reqv=0; rf_resr=1'b1; rf_q='0; rf_t='0; rf_cfg='0;   // result_ready held high
        repeat (5) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // 1. ACGT / ACGT
        q='0; t='0; q[0]=0;q[1]=1;q[2]=2;q[3]=3; t[0]=0;t[1]=1;t[2]=2;t[3]=3;
        c = mk_cfg(4,4); check(q,t,c,"ACGT/ACGT");

        // 2. AAAA / CCCC (all mismatch)
        q='0; t='0; for(int i=0;i<4;i++) begin q[i]=0; t[i]=1; end
        c = mk_cfg(4,4); check(q,t,c,"AAAA/CCCC");

        // 3. 20-base exact match inside a 30-base target
        q='0; t='0;
        for(int i=0;i<20;i++) begin q[i]=base_t'(i%4); t[i+5]=base_t'(i%4); end
        c = mk_cfg(20,30); check(q,t,c,"match20/in30");

        // 4-13. randomized small alignments
        for (int n=0; n<10; n++) begin
            int ql, tl;
            ql = 1 + ($urandom % 32);
            tl = ql + ($urandom % 32);
            q='0; t='0;
            for (int i=0;i<ql;i++) q[i] = base_t'($urandom % 4);
            for (int i=0;i<tl;i++) t[i] = base_t'($urandom % 4);
            c = mk_cfg(len_t'(ql), len_t'(tl));
            check(q,t,c,$sformatf("rand[q=%0d,t=%0d]",ql,tl));
        end

        $display("==== tb_bsw_axil: %0d pass, %0d fail ====", pass, fail);
        if (fail==0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    // safety timeout
    initial begin #2_000_000; $display("TIMEOUT"); $finish; end
endmodule
