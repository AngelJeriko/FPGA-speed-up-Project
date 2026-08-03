#!/usr/bin/env python3
# Generate TB vectors for the v2 windowed-dedup RTL (tb/tb_msort_dedup.sv).
#
# The dedup FSM operates on records already re-sorted by `re`. So here we:
#   1. read the captured v2 golden vectors (pre-dedup input + real final output),
#   2. for each TIE-FREE array (the hardware-handled set): stable re-sort the
#      input, run the integer branch-A dedup -> survivors (pre-score-sort),
#   3. VALIDATE by running the rest of the chain (score sort + identical removal)
#      and asserting it equals the captured real bwa-mem2 output,
#   4. emit the re-sorted input + the expected survivors for the SV testbench.
#
# Uses the integer redundancy surrogate 20*or_>19*mr (proven == float 0.95f*mr by
# check_redun_int.cpp), matching the RTL exactly.
import struct, sys
from collections import Counter

src = sys.argv[1] if len(sys.argv) > 1 else "vectors/alnreg_v2_vectors.bin"
dst = sys.argv[2] if len(sys.argv) > 2 else "../../tb/vectors/msort_dedup_vectors.hex"
PER_N = int(sys.argv[3]) if len(sys.argv) > 3 else 2
# EXCL_MAX: additionally keep this many redundancy-EXCLUSION-observable tie-free arrays
# (final output depends on the excl_p/excl_q decision), regardless of the PER_N size cap.
# Closes the dedup-exclusion coverage gap: without these the mutation "excl_p=excl_q=0"
# stays green because no array in the size-diversity sample exercises the decision.
EXCL_MAX = int(sys.argv[4]) if len(sys.argv) > 4 else 300
GAP = 10000
KEY = struct.Struct('<qqiiii')   # rb,re(int64) qb,qe,rid,score(int32) = 32 bytes

def dedup(recs, excl=True):
    # excl=True: the real branch-A behaviour. excl=False: mirrors the RTL "disable
    # exclusion" mutation (redundant, but drop nothing) — used only to detect whether
    # an array's OUTPUT actually depends on the exclusion decision (coverage targeting).
    a = [list(r) for r in recs]
    a.sort(key=lambda r: r[1])                 # stable re-sort (Python sort is stable)
    n = len(a)
    for i in range(1, n):
        p = a[i]
        if p[4] != a[i-1][4] or p[0] >= a[i-1][1] + GAP:
            continue
        j = i - 1
        while j >= 0 and p[4] == a[j][4] and p[0] < a[j][1] + GAP:
            q = a[j]
            if q[3] == q[2]:
                j -= 1; continue
            or_ = q[1] - p[0]
            oq = (q[3] - p[2]) if q[2] < p[2] else (p[3] - q[2])
            mr = min(q[1] - q[0], p[1] - p[0])
            mq = min(q[3] - q[2], p[3] - p[2])
            if 20*or_ > 19*mr and 20*oq > 19*mq and excl:
                if p[5] < q[5]:
                    p[3] = p[2]; break
                else:
                    q[3] = q[2]
            j -= 1
    survivors = [r for r in a if r[3] > r[2]]
    return a, survivors

def excl_observable(recs):
    # True iff the final output DEPENDS on the redundancy-exclusion decision, i.e. a tb
    # that includes this array can turn the "excl_p=excl_q=0" RTL mutation RED. (Was: the
    # size-diversity PER_N sample never included such arrays -> exclusion coverage gap.)
    _, sv_on  = dedup(recs, excl=True)
    _, sv_off = dedup(recs, excl=False)
    return final_chain(sv_on) != final_chain(sv_off)

def final_chain(survivors):
    s = sorted(survivors, key=lambda r: (-r[5], r[0], r[2]))   # score desc, rb asc, qb asc
    out = []
    for k, r in enumerate(s):
        if k > 0 and r[5]==s[k-1][5] and r[0]==s[k-1][0] and r[2]==s[k-1][2]:
            continue
        out.append(r)
    return out

def h(x, w): return format(x & ((1 << (4*w)) - 1), '0%dx' % w)
def rec_hex(r): return "%s %s %s %s %s %s" % (h(r[0],16),h(r[1],16),h(r[2],8),h(r[3],8),h(r[4],8),h(r[5],8))

with open(src, 'rb') as f:
    data = f.read()

off, L = 0, len(data)
quota = Counter()
out_records, kept, validated, valfail, excl_kept = [], 0, 0, 0, 0
while off < L:
    (n,) = struct.unpack_from('<i', data, off); off += 4
    has_tie = data[off]; off += 1
    (m,) = struct.unpack_from('<i', data, off); off += 4
    inp = [KEY.unpack_from(data, off + i*32) for i in range(n)]; off += n*32
    exp = [KEY.unpack_from(data, off + i*32) for i in range(m)]; off += m*32
    if has_tie:
        continue
    want_size = quota[n] < PER_N
    want_excl = (excl_kept < EXCL_MAX) and excl_observable(inp)  # exclusion-coverage
    if not (want_size or want_excl):
        continue
    _mutated_in, survivors = dedup(inp)
    # EMIT the re-sorted ORIGINAL input (unmutated) — NOT dedup's in-place-mutated array.
    # dedup() sets qe=qb on excluded losers; emitting that pre-bakes the exclusion into
    # the RTL input (losers arrive already qe==qb), so the RTL just skips them and the
    # exclusion decision is bypassed & untestable (the mutation excl_p=excl_q=0 stays
    # green regardless). The RTL must be fed the ORIGINAL qe and perform the exclusion
    # itself. Python's sort is stable, so this matches the RTL's stable re-sort.
    resorted_in = sorted([list(r) for r in inp], key=lambda r: r[1])
    # validate the dedup against the captured real output via the rest of the chain
    fin = final_chain(survivors)
    ok = (len(fin) == m) and all(tuple(a)==tuple(b) for a,b in zip(fin, exp))
    validated += 1
    if not ok:
        valfail += 1
        continue                              # don't emit unvalidated vectors
    quota[n] += 1; kept += 1
    if want_excl:
        excl_kept += 1
    lines = ["%d %d" % (n, len(survivors))]
    lines += [rec_hex(r) for r in resorted_in]
    lines += [rec_hex(r) for r in survivors]
    out_records.append("\n".join(lines))

with open(dst, 'w') as f:
    f.write(str(kept) + "\n")
    f.write("\n".join(out_records) + "\n")
print("validated %d tie-free arrays vs real output (%d failed); emitted %d to %s" %
      (validated, valfail, kept, dst))
print("  of which exclusion-OBSERVABLE (close the coverage gap): %d" % excl_kept)
