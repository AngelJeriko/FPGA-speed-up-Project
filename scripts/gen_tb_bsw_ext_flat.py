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

    # `result` becomes continuously assigned, so it must never be written
    # procedurally as well -- that would be a compile error in both simulators.
    if 'result =' in body.replace('assign result = result_bits;', ''):
        fail("`result` is assigned procedurally; it cannot also be continuously assigned")

    open(DST, 'w').write(HDR + body)
    print("wrote %s" % os.path.relpath(DST, ROOT))


if __name__ == '__main__':
    main()
