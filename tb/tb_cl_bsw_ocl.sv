// tb_cl_bsw_ocl.sv  (board-bringup track)
// -----------------------------------------------------------------------------
// Simulates the F1 CL wrapper cl_bsw_top through its OCL AXI4-Lite port set (the
// exact signals the AWS Shell drives), proving the OCL->bsw_axil_regs bridge +
// reset synchroniser are transparent to bsw_top. Same transparency property as
// tb_bsw_axil (DUT vs bare bsw_top REF), but exercising the CL wrapper, not the
// bare register file -- so a typo in the OCL rename or the rst sync shows up here.
//
// Compile cl_bsw_top with +define+CL_BSW_LINT (self-contained OCL port list, no HDK).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_cl_bsw_ocl
    import bsw_pkg::*;
;
    localparam int ADDR_W = 16, DATA_W = 32;
    localparam int QRY_BITS = MAX_QLEN*BASE_WIDTH,  TGT_BITS = MAX_TLEN*BASE_WIDTH;
    localparam int CFG_BITS = $bits(bsw_config_t),  RES_BITS = $bits(bsw_result_t);
    localparam int QRY_WORDS = (QRY_BITS+DATA_W-1)/DATA_W;
    localparam int TGT_WORDS = (TGT_BITS+DATA_W-1)/DATA_W;
    localparam int CFG_WORDS = (CFG_BITS+DATA_W-1)/DATA_W;
    localparam int RES_WORDS = (RES_BITS+DATA_W-1)/DATA_W;

    localparam [15:0] A_CTRL=16'h000, A_STAT=16'h004, A_CFG=16'h010,
                      A_QRY=16'h100, A_TGT=16'h200, A_RES=16'h400;

    logic clk=0, rst_n=0;
    always #5 clk = ~clk;

    // ---- AXI-Lite bus (local); connected to cl_bsw_top's OCL ports below ----
    logic [ADDR_W-1:0] awaddr, araddr;
    logic [DATA_W-1:0] wdata, rdata;
    logic [DATA_W/8-1:0] wstrb;
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic arvalid, arready, rvalid, rready;
    logic [1:0] bresp, rresp;

    // DUT = the F1 CL wrapper, driven exactly as the Shell OCL master would.
    // (sh_ocl_* = Shell->CL, ocl_sh_* = CL->Shell; addr padded to the 32-bit OCL width.)
    cl_bsw_top dut (
        .clk_main_a0(clk), .rst_main_n(rst_n),
        .sh_ocl_awaddr({16'b0, awaddr}), .sh_ocl_awvalid(awvalid), .ocl_sh_awready(awready),
        .sh_ocl_wdata(wdata), .sh_ocl_wstrb(wstrb), .sh_ocl_wvalid(wvalid), .ocl_sh_wready(wready),
        .ocl_sh_bresp(bresp), .ocl_sh_bvalid(bvalid), .sh_ocl_bready(bready),
        .sh_ocl_araddr({16'b0, araddr}), .sh_ocl_arvalid(arvalid), .ocl_sh_arready(arready),
        .ocl_sh_rdata(rdata), .ocl_sh_rresp(rresp), .ocl_sh_rvalid(rvalid), .sh_ocl_rready(rready)
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

    task automatic run_ref(input base_t [MAX_QLEN-1:0] q, input base_t [MAX_TLEN-1:0] t,
                           input bsw_config_t c, output bsw_result_t r);
        @(posedge clk); rf_q = q; rf_t = t; rf_cfg = c;
        @(posedge clk); wait (rf_reqr); @(posedge clk);
        rf_reqv = 1'b1; @(posedge clk); rf_reqv = 1'b0;
        wait (rf_resv); @(posedge clk);
        r = rf_res;
    endtask

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
        axil_write(A_CTRL, 32'h1);
        forever begin axil_read(A_STAT, w); if (w[1]) break; end
        rf = '0;
        for (int i = 0; i < RES_WORDS; i++) axil_read(A_RES + i*4, rf[i*DATA_W +: DATA_W]);
        r = rf[RES_BITS-1:0];
    endtask

    function automatic bsw_config_t mk_cfg(input len_t qlen, input len_t tlen);
        bsw_config_t c;
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
            $display("[FAIL] %-22s REF{score=%0d qle=%0d tle=%0d} DUT{score=%0d qle=%0d tle=%0d}",
                     name, rr.score, rr.qle, rr.tle, rd.score, rd.qle, rd.tle);
        end
    endtask

    base_t [MAX_QLEN-1:0] q; base_t [MAX_TLEN-1:0] t; bsw_config_t c;
    initial begin
        awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; wstrb=0;
        rf_reqv=0; rf_resr=1'b1; rf_q='0; rf_t='0; rf_cfg='0;
        repeat (5) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        q='0; t='0; q[0]=0;q[1]=1;q[2]=2;q[3]=3; t[0]=0;t[1]=1;t[2]=2;t[3]=3;
        c = mk_cfg(4,4); check(q,t,c,"ACGT/ACGT");

        q='0; t='0; for(int i=0;i<4;i++) begin q[i]=0; t[i]=1; end
        c = mk_cfg(4,4); check(q,t,c,"AAAA/CCCC");

        q='0; t='0;
        for(int i=0;i<20;i++) begin q[i]=base_t'(i%4); t[i+5]=base_t'(i%4); end
        c = mk_cfg(20,30); check(q,t,c,"match20/in30");

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

        $display("==== tb_cl_bsw_ocl: %0d pass, %0d fail ====", pass, fail);
        if (fail==0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT"); $finish; end
endmodule
