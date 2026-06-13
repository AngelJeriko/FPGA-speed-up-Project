#!/usr/bin/env python3
# Convert the binary score-sort vectors into a text file the SystemVerilog
# testbench (tb/tb_msort.sv) can read with $fscanf. Packs (score,rb,qb) into the
# 96-bit composite key (same layout as host/merge_sorter/key.h pack_key) and
# emits, per record: n, then n INPUT keys (hex), then n EXPECTED keys (hex).
#
# Records are capped per distinct n (default 4) to keep RTL simulation fast while
# covering the full size range incl. the tail. The exhaustive bit-exact proof is
# already done in C++ (test_sorter); the RTL sim confirms the hardware matches.
#
# Usage: gen_rtl_vectors.py vectors/alnreg_vectors.bin tb_vectors.hex [per_n]
import sys, struct
from collections import Counter

src = sys.argv[1]
dst = sys.argv[2]
PER_N = int(sys.argv[3]) if len(sys.argv) > 3 else 4
N_MAX = 1024                      # hardware capacity; skip n>N_MAX (software fallback)
REC = struct.Struct('<iqi')

def pack(score, rb, qb):
    ks = (0x7FFFFFFF - score) & 0xFFFFFFFF
    return (ks << 64) | ((rb & ((1 << 40) - 1)) << 24) | (qb & ((1 << 24) - 1))

with open(src, 'rb') as f:
    data = f.read()

quota = Counter()
out = []
off, L, kept = 0, len(data), 0
while off < L:
    (n,) = struct.unpack_from('<i', data, off); off += 4
    inp, exp = [], []
    for _ in range(n):
        s, r, q = REC.unpack_from(data, off); off += 16; inp.append((s, r, q))
    for _ in range(n):
        s, r, q = REC.unpack_from(data, off); off += 16; exp.append((s, r, q))
    if n > N_MAX or quota[n] >= PER_N:
        continue
    quota[n] += 1
    kept += 1
    lines = [str(n)]
    lines += [format(pack(*t), '024x') for t in inp]
    lines += [format(pack(*t), '024x') for t in exp]
    out.append("\n".join(lines))

with open(dst, 'w') as f:
    f.write(str(kept) + "\n")
    f.write("\n".join(out) + "\n")

ns = sorted(quota)
print(f"wrote {kept} records to {dst}  (per_n<={PER_N}, n in [{ns[0]},{ns[-1]}], distinct_n={len(ns)})")
