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
        .restart_mode   (1'b0),
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

    // ---- DONE -> IDLE transition sampler (B speedup verification) ----
    // Latches if the FSM ever passes through S_IDLE between two alignments.
    // For the back-to-back test (T9) we hold req_valid high so the FSM
    // should take the direct S_DONE -> S_LOAD path; visiting S_IDLE means
    // the handoff did not happen. Cleared by t9_sampler_clear.
    logic t9_done_to_idle;
    logic t9_sampler_clear = 1'b0;
    always_ff @(posedge clk) begin
        if (!rst_n || t9_sampler_clear)
            t9_done_to_idle <= 1'b0;
        else if (dut.u_fsm.state_q == 3'd4 /* S_DONE */ &&
                 dut.u_fsm.state   == 3'd0 /* S_IDLE */)
            t9_done_to_idle <= 1'b1;
    end

    // ---- z-drop pulse sampler ----
    // Latches if u_tracker.zdrop_break_o ever asserts during S_RUN. We gate on
    // state==S_RUN (=3'd2) because zdrop_break_o is sticky inside the tracker
    // — it stays high after firing until the NEXT alignment clears it. Without
    // the state gate we'd see leftover assertions in the IDLE/LOAD window
    // between tests and contaminate the negative-control assertion.
    logic zdrop_seen;
    logic zdrop_clear = 1'b0;
    always_ff @(posedge clk) begin
        if (!rst_n || zdrop_clear)
            zdrop_seen <= 1'b0;
        else if (dut.u_tracker.zdrop_break_o && (dut.u_fsm.state == 3'd2))
            zdrop_seen <= 1'b1;
    end

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

    task automatic load_config(input int qlen, input int tlen, input int zdrop = 0);
        // BWA-MEM2 is a seed-extension algorithm: h0 is the carry-in seed score.
        // With h0=0 the gate kills every cell. Use h0=1 here so the DP can start.
        cfg.h0        = score_t'(1);
        cfg.o_del     = score_t'(W_O_DEL);
        cfg.e_del     = score_t'(W_E_DEL);
        cfg.o_ins     = score_t'(W_O_INS);
        cfg.e_ins     = score_t'(W_E_INS);
        cfg.zdrop     = score_t'(zdrop);  // 0 = disabled (default)
        cfg.end_bonus = score_t'(0);
        cfg.w         = len_t'(BAND_WIDTH);
        cfg.qlen      = len_t'(qlen);
        cfg.tlen      = len_t'(tlen);
        // Reset the z-drop pulse sampler so the next alignment starts fresh.
        @(negedge clk);
        zdrop_clear = 1'b1;
        @(negedge clk);
        zdrop_clear = 1'b0;
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
        // Test 5: Dedicated z-drop early-exit (positive case).
        // query = AAAAAAAA (8x A), target = AAAAAAAATTTTTTTT.
        // Diagonal cells (k,k) = h0 + k + 1 climb to H(7,7) = 9.
        // When row 0's tail graduates (stage qlen-1 = 7), glob_max has already
        // climbed past row 0's m via the wavefront, so the row-0 tail check
        // triggers z-drop with this aggressive threshold (zdrop=1).
        // After the FSM exits S_RUN, the drain phase still runs long enough
        // for the wavefront cells already in flight (including the diagonal
        // peak (7,7)) to graduate into glob_max — so the SCORE stays correct.
        // What z-drop saves is the extra S_RUN cycles that would have fed the
        // tail target bases into PE_0.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,A,A,A,A,A,A,A};
            bit [2:0] t[$] = '{A,A,A,A,A,A,A,A,T,T,T,T,T,T,T,T};
            set_query(8, q);
            set_target(16, t);
            load_config(8, 16, 1);   // zdrop = 1 (aggressive)
            submit_and_wait();
            check("T5 zdrop score (peak preserved)", result.score,  9);
            check("T5 zdrop qle  (peak col+1)",      result.qle,    8);
            check("T5 zdrop tle  (peak row+1)",      result.tle,    8);
            check("T5 zdrop fired",                  zdrop_seen,    1);
        end

        // ----------------------------------------------------------------
        // Test 6: z-drop disabled (negative control).
        // Same sequence as T5 but zdrop=0. The early-exit gate is
        // unconditionally false, so zdrop_seen must stay 0. The alignment
        // still produces the same final score (z-drop only changes WHEN we
        // stop, not WHAT the running max is).
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,A,A,A,A,A,A,A};
            bit [2:0] t[$] = '{A,A,A,A,A,A,A,A,T,T,T,T,T,T,T,T};
            set_query(8, q);
            set_target(16, t);
            load_config(8, 16, 0);   // zdrop = 0 (disabled)
            submit_and_wait();
            check("T6 no-zdrop score (same as T5)",  result.score,  9);
            check("T6 no-zdrop did NOT fire",        zdrop_seen,    0);
        end

        // ----------------------------------------------------------------
        // Test 7: Oversize-request rejection (qlen > N_PE).
        // N_PE = BAND_WIDTH = 64. Submit qlen = 65 and verify the FSM
        // rejects: result.error == 1, score == 0, no hang.
        // The query/target contents are immaterial — the FSM bypasses
        // S_LOAD/S_RUN/S_DRAIN entirely via S_REJECT.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A};   // contents don't matter
            bit [2:0] t[$] = '{A};
            set_query(1, q);
            set_target(1, t);
            load_config(BAND_WIDTH + 1, 1, 0);   // qlen = N_PE + 1 = oversize
            submit_and_wait();
            check("T7 oversize error bit set",   result.error,  1);
            check("T7 oversize score zeroed",    result.score,  0);
            check("T7 oversize qle zeroed",      result.qle,    0);
            check("T7 oversize tle zeroed",      result.tle,    0);
        end

        // ----------------------------------------------------------------
        // Test 8: Boundary acceptance: confirm a previously-valid request
        // following T7 still works (rejection state is not sticky).
        // Reuse T1's perfect-match setup; expect identical results.
        // ----------------------------------------------------------------
        begin
            bit [2:0] q[$] = '{A,C,G,T};
            bit [2:0] t[$] = '{A,C,G,T};
            set_query(4, q);
            set_target(4, t);
            load_config(4, 4);
            submit_and_wait();
            check("T8 post-reject error clear",  result.error,  0);
            check("T8 post-reject score",        result.score,  5);
        end

        // ----------------------------------------------------------------
        // Test 9: Back-to-back direct DONE -> LOAD handoff (B speedup).
        // Submit alignment A; while A is processing, swap inputs to B and
        // hold req_valid high. The FSM should latch B in the same cycle it
        // emits A's result, skipping the IDLE wait.
        // A = ACGT/ACGT  (expect score=5)
        // B = AAAA/CCCC  (expect score=1, all-mismatch dead-row)
        // Sampler t9_done_to_idle must remain 0 — the FSM should never
        // enter IDLE between A and B.
        // ----------------------------------------------------------------
        begin
            bit [2:0] qA[$] = '{A,C,G,T};
            bit [2:0] tA[$] = '{A,C,G,T};
            bit [2:0] qB[$] = '{A,A,A,A};
            bit [2:0] tB[$] = '{C,C,C,C};

            // Clear the transition sampler
            @(negedge clk);
            t9_sampler_clear = 1'b1;
            @(negedge clk);
            t9_sampler_clear = 1'b0;

            // Submit A
            set_query(4, qA);
            set_target(4, tA);
            load_config(4, 4);
            @(posedge clk);
            wait (req_ready);
            @(posedge clk);
            req_valid = 1'b1;
            @(posedge clk);   // A's request latched here; FSM is now in S_LOAD

            // Swap inputs to B while A processes. req_valid stays high so the
            // FSM picks up B during A's DONE cycle.
            set_query(4, qB);
            set_target(4, tB);
            load_config(4, 4);

            // Wait for A's result
            wait (result_valid);
            check("T9 A score (ACGT/ACGT)",      result.score,    5);
            @(posedge clk);   // host consumes A; direct path: state -> S_LOAD for B

            // Wait for B's result (result_valid drops as state leaves DONE, then
            // rises again when B reaches DONE)
            wait (!result_valid);
            wait (result_valid);
            check("T9 B score (AAAA/CCCC)",      result.score,    1);
            @(posedge clk);
            req_valid = 1'b0;

            // Verify the direct handoff: no DONE -> IDLE transition in T9
            check("T9 no IDLE between A and B",  t9_done_to_idle, 0);
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
