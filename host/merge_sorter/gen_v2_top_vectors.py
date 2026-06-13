#!/usr/bin/env python3
# Generate end-to-end TB vectors for msort_v2_top (tb/tb_msort_v2.sv): raw
# pre-dedup INPUT (original order) -> final OUTPUT, for TIE-FREE arrays only (the
# hardware-handled set). The captured golden output is the real bwa-mem2 result.
import struct, sys
from collections import Counter

src = sys.argv[1] if len(sys.argv) > 1 else "vectors/alnreg_v2_vectors.bin"
dst = sys.argv[2] if len(sys.argv) > 2 else "../../tb/vectors/msort_v2_vectors.hex"
PER_N = int(sys.argv[3]) if len(sys.argv) > 3 else 2
KEY = struct.Struct('<qqiiii')

def h(x, w): return format(x & ((1 << (4*w)) - 1), '0%dx' % w)
def rec_hex(r): return "%s %s %s %s %s %s" % (h(r[0],16),h(r[1],16),h(r[2],8),h(r[3],8),h(r[4],8),h(r[5],8))

with open(src, 'rb') as f:
    data = f.read()
off, L = 0, len(data)
quota = Counter(); out=[]; kept=0
while off < L:
    (n,) = struct.unpack_from('<i', data, off); off += 4
    has_tie = data[off]; off += 1
    (m,) = struct.unpack_from('<i', data, off); off += 4
    inp = [KEY.unpack_from(data, off + i*32) for i in range(n)]; off += n*32
    exp = [KEY.unpack_from(data, off + i*32) for i in range(m)]; off += m*32
    if has_tie or quota[n] >= PER_N:
        continue
    quota[n] += 1; kept += 1
    lines = ["%d %d" % (n, m)]
    lines += [rec_hex(r) for r in inp]
    lines += [rec_hex(r) for r in exp]
    out.append("\n".join(lines))

with open(dst, 'w') as f:
    f.write(str(kept) + "\n")
    f.write("\n".join(out) + "\n")
print("emitted %d tie-free end-to-end arrays to %s" % (kept, dst))
