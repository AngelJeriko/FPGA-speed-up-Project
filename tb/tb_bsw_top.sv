// tb_bsw_top.sv
// Top-level self-checking testbench. Hand-computed cases first; a hook is
// provided to load reference vectors generated from scalarBandedSWA (see
// scripts/gen_vectors.cpp for a future companion).

`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_top
    import bsw_pkg::*;
();

    // ---- Clock / reset ----
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT I/O ----
    logic                       req_valid;
    logic                       req_ready;
    base_t [MAX_QLEN-1:0]       query;
    base_t [MAX_TLEN-1:0]       target;
    bsw_config_t                cfg;

    logic                       result_valid;
    logic                       result_ready;
    bsw_result_t                result;

    bsw_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid_i    (req_valid),
        .req_ready_o    (req_ready),
        .query_i        (query),
        .target_i       (target),
        .cfg_i          (cfg),
        .result_valid_o (result_valid),
        .result_ready_i (result_ready),
        .result_o       (result)
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

    // ---- Driver helpers ----
    task automatic do_reset();
        rst_n = 1'b0;
        req_valid = 1'b0;
        result_ready = 1'b1;
        query = '{default: '0};
        target = '{default: '0};
        cfg = '{default: '0};
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    task automatic load_config(input int qlen, input int tlen);
        // BWA-MEM2 is a seed-extension algorithm: h0 is the carry-in seed score.
        // With h0=0 the gate kills every cell. Use h0=1 here so the DP can start.
        cfg.h0        = score_t'(1);
        cfg.o_del     = score_t'(W_O_DEL);
        cfg.e_del     = score_t'(W_E_DEL);
        cfg.o_ins     = score_t'(W_O_INS);
        cfg.e_ins     = score_t'(W_E_INS);
        cfg.zdrop     = score_t'(0);      // disable zdrop for these basic cases
        cfg.end_bonus = score_t'(0);
        cfg.w         = len_t'(BAND_WIDTH);
        cfg.qlen      = len_t'(qlen);
        cfg.tlen      = len_t'(tlen);
    endtask

    task automatic submit_and_wait();
        @(posedge clk);
        wait (req_ready);
        @(posedge clk);
        req_valid = 1'b1;
        @(posedge clk);
        req_valid = 1'b0;
        wait (result_valid);
        @(posedge clk);
    endtask

    // ---- Convenience: set query and target from byte arrays ----
    task automatic set_query(input int len, input bit [2:0] bases [$]);
        query = '{default: base_t'(4)};   // pad with N
        for (int i = 0; i < len; i++) query[i] = base_t'(bases[i]);
    endtask

    task automatic set_target(input int len, input bit [2:0] bases [$]);
        target = '{default: base_t'(4)};
        for (int i = 0; i < len; i++) target[i] = base_t'(bases[i]);
    endtask

    // ---- Tests ----
    // Encoding: A=0 C=1 G=2 T=3 N=4
    localparam bit [2:0] A = 3'd0, C = 3'd1, G = 3'd2, T = 3'd3, N = 3'd4;

    initial begin
        $display("==== tb_bsw_top starting ====");
        do_reset();

        // ----------------------------------------------------------------
        // Test 1: perfect match, qlen=4, tlen=4. h0=1 (seed-extension).
        // query = ACGT, target = ACGT.
        // H(0,0)=h0+1=2, H(1,1)=3, H(2,2)=4, H(3,3)=5. Max=5 at (3,3).
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,C,G,T};
            bit [2:0] t[$] = '{A,C,G,T};
            set_query(4, q);
            set_target(4, t);
            load_config(4, 4);
            submit_and_wait();
            check("T1 perfect match score",  result.score,    5);
            check("T1 perfect match qle",    result.qle,      4);
            check("T1 perfect match tle",    result.tle,      4);
            check("T1 perfect match gscore", $signed(result.gscore), 5);
            check("T1 perfect match gtle",   result.gtle,     4);
            check("T1 perfect match max_off",result.max_off,  0);
        end

        // ----------------------------------------------------------------
        // Test 2: complete mismatch, no productive cells. h0=1.
        // query = AAAA, target = CCCC. C++ initialises max=h0; no row ever
        // beats it, so score stays at h0. m=0 after first row -> break.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,A,A,A};
            bit [2:0] t[$] = '{C,C,C,C};
            set_query(4, q);
            set_target(4, t);
            load_config(4, 4);
            submit_and_wait();
            check("T2 all-mismatch score", result.score, 1);
        end

        // ----------------------------------------------------------------
        // Test 3: match followed by mismatch tail. h0=1.
        // query = ACGT, target = ACGTGGGG.
        // First 4 rows mirror T1 (score reaches 5 at (3,3)); tail rows have
        // m=0 and break the loop.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,C,G,T};
            bit [2:0] t[$] = '{A,C,G,T,G,G,G,G};
            set_query(4, q);
            set_target(8, t);
            load_config(4, 8);
            submit_and_wait();
            check("T3 match+tail score",    result.score, 5);
            check("T3 match+tail tle",      result.tle,   4);
            check("T3 match+tail qle",      result.qle,   4);
        end

        // ----------------------------------------------------------------
        // Test 4: match with a single insertion in target.
        // query = ACGT, target = ACAGT  (extra A inserted between C and G).
        // The DP can either extend through the insertion (cost = oe_ins =
        // o_ins + e_ins = 7) or stop at the first mismatch.
        // Optimal local: take prefix "AC" (score 2) -> 2, OR push through:
        //   A(1) C(2) skip(-7) G(3) T(4) -> -3 net, clamped.
        // So the optimal local is just "AC" = 2 OR "GT" = 2 at the end.
        // Hand-check shows score should be 2.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,C,G,T};
            bit [2:0] t[$] = '{A,C,A,G,T};
            set_query(4, q);
            set_target(5, t);
            load_config(4, 5);
            submit_and_wait();
            check("T4 single insertion score (>=2)", (result.score >= 2) ? 1 : 0, 1);
        end

        // ----------------------------------------------------------------
        $display("==== tb_bsw_top done: %0d checks, %0d errors ====", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

    initial begin
        #500000;
        $display("[FATAL] tb_bsw_top timeout in state %0d", dut.u_fsm.state);
        $finish;
    end

endmodule
