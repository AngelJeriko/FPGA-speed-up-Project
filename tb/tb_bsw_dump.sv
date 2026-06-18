// tb_bsw_dump.sv — single-case H-cell dump for debugging bsw_top vs ksw.
// Hardcodes failing case [19] (qlen=6 tlen=7 h0=143) and prints, each cycle,
// every valid PE cell whose H exceeds a threshold, with the tracker's inferred
// (row,col). True max is 144 @ (5,5); RTL reports 145, so we hunt the phantom.
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_dump
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;
    logic req_valid, req_ready;
    base_t [MAX_QLEN-1:0] query;
    base_t [MAX_TLEN-1:0] target;
    bsw_config_t cfg;
    logic result_valid, result_ready;
    bsw_result_t result;

    bsw_top dut(.clk,.rst_n,.req_valid_i(req_valid),.req_ready_o(req_ready),
        .query_i(query),.target_i(target),.cfg_i(cfg),
        .result_valid_o(result_valid),.result_ready_i(result_ready),.result_o(result));

    int qa[6] = '{1,3,3,2,3,0};
    int ta[7] = '{3,3,3,2,3,0,0};
    int i;

    // per-cycle dump of array cell taps (threshold to cut noise)
    int cyc; logic dumping;
    always_ff @(posedge clk) begin
        if (!rst_n) begin cyc<=0; end
        else begin
            if (dut.u_fsm.tr_start_o) cyc<=1;
            else if (cyc!=0) cyc<=cyc+1;
            if (dumping) begin
                for (int k=0;k<8;k++) begin
                    if (dut.cell_valid[k] && $signed(dut.h_cells[k]) >= 140)
                        $display("cyc=%0d PE%0d row=%0d H=%0d (E=%0d)",
                            cyc, k, (cyc-1-k), $signed(dut.h_cells[k]), $signed(dut.e_cells[k]));
                end
            end
        end
    end

    initial begin
        rst_n=0; req_valid=0; result_ready=1; dumping=0;
        query='{default:base_t'(4)}; target='{default:base_t'(4)}; cfg='{default:'0};
        repeat(5) @(posedge clk); rst_n=1; @(posedge clk);
        for (i=0;i<6;i++) query[i]=base_t'(qa[i]);
        for (i=0;i<7;i++) target[i]=base_t'(ta[i]);
        cfg.h0=score_t'(143); cfg.o_del=6; cfg.e_del=1; cfg.o_ins=6; cfg.e_ins=1;
        cfg.zdrop=100; cfg.end_bonus=5; cfg.w=100; cfg.qlen=6; cfg.tlen=7;
        dumping=1;
        @(posedge clk); wait(req_ready); @(posedge clk);
        req_valid=1; @(posedge clk); req_valid=0;
        wait(result_valid); @(posedge clk);
        $display("RESULT score=%0d qle=%0d tle=%0d gscore=%0d gtle=%0d max_off=%0d err=%0b",
            $signed(result.score),result.qle,result.tle,$signed(result.gscore),
            result.gtle,result.max_off,result.error);
        $finish;
    end
    initial begin #100000; $display("timeout"); $finish; end
endmodule
