// tb_bsw_pe.sv
// Self-checking testbench for bsw_pe.
// Designed to run under both Icarus Verilog and Verilator (--binary).

`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_bsw_pe
    import bsw_pkg::*;
();

    // ---- Clock / reset ----
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- DUT I/O ----
    logic   clear_i;
    logic   load_q_i;
    base_t  query_base_i;
    score_t o_del_i, e_del_i, o_ins_i, e_ins_i;
    logic   active_i;
    base_t  target_i;
    score_t h_diag_i, f_i;

    logic   active_o;
    base_t  target_o;
    score_t h_diag_o, h_left_o, f_o;
    logic   cell_valid_o;
    score_t h_cell_o, e_cell_o;

    bsw_pe dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear_i      (clear_i),
        .load_q_i     (load_q_i),
        .query_base_i (query_base_i),
        .init_h_curr_i(score_t'(0)),   // PE tests don't exercise the seed init
        .o_del_i      (o_del_i),
        .e_del_i      (e_del_i),
        .o_ins_i      (o_ins_i),
        .e_ins_i      (e_ins_i),
        .active_i     (active_i),
        .target_i     (target_i),
        .h_diag_i     (h_diag_i),
        .f_i          (f_i),
        .active_o     (active_o),
        .target_o     (target_o),
        .h_diag_o     (h_diag_o),
        .h_left_o     (h_left_o),
        .f_o          (f_o),
        .cell_valid_o (cell_valid_o),
        .h_cell_o     (h_cell_o),
        .e_cell_o     (e_cell_o)
    );

    // ---- Bookkeeping ----
    int errors = 0;
    int checks = 0;

    task automatic check(input string name,
                         input score_t got,
                         input score_t expected);
        checks++;
        if (got !== expected) begin
            errors++;
            $display("[FAIL] %-32s got=%0d expected=%0d", name, got, expected);
        end else begin
            $display("[ OK ] %-32s = %0d", name, got);
        end
    endtask

    // ---- Helpers ----
    // Drive one cycle of input, then sample DUT 1 cycle later (PE outputs are registered).
    task automatic drive_cell(input logic active,
                              input base_t tgt,
                              input score_t h_diag,
                              input score_t f_in);
        @(negedge clk);
        active_i = active;
        target_i = tgt;
        h_diag_i = h_diag;
        f_i      = f_in;
    endtask

    task automatic idle_cell();
        drive_cell(1'b0, '0, '0, '0);
    endtask

    task automatic do_reset();
        rst_n = 1'b0;
        clear_i = 1'b0;
        load_q_i = 1'b0;
        active_i = 1'b0;
        target_i = '0;
        h_diag_i = '0;
        f_i      = '0;
        query_base_i = '0;
        o_del_i = score_t'(W_O_DEL);
        e_del_i = score_t'(W_E_DEL);
        o_ins_i = score_t'(W_O_INS);
        e_ins_i = score_t'(W_E_INS);
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    task automatic load_query(input base_t q);
        @(negedge clk);
        load_q_i = 1'b1;
        query_base_i = q;
        @(negedge clk);
        load_q_i = 1'b0;
    endtask

    task automatic clear_state();
        // Also idle the wavefront inputs so the cycle between clear and the next
        // drive_cell doesn't sneak a stale-input compute into the cleared state.
        @(negedge clk);
        clear_i  = 1'b1;
        active_i = 1'b0;
        target_i = '0;
        h_diag_i = '0;
        f_i      = '0;
        @(negedge clk);
        clear_i  = 1'b0;
    endtask

    // ---- Tests ----
    // Encoding: A=0, C=1, G=2, T=3, N=4
    localparam base_t A = 3'd0;
    localparam base_t C = 3'd1;
    localparam base_t G = 3'd2;
    localparam base_t T = 3'd3;
    localparam base_t N = 3'd4;

    initial begin
        $display("==== tb_bsw_pe starting ====");

        do_reset();

        // ----------------------------------------------------------------
        // Test 1: Match. q=A, t=A, H_diag=10, F=0, E starts at 0.
        // Expected: M = 10 + 1 = 11, H_new = max(11, 0, 0, 0) = 11.
        //           E_new = max(11-(6+1), 0-1, 0) = max(4, -1, 0) = 4
        //           F_new = max(11-(6+1), 0-1, 0) = 4
        // ----------------------------------------------------------------
        load_query(A);
        clear_state();
        drive_cell(1'b1, A, score_t'(10), score_t'(0));
        @(posedge clk); #1;
        check("T1 match H",     h_cell_o, score_t'(11));
        check("T1 match E",     e_cell_o, score_t'(4));
        check("T1 match F_out", f_o,      score_t'(4));

        // ----------------------------------------------------------------
        // Test 2: Mismatch. q=A, t=C, H_diag=10. Mismatch score = -4.
        // M = 10 + (-4) = 6. H_new = max(6, 0, 0, 0) = 6.
        // E_new = max(6-7, -1, 0) = 0;  F_new = 0.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, C, score_t'(10), score_t'(0));
        @(posedge clk); #1;
        check("T2 mismatch H",     h_cell_o, score_t'(6));
        check("T2 mismatch E",     e_cell_o, score_t'(0));
        check("T2 mismatch F_out", f_o,      score_t'(0));

        // ----------------------------------------------------------------
        // Test 3: E dominates. q=A, t=A, H_diag=1 (M=2), F_in=0, but
        // we need E to be already high. Run a priming match first so E builds up.
        // ----------------------------------------------------------------
        clear_state();
        // Prime: H_diag=20 match → M=21 → H=21 → E=21-7=14
        drive_cell(1'b1, A, score_t'(20), score_t'(0));
        @(posedge clk); #1;
        // Now drive a weak match so E (=14) wins over M
        // q=A, t=A again, H_diag=2 → M=3. F=0. E_reg should be 14.
        // H_new = max(3, 14, 0, 0) = 14.
        drive_cell(1'b1, A, score_t'(2), score_t'(0));
        @(posedge clk); #1;
        check("T3 E dominates H", h_cell_o, score_t'(14));

        // ----------------------------------------------------------------
        // Test 4: F dominates. q=A, t=A, H_diag=0 (so M=0), F_in=9.
        // H_new = max(0, E, 9, 0). E must be < 9; after a clear it's 0.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, A, score_t'(0), score_t'(9));
        @(posedge clk); #1;
        check("T4 F dominates H", h_cell_o, score_t'(9));

        // ----------------------------------------------------------------
        // Test 5: Semi-global trick. H_diag=0 means M=0 even if there's a match
        // that would otherwise add +1. q=A, t=A, H_diag=0, F=0, E=0.
        // M = 0 (since H_diag is zero), H_new = max(0,0,0,0) = 0.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, A, score_t'(0), score_t'(0));
        @(posedge clk); #1;
        check("T5 semi-global zero", h_cell_o, score_t'(0));

        // ----------------------------------------------------------------
        // Test 6: Local clamp. All-negative drivers should clamp to 0.
        // q=A, t=C (mismatch -4), H_diag=1 → M = 1 + (-4) = -3.
        // F_in = 0, E_reg = 0. H_new = max(-3, 0, 0, 0) = 0.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, C, score_t'(1), score_t'(0));
        @(posedge clk); #1;
        check("T6 local clamp H", h_cell_o, score_t'(0));

        // ----------------------------------------------------------------
        // Test 7: Ambiguous (N). q=A, t=N. Score should be W_AMBIG=-1.
        // H_diag=10 → M=9. H_new=9. E_new=max(9-7,0-1,0)=2; F_new=2.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, N, score_t'(10), score_t'(0));
        @(posedge clk); #1;
        check("T7 ambiguous H", h_cell_o, score_t'(9));
        check("T7 ambiguous E", e_cell_o, score_t'(2));

        // ----------------------------------------------------------------
        // Test 8: Pipeline forwarding. After an active cycle, the next cycle
        // should expose H_curr in h_left_o (1-cycle delay), and the cycle
        // after that should expose it in h_diag_o (2-cycle delay).
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, A, score_t'(10), score_t'(0));  // H_new = 11
        @(posedge clk); #1;
        check("T8 h_cell after 1 cyc",  h_cell_o, score_t'(11));
        check("T8 h_left after 1 cyc",  h_left_o, score_t'(11));
        check("T8 h_diag after 1 cyc",  h_diag_o, score_t'(0));  // not yet rolled
        idle_cell();
        @(posedge clk); #1;
        check("T8 h_diag after 2 cyc",  h_diag_o, score_t'(11));

        // ----------------------------------------------------------------
        // Test 9: target forwarding. target_i should appear on target_o
        // one cycle later.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, G, score_t'(0), score_t'(0));
        @(posedge clk); #1;
        check("T9 target fwd", score_t'(target_o), score_t'(G));

        // ----------------------------------------------------------------
        // Test 10: inactive cycles should not change E/H/F.
        // ----------------------------------------------------------------
        clear_state();
        drive_cell(1'b1, A, score_t'(20), score_t'(0));  // H=21
        @(posedge clk); #1;
        idle_cell();   // active=0
        idle_cell();
        @(posedge clk); #1;
        check("T10 hold H during idle", h_cell_o, score_t'(21));

        // ----------------------------------------------------------------
        $display("==== tb_bsw_pe done: %0d checks, %0d errors ====", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

    initial begin
        // Watchdog
        #50000;
        $display("[FATAL] tb_bsw_pe timeout");
        $finish;
    end

endmodule
