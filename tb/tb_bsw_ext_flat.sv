// tb_bsw_ext_flat.sv -- GENERATED from tb_bsw_ext.sv. Do not hand-edit; regenerate
// with scripts/gen_tb_bsw_ext_flat.py so the checking logic can never drift.
//
// Identical to tb_bsw_ext in every respect except the DUT binding: it drives
// bsw_top_flat (synth/postsynth/bsw_top_flat.sv), whose ports are plain 1-D
// vectors instead of packed arrays and structs.
//
// WHY: Vivado's funcsim netlist writer scalarizes aggregate ports -- bsw_top's
// `base_t [1023:0] target_i` becomes 1024 separate ports named \target_i[1023] and
// so on -- so tb_bsw_ext cannot bind to a post-synthesis netlist of bsw_top at
// all. Wrapping in flat vectors survives the writer, which lets ONE testbench
// drive both the RTL and the netlist. That equality matters: when the two runs
// agree, the agreement is about synthesis, not about two harnesses that happened
// to be wired the same way.
//
// TWO FURTHER DELIBERATE DEVIATIONS, both about surviving a gate-level run. Neither
// touches the pass/fail comparison, which stays byte-identical to tb_bsw_ext:
//
//  1. RESET IS HELD FOR 30 CYCLES (300 ns), not 5 (50 ns). In post-synthesis
//     simulation `glbl` asserts the Global Set/Reset for the first 100 ns, holding
//     every flop. Releasing rst_n at 50 ns means the design never sees a clean
//     reset release after GSR lets go, and the FSM can come up in a state where
//     req_ready never asserts. Costs 250 ns of simulated time under Verilator.
//
//  2. THE WATCHDOG COUNTS CYCLES, not simulated time. tb_bsw_ext waits
//     `#2000000000`, which in a 1ns timescale is 2e8 clock cycles -- unreachable at
//     gate-level speed, so a stalled gate-level run hangs indefinitely instead of
//     failing. A real one did, for 10 hours. The cycle watchdog also reports WHICH
//     extension stalled, which the time-based one never could.
//
`timescale 1ns/1ps
`include "bsw_pkg.sv"

`ifndef BSW_RESET_CYCLES
  `define BSW_RESET_CYCLES 30
`endif
`ifndef BSW_MAX_CYCLES
  `define BSW_MAX_CYCLES 400000
`endif


module tb_bsw_ext_flat
    import bsw_pkg::*;
();
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic                 req_valid, req_ready;
    base_t [MAX_QLEN-1:0] query;
    base_t [MAX_TLEN-1:0] target;
    bsw_config_t          cfg;
    logic                 result_valid;
    logic                 result_ready;
    bsw_result_t          result;

    // The flat wrapper's ports are plain vectors. A packed struct / packed array is
    // bit-stream equivalent to a vector of the same width, so `query`, `target` and
    // `cfg` connect directly and `result_bits` unpacks straight back into the
    // bsw_result_t the checking code below already reads field-by-field.
    logic [$bits(bsw_result_t)-1:0] result_bits;
    assign result = result_bits;

    bsw_top_flat dut (
        .clk(clk), .rst_n(rst_n), .restart_mode(1'b0),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .query_flat_i(query), .target_flat_i(target), .cfg_flat_i(cfg),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_flat_o(result_bits)
    );

    int fd, got, cnt, i, b;
    int dfd = 0;              // +DUMP=<file>: record what the RTL produced
    string dump_path;
    int side, qlen, tlen, h0, eb, o_del, e_del, o_ins, e_ins, zdrop;
    int e_score, e_qle, e_tle, e_gscore, e_gtle, e_maxoff;
    int fails, maxoff_diffs;
    string path;

    task automatic do_reset();
        rst_n = 0; req_valid = 0; result_ready = 1;
        query = '{default:'0}; target = '{default:'0}; cfg = '{default:'0};
        // 30 cycles = 300 ns, past glbl's 100 ns GSR pulse. See the header.
        repeat (`BSW_RESET_CYCLES) @(posedge clk);
        rst_n = 1; @(posedge clk);
    endtask

    task automatic submit_and_wait();
        @(posedge clk);
        wait (req_ready);
        @(posedge clk);
        req_valid = 1;
        @(posedge clk);
        req_valid = 0;
        wait (result_valid);
        @(posedge clk);
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path))
            path = "host/extend_orchestrator/vectors/ext_sw_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", path); $finish; end

        // Optional: write the DUT's six outputs per extension so a side-by-side
        // against bwa-mem2 can be produced (scripts/show_rtl_vs_bwamem2.sh).
        // Off unless +DUMP is given, so the regression suite is unaffected.
        if ($value$plusargs("DUMP=%s", dump_path)) begin
            dfd = $fopen(dump_path, "w");
            if (dfd == 0) begin $display("FATAL: cannot write %s", dump_path); $finish; end
            $fdisplay(dfd, "# idx score qle tle gscore gtle max_off error");
        end

        do_reset();
        got = $fscanf(fd, "%d", cnt);
        fails = 0; maxoff_diffs = 0;

        for (i = 0; i < cnt; i = i + 1) begin
            got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                side, qlen, tlen, h0, eb, o_del, e_del, o_ins, e_ins, zdrop,
                e_score, e_qle, e_tle, e_gscore, e_gtle, e_maxoff);

            query  = '{default: base_t'(4)};
            target = '{default: base_t'(4)};
            for (b = 0; b < qlen; b = b + 1) begin
                got = $fscanf(fd, "%d", query[b]);
            end
            for (b = 0; b < tlen; b = b + 1) begin
                got = $fscanf(fd, "%d", target[b]);
            end

            cfg = '{default:'0};
            cfg.h0        = score_t'(h0);
            cfg.o_del     = score_t'(o_del);
            cfg.e_del     = score_t'(e_del);
            cfg.o_ins     = score_t'(o_ins);
            cfg.e_ins     = score_t'(e_ins);
            cfg.zdrop     = score_t'(zdrop);
            cfg.end_bonus = score_t'(eb);   // not used by the array; carried for completeness
            cfg.w         = len_t'(100);    // not used by the full-DP array
            cfg.qlen      = len_t'(qlen);
            cfg.tlen      = len_t'(tlen);

            submit_and_wait();

            // gtle (= max_ie+1, the target len at gscore) is consumed by alnreg
            // assembly ONLY in the gscore>0 branch; when gscore<=0 the score
            // branch is taken and gtle is unused, so a divergent gtle there is
            // harmless (the array keeps a fully-zeroed tail alive on column 0
            // longer than ksw's narrowing does). Gate the gtle check on gscore>0.
            if (result.error !== 1'b0 ||
                $signed(result.score)  !== e_score  ||
                result.qle             !== e_qle    ||
                result.tle             !== e_tle    ||
                $signed(result.gscore) !== e_gscore ||
                (e_gscore > 0 && result.gtle !== e_gtle)) begin
                fails = fails + 1;
                if (fails <= 10)
                    $display("MISMATCH[%0d] side=%0d qlen=%0d tlen=%0d | score %0d/%0d qle %0d/%0d tle %0d/%0d gsc %0d/%0d gtle %0d/%0d err=%0b",
                        i, side, qlen, tlen,
                        $signed(result.score), e_score, result.qle, e_qle, result.tle, e_tle,
                        $signed(result.gscore), e_gscore, result.gtle, e_gtle, result.error);
            end
            if (dfd != 0)
                $fdisplay(dfd, "%0d %0d %0d %0d %0d %0d %0d %0b", i,
                          $signed(result.score), result.qle, result.tle,
                          $signed(result.gscore), result.gtle, result.max_off,
                          result.error);
            if (result.max_off !== e_maxoff) maxoff_diffs = maxoff_diffs + 1;
        end

        $fclose(fd);
        if (dfd != 0) $fclose(dfd);
        $display("tb_bsw_ext_flat: %0d extensions, %0d failures, %0d max_off diffs (informational) -> %s",
                 cnt, fails, maxoff_diffs, (fails==0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    // Cycle-counted watchdog. A time-based one is unreachable at gate level: see
    // the header. Override with +define+BSW_MAX_CYCLES=<n>.
    int unsigned wdog_cyc = 0;
    always @(posedge clk) begin
        wdog_cyc <= wdog_cyc + 1;
        if (wdog_cyc > `BSW_MAX_CYCLES) begin
            $display("[FATAL] tb_bsw_ext_flat: watchdog fired after %0d cycles while on extension index %0d (of %0d). The DUT stopped responding -- req_ready or result_valid never asserted.",
                     wdog_cyc, i, cnt);
            $fatal(1);
        end
    end
endmodule
