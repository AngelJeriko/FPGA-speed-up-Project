#!/usr/bin/env python3
"""Filter a tb_bsw_ext vector file to records whose qlen fits a reduced PE array.

    python3 scripts/filter_vectors_by_qlen.py <in.txt> <out.txt> <max_qlen> [max_records]

WHY THIS EXISTS: XSIM's BASIC licence tier refuses any design with more than 50,000
instances, and the 160-PE gate-level netlist has 166,514. The only way to get
gate-level evidence on that licence is to synthesize a narrower array -- and a
narrower array legitimately REJECTS a query longer than N_PE (bsw_ctrl_fsm sets
error=1 rather than computing a wrong answer, which is the documented behaviour and
exactly what the tlen guard was added for). So the vectors must be filtered to
match, or every record would come back as a rejection.

Real E. coli data has plenty of short extensions, because the left-extension of a
seed near a read's start is short: of 10,000 captured extensions, 498 have qlen <= 8
and 2,092 have qlen <= 32.

Format: first line is the record count, then 3 lines per record --
    <16 ints: side qlen tlen h0 end_bonus o_del e_del o_ins e_ins zdrop
              score qle tle gscore gtle max_off>
    <qlen query bases>
    <tlen target bases>
"""
import sys


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    src, dst, max_qlen = sys.argv[1], sys.argv[2], int(sys.argv[3])
    cap = int(sys.argv[4]) if len(sys.argv) == 5 else None

    with open(src) as fh:
        lines = fh.read().split("\n")

    try:
        total = int(lines[0].strip())
    except (ValueError, IndexError):
        sys.exit("%s: first line must be the record count" % src)

    kept, scanned = [], 0
    i = 1
    while i + 2 < len(lines) + 1 and scanned < total:
        hdr = lines[i].split()
        if len(hdr) != 16:
            sys.exit("%s:%d: expected 16 fields, got %d" % (src, i + 1, len(hdr)))
        qlen = int(hdr[1])
        if qlen <= max_qlen:
            kept.append((lines[i], lines[i + 1], lines[i + 2]))
            if cap and len(kept) >= cap:
                i += 3
                scanned += 1
                break
        i += 3
        scanned += 1

    if not kept:
        sys.exit("no records with qlen <= %d found in %s" % (max_qlen, src))

    with open(dst, "w") as fh:
        fh.write("%d\n" % len(kept))
        for rec in kept:
            fh.write("\n".join(rec) + "\n")

    qs = [int(r[0].split()[1]) for r in kept]
    print("%s -> %s" % (src, dst))
    print("  scanned %d of %d records" % (scanned, total))
    print("  kept    %d (qlen <= %d; actual range %d..%d)" % (len(kept), max_qlen, min(qs), max(qs)))


if __name__ == "__main__":
    main()
