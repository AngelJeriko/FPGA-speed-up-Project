#!/usr/bin/env python3
"""Compare two tb_bsw_ext dump files field by field.

    python3 scripts/compare_dumps.py <reference> <candidate>

Both files are produced by tb_bsw_ext / tb_bsw_ext_flat via `+DUMP=<file>`:
one header line, then one row per extension:

    idx score qle tle gscore gtle max_off error

The intended use is STEP 2 of the post-synthesis flow: the reference is what
Verilator produced from the RTL (committed under sim/xsim/reference/), the
candidate is what XSIM produced from the synthesized netlist. Identical files mean
synthesis preserved behaviour exactly -- which is the one thing a Verilator run,
however large, cannot establish.

Exits 0 when every compared row matches, 1 otherwise, so it can gate CI.

X VALUES: a 4-state simulator can emit x or z where Verilator, being 2-state,
always had a definite 0 or 1. Those are reported separately from ordinary value
mismatches, because they are a different and usually more serious finding: an X
means the design depends on state nothing initialised, which on real silicon comes
up as whatever the bitstream loaded.
"""
import sys

FIELDS = ["score", "qle", "tle", "gscore", "gtle", "max_off", "error"]


def load(path):
    rows = {}
    with open(path) as fh:
        for ln, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 8:
                sys.exit("%s:%d: expected 8 columns, got %d: %r" % (path, ln, len(parts), line))
            rows[parts[0]] = parts[1:]
    return rows


def is_x(tok):
    # Verilog %0d on an unknown value prints x (or z); any non-integer token counts.
    try:
        int(tok)
        return False
    except ValueError:
        return True


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref_path, cand_path = sys.argv[1], sys.argv[2]
    ref, cand = load(ref_path), load(cand_path)

    print("reference : %s  (%d rows)" % (ref_path, len(ref)))
    print("candidate : %s  (%d rows)" % (cand_path, len(cand)))

    common = sorted(set(ref) & set(cand), key=int)
    only_ref = sorted(set(ref) - set(cand), key=int)
    only_cand = sorted(set(cand) - set(ref), key=int)

    if only_ref:
        print("\nWARNING: %d row(s) only in the reference (candidate ran fewer vectors?)"
              % len(only_ref))
        print("         first few: %s" % ", ".join(only_ref[:10]))
    if only_cand:
        print("\nWARNING: %d row(s) only in the candidate" % len(only_cand))
        print("         first few: %s" % ", ".join(only_cand[:10]))
    if not common:
        print("\nFAIL: no rows in common -- nothing was actually compared.")
        return 1

    mismatches = []
    xrows = []
    per_field = {f: 0 for f in FIELDS}

    for idx in common:
        r, c = ref[idx], cand[idx]
        xs = [FIELDS[i] for i, tok in enumerate(c) if is_x(tok)]
        if xs:
            xrows.append((idx, xs, c))
        diffs = [(FIELDS[i], r[i], c[i]) for i in range(len(FIELDS)) if r[i] != c[i]]
        if diffs:
            mismatches.append((idx, diffs))
            for f, _, _ in diffs:
                per_field[f] += 1

    print("\ncompared  : %d rows" % len(common))

    if xrows:
        print("\n--- X VALUES (%d row(s)) -- read these first ---" % len(xrows))
        print("    An X means the design read state that nothing initialised. Verilator")
        print("    cannot produce this; it is a genuine 4-state finding.")
        for idx, xs, c in xrows[:20]:
            print("    idx %-6s unknown in: %-28s row: %s" % (idx, ",".join(xs), " ".join(c)))
        if len(xrows) > 20:
            print("    ... and %d more" % (len(xrows) - 20))

    if not mismatches:
        print("\nPASS: all %d rows identical across every field." % len(common))
        if xrows:
            print("      (but see the X values above -- values agreed, yet some are unknown)")
            return 1
        return 0

    print("\n--- MISMATCHES (%d of %d rows) ---" % (len(mismatches), len(common)))
    print("    per field: %s" % ", ".join("%s=%d" % (f, per_field[f]) for f in FIELDS if per_field[f]))
    print()
    print("    %-8s %-10s %-12s %-12s" % ("idx", "field", "reference", "candidate"))
    shown = 0
    for idx, diffs in mismatches:
        for f, a, b in diffs:
            print("    %-8s %-10s %-12s %-12s" % (idx, f, a, b))
            shown += 1
            if shown >= 40:
                break
        if shown >= 40:
            print("    ... truncated")
            break

    # score/qle/tle must be exact. gscore/gtle can legitimately differ between the
    # banded C reference and the full-DP array (docs/rtl_verification.md sections 4
    # and 8), but NOT between the RTL and its own netlist -- same design, so any
    # difference here is a synthesis problem.
    hard = [f for f in ("score", "qle", "tle", "error") if per_field[f]]
    print("\nFAIL: %d row(s) differ." % len(mismatches))
    if hard:
        print("      %s differ -- these are never acceptable between an RTL run and" % ", ".join(hard))
        print("      its own netlist. This is a synthesis-behaviour finding.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
