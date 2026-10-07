#!/usr/bin/env python3
"""Regenerate tb/tb_bsw_ext_flat.sv from tb/tb_bsw_ext.sv.

tb_bsw_ext_flat must differ from tb_bsw_ext ONLY in which DUT it binds: the flat
wrapper (synth/postsynth/bsw_top_flat.sv) rather than bsw_top directly. Everything
else -- the vector reader, the handshake, and above all the pass/fail comparison --
has to stay identical, because the entire value of the post-synthesis run is that
the RTL and the netlist are judged by the same code.

Hand-maintaining two copies would let them drift silently, and a drifted copy
would produce a "pass" that means nothing. So the flat testbench is generated, and
this script asserts on every structure it depends on: if tb_bsw_ext.sv is
restructured, this fails loudly instead of emitting something subtly wrong.

    python3 scripts/gen_tb_bsw_ext_flat.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tb', 'tb_bsw_ext.sv')
DST = os.path.join(ROOT, 'tb', 'tb_bsw_ext_flat.sv')

HDR = '''// tb_bsw_ext_flat.sv -- GENERATED from tb_bsw_ext.sv. Do not hand-edit; regenerate
// with scripts/gen_tb_bsw_ext_flat.py so the checking logic can never drift.
//
// Identical to tb_bsw_ext in every respect except the DUT binding: it drives
// bsw_top_flat (synth/postsynth/bsw_top_flat.sv), whose ports are plain 1-D
// vectors instead of packed arrays and structs.
//
// WHY: Vivado's funcsim netlist writer scalarizes aggregate ports -- bsw_top's
// `base_t [1023:0] target_i` becomes 1024 separate ports named \\target_i[1023] and
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
'''

OLD_INST = '''    bsw_top dut (
        .clk(clk), .rst_n(rst_n), .restart_mode(1'b0),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .query_i(query), .target_i(target), .cfg_i(cfg),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_o(result)
    );'''

NEW_INST = '''    // The flat wrapper's ports are plain vectors. A packed struct / packed array is
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
    );'''


OLD_RESET = """        repeat (5) @(posedge clk);
        rst_n = 1; @(posedge clk);"""

NEW_RESET = """        // 30 cycles = 300 ns, past glbl's 100 ns GSR pulse. See the header.
        repeat (`BSW_RESET_CYCLES) @(posedge clk);
        rst_n = 1; @(posedge clk);"""

OLD_WDOG = """    initial begin
        #2000000000;
        $display("[FATAL] tb_bsw_ext_flat timeout");
        $finish;
    end"""

NEW_WDOG = """    // Cycle-counted watchdog. A time-based one is unreachable at gate level: see
    // the header. Override with +define+BSW_MAX_CYCLES=<n>.
    int unsigned wdog_cyc = 0;
    always @(posedge clk) begin
        wdog_cyc <= wdog_cyc + 1;
        if (wdog_cyc > `BSW_MAX_CYCLES) begin
            $display("[FATAL] tb_bsw_ext_flat: watchdog fired after %0d cycles while on extension index %0d (of %0d). The DUT stopped responding -- req_ready or result_valid never asserted.",
                     wdog_cyc, i, cnt);
            $fatal(1);
        end
    end"""

DEFINES = """`ifndef BSW_RESET_CYCLES
  `define BSW_RESET_CYCLES 30
`endif
`ifndef BSW_MAX_CYCLES
  `define BSW_MAX_CYCLES 400000
`endif

"""


def fail(msg):
    sys.exit("gen_tb_bsw_ext_flat: %s\n"
             "  tb/tb_bsw_ext.sv has been restructured. Update this script to match "
             "rather than hand-editing tb_bsw_ext_flat.sv." % msg)


def main():
    src = open(SRC).read()

    if '`timescale' not in src:
        fail("no `timescale directive found")
    body = src[src.index('`timescale'):]

    for needle, repl, what in (
        ('module tb_bsw_ext\n', 'module tb_bsw_ext_flat\n', 'module declaration'),
        ('"tb_bsw_ext: %0d extensions', '"tb_bsw_ext_flat: %0d extensions', 'summary line'),
        ('"[FATAL] tb_bsw_ext timeout"', '"[FATAL] tb_bsw_ext_flat timeout"', 'timeout message'),
    ):
        if needle not in body:
            fail("could not find the %s" % what)
        body = body.replace(needle, repl, 1)

    if OLD_INST not in body:
        fail("the bsw_top instantiation block does not match")
    body = body.replace(OLD_INST, NEW_INST, 1)

    # Deviation 1: hold reset past glbl's 100 ns GSR pulse.
    if OLD_RESET not in body:
        fail("the reset sequence does not match")
    body = body.replace(OLD_RESET, NEW_RESET, 1)

    # Deviation 2: a cycle-counted watchdog that is actually reachable at gate level.
    if OLD_WDOG not in body:
        fail("the watchdog block does not match")
    body = body.replace(OLD_WDOG, NEW_WDOG, 1)

    # `result` becomes continuously assigned, so it must never be written
    # procedurally as well -- that would be a compile error in both simulators.
    if 'result =' in body.replace('assign result = result_bits;', ''):
        fail("`result` is assigned procedurally; it cannot also be continuously assigned")

    # The defines go after `timescale/`include so they precede first use.
    marker = '`include "bsw_pkg.sv"\n'
    if marker not in body:
        fail("could not find the bsw_pkg include to anchor the defines")
    body = body.replace(marker, marker + "\n" + DEFINES, 1)

    open(DST, 'w').write(HDR + body)
    print("wrote %s" % os.path.relpath(DST, ROOT))


if __name__ == '__main__':
    main()
