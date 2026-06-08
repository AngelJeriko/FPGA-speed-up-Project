// tb_bsw_axis.sv
// Loopback self-checking testbench for bsw_axis_adapter.
//
// Serializes a request onto the slave AXIS port, waits for the master AXIS
// result beat, deserializes it, and checks score / error / tag against
// known-good values reused from tb_bsw_top.

`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_axis
    import bsw_pkg::*;
();

    // ---- Parameters mirrored from DUT ----
    localparam int AXIS_DATA_WIDTH = 256;
    localparam int TAG_WIDTH       = 16;
    localparam int CFG_BITS        = $bits(bsw_config_t);
    localparam int RES_BITS        = $bits(bsw_result_t);
    localparam int BASES_PER_BEAT  = AXIS_DATA_WIDTH / 4;
    localparam int QRY_BEATS       = (MAX_QLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT;
    localparam int TGT_BEATS       = (MAX_TLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT;

    // ---- Clock / reset ----
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT I/O ----
    logic                            s_axis_tvalid;
    logic                            s_axis_tready;
    logic [AXIS_DATA_WIDTH-1:0]      s_axis_tdata;
    logic                            s_axis_tlast;

    logic                            m_axis_tvalid;
    logic                            m_axis_tready;
    logic [AXIS_DATA_WIDTH-1:0]      m_axis_tdata;
    logic                            m_axis_tlast;

    bsw_axis_adapter #(
        .AXIS_DATA_WIDTH (AXIS_DATA_WIDTH),
        .TAG_WIDTH       (TAG_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tready   (s_axis_tready),
        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tlast    (s_axis_tlast),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tlast    (m_axis_tlast)
    );

    // ---- Bookkeeping ----
    int errors = 0;
    int checks = 0;

    task automatic check(input string name,
                         input int got,
                         input int expected);
        checks++;
        if (got !== expected) begin
            errors++;
            $display("[FAIL] %-40s got=%0d expected=%0d", name, got, expected);
        end else begin
            $display("[ OK ] %-40s = %0d", name, got);
        end
    endtask

    task automatic do_reset();
        rst_n          = 1'b0;
        s_axis_tvalid  = 1'b0;
        s_axis_tdata   = '0;
        s_axis_tlast   = 1'b0;
        m_axis_tready  = 1'b1;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // ---- Beat builders ----
    function automatic logic [AXIS_DATA_WIDTH-1:0]
            make_hdr(bsw_config_t cfg, logic [TAG_WIDTH-1:0] tag);
        logic [AXIS_DATA_WIDTH-1:0] beat;
        beat = '0;
        beat[CFG_BITS-1:0]                 = cfg;
        beat[CFG_BITS+TAG_WIDTH-1 -: TAG_WIDTH] = tag;
        return beat;
    endfunction

    function automatic logic [AXIS_DATA_WIDTH-1:0]
            make_seq_beat(input base_t arr[],
                          input int     beat_idx,
                          input int     max_len);
        logic [AXIS_DATA_WIDTH-1:0] beat;
        int idx;
        beat = '0;
        for (int k = 0; k < BASES_PER_BEAT; k++) begin
            idx = beat_idx * BASES_PER_BEAT + k;
            if (idx < max_len) beat[k*4 +: BASE_WIDTH] = arr[idx];
        end
        return beat;
    endfunction

    // ---- Send / receive ----
    task automatic send_beat(input logic [AXIS_DATA_WIDTH-1:0] data,
                             input logic                       is_last);
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tdata  = data;
        s_axis_tlast  = is_last;
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    task automatic send_request(input bsw_config_t cfg,
                                input logic [TAG_WIDTH-1:0] tag,
                                input base_t  query  [MAX_QLEN],
                                input base_t  target [MAX_TLEN]);
        base_t qtmp [];
        base_t ttmp [];
        // Convert fixed-size arrays to dynamic for the helper. Verilator
        // accepts assigning a fixed-size unpacked array to a dynamic one of
        // matching element type.
        qtmp = new[MAX_QLEN];
        ttmp = new[MAX_TLEN];
        foreach (query[i])  qtmp[i] = query[i];
        foreach (target[i]) ttmp[i] = target[i];

        send_beat(make_hdr(cfg, tag), 1'b0);
        for (int b = 0; b < QRY_BEATS; b++) begin
            send_beat(make_seq_beat(qtmp, b, MAX_QLEN), 1'b0);
        end
        for (int b = 0; b < TGT_BEATS; b++) begin
            send_beat(make_seq_beat(ttmp, b, MAX_TLEN),
                      (b == TGT_BEATS - 1));
        end
    endtask

    task automatic recv_result(output bsw_result_t        result,
                               output logic [TAG_WIDTH-1:0] tag);
        do @(posedge clk); while (!(m_axis_tvalid && m_axis_tready));
        result = m_axis_tdata[RES_BITS-1:0];
        tag    = m_axis_tdata[127:112];
    endtask

    // ---- Test helpers ----
    function automatic bsw_config_t default_cfg(input int qlen,
                                                input int tlen);
        bsw_config_t c;
        c.h0        = score_t'(1);
        c.o_del     = score_t'(W_O_DEL);
        c.e_del     = score_t'(W_E_DEL);
        c.o_ins     = score_t'(W_O_INS);
        c.e_ins     = score_t'(W_E_INS);
        c.zdrop     = score_t'(0);
        c.end_bonus = score_t'(0);
        c.w         = len_t'(BAND_WIDTH);
        c.qlen      = len_t'(qlen);
        c.tlen      = len_t'(tlen);
        return c;
    endfunction

    // ---- Main ----
    bsw_config_t cfg;
    base_t       q [MAX_QLEN];
    base_t       t [MAX_TLEN];
    bsw_result_t res;
    logic [TAG_WIDTH-1:0] rxtag;

    initial begin
        $display("==== tb_bsw_axis starting ====");
        do_reset();

        // ---------------- T1: ACGT / ACGT, score=5, tag echo ----------------
        for (int i = 0; i < MAX_QLEN; i++) q[i] = '0;
        for (int i = 0; i < MAX_TLEN; i++) t[i] = '0;
        q[0] = 3'd0; q[1] = 3'd1; q[2] = 3'd2; q[3] = 3'd3;   // A C G T
        t[0] = 3'd0; t[1] = 3'd1; t[2] = 3'd2; t[3] = 3'd3;
        cfg = default_cfg(4, 4);
        fork
            send_request(cfg, 16'hCAFE, q, t);
            recv_result(res, rxtag);
        join
        check("T1 score (ACGT/ACGT)",          int'($signed(res.score)), 5);
        check("T1 error",                      int'(res.error),          0);
        check("T1 tag echo",                   int'(rxtag),              16'hCAFE);

        // ---------------- T2: AAAA / CCCC, all mismatches, score=h0=1 ----------------
        for (int i = 0; i < MAX_QLEN; i++) q[i] = '0;
        for (int i = 0; i < MAX_TLEN; i++) t[i] = '0;
        q[0] = 3'd0; q[1] = 3'd0; q[2] = 3'd0; q[3] = 3'd0;   // A A A A
        t[0] = 3'd1; t[1] = 3'd1; t[2] = 3'd1; t[3] = 3'd1;   // C C C C
        cfg = default_cfg(4, 4);
        fork
            send_request(cfg, 16'hBEEF, q, t);
            recv_result(res, rxtag);
        join
        check("T2 score (AAAA/CCCC)",          int'($signed(res.score)), 1);
        check("T2 error",                      int'(res.error),          0);
        check("T2 tag echo",                   int'(rxtag),              16'hBEEF);

        // ---------------- T3: oversize query -> error=1, score=0 ----------------
        for (int i = 0; i < MAX_QLEN; i++) q[i] = (i < 100) ? 3'd0 : '0;
        for (int i = 0; i < MAX_TLEN; i++) t[i] = (i <   8) ? 3'd0 : '0;
        cfg = default_cfg(100, 8);   // qlen=100 > N_PE=64 -> reject
        fork
            send_request(cfg, 16'h1234, q, t);
            recv_result(res, rxtag);
        join
        check("T3 error (oversize)",           int'(res.error),          1);
        check("T3 score forced 0",             int'($signed(res.score)), 0);
        check("T3 tag echo (oversize)",        int'(rxtag),              16'h1234);

        // ---------------- T4: back-to-back recovery, T1-style again ----------------
        for (int i = 0; i < MAX_QLEN; i++) q[i] = '0;
        for (int i = 0; i < MAX_TLEN; i++) t[i] = '0;
        q[0] = 3'd0; q[1] = 3'd1; q[2] = 3'd2; q[3] = 3'd3;
        t[0] = 3'd0; t[1] = 3'd1; t[2] = 3'd2; t[3] = 3'd3;
        cfg = default_cfg(4, 4);
        fork
            send_request(cfg, 16'hFACE, q, t);
            recv_result(res, rxtag);
        join
        check("T4 score (recovery)",           int'($signed(res.score)), 5);
        check("T4 error",                      int'(res.error),          0);
        check("T4 tag echo (recovery)",        int'(rxtag),              16'hFACE);

        $display("==== tb_bsw_axis done: %0d checks, %0d errors ====", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    // Safety watchdog
    initial begin
        #200000;
        $display("[FAIL] watchdog timeout");
        $finish;
    end

endmodule
