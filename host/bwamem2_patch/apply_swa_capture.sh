#!/usr/bin/env bash
# Apply swa_capture.inc to a bwa-mem2 checkout.
#
#   ./apply_swa_capture.sh /path/to/bwa-mem2
#
# Copies the .inc into src/, adds one #include, and inserts one bswcap_batch()
# call after each of the six extension batches in mem_chain2aln.
# Anchors are structural (the tprof accounting lines), not line numbers.
# Idempotent: re-running on an already-patched tree is a no-op.
set -euo pipefail

BWA=${1:?usage: apply_swa_capture.sh /path/to/bwa-mem2}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$BWA/src/bwamem.cpp"
[ -f "$SRC" ] || { echo "not a bwa-mem2 checkout: $BWA" >&2; exit 1; }

cp "$HERE/swa_capture.inc" "$BWA/src/swa_capture.inc"

python3 - "$SRC" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()

if 'swa_capture.inc' in s:
    print('[apply] already patched, nothing to do'); sys.exit(0)

# 1) include
anchor = '#include "kbtree.h"'
assert s.count(anchor) == 1, 'kbtree.h include anchor not unique'
s = s.replace(anchor, anchor + '\n#include "swa_capture.inc"', 1)

# 2) six capture calls, in source order, after each extension batch
#    order: L-scalar, L-16bit, L-8bit, R-scalar, R-16bit, R-8bit
plan = [('Left','S'), ('Left','1'), ('Left','8'),
        ('Right','S'), ('Right','1'), ('Right','8')]

pat = re.compile(r'^([ \t]*)(?://\s*)?tprof\[PE\d+\]\[0\] \+= nump;', re.M)
hits = list(pat.finditer(s))
assert len(hits) == 6, f'expected 6 extension batches, found {len(hits)}'

out, prev = [], 0
for m, (side, route) in zip(hits, plan):
    ind = m.group(1)
    call = (f'{ind}bswcap_batch(opt, pair_ar, nump, seqBuf{side}Ref, '
            f'seqBuf{side}Qer, w, i, \'{side[0]}\', \'{route}\');\n')
    out.append(s[prev:m.start()]); out.append(call); prev = m.start()
out.append(s[prev:])
open(path, 'w').write(''.join(out))
print('[apply] patched: 1 include + 6 capture calls')
PY
