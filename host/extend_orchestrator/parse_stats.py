#!/usr/bin/env python3
# Validate the ext-capture binary and report data shape. Buckets records by
# read_id (HEADER/CHAIN/OUTPUT) and checks each read is well-formed.
import struct, sys, gzip, collections

path = sys.argv[1] if len(sys.argv) > 1 else "vectors/ext_vec.bin"
op = gzip.open if path.endswith(".gz") else open
buf = op(path, "rb").read()
n = len(buf); off = 0
def rd(fmt):
    global off
    sz = struct.calcsize("<"+fmt)
    v = struct.unpack_from("<"+fmt, buf, off); off += sz
    return v

reads = {}   # read_id -> dict
n_hdr=n_chn=n_out=0
while off < n:
    (t,) = rd("i")
    if t == 0:
        (rid, lq, nch) = rd("qii"); cfg = rd("10i"); off += lq
        reads.setdefault(rid, {})["hdr"] = (lq, nch, cfg)
        n_hdr += 1
    elif t == 1:
        (rid, ci, crid, fr, r0, r1, ns) = rd("qiifqqi")
        off += ns*(8+4+4+4)            # seeds
        (rlen,) = rd("q"); off += rlen # ref window
        d = reads.setdefault(rid, {}); d.setdefault("chains", []).append((ci, ns, r1-r0))
        n_chn += 1
    elif t == 2:
        (rid, no) = rd("qi"); off += no*(8+8+4*8)
        reads.setdefault(rid, {})["nout"] = no
        n_out += 1
    else:
        print("BAD TAG", t, "at", off); break

# stats
nseeds = [ns for d in reads.values() for (_,ns,_) in d.get("chains",[])]
refw   = [w  for d in reads.values() for (_,_,w)  in d.get("chains",[])]
nout   = [d["nout"] for d in reads.values() if "nout" in d]
nchain = [d["hdr"][1] for d in reads.values() if "hdr" in d]
complete = sum(1 for d in reads.values() if "hdr" in d and "nout" in d)

def q(x, p):
    x=sorted(x); return x[min(len(x)-1, int(p*len(x)))] if x else 0
print(f"file bytes        : {n:,}")
print(f"records           : {n_hdr} HEADER, {n_chn} CHAIN, {n_out} OUTPUT")
print(f"reads (by id)     : {len(reads)}  complete(hdr+out): {complete}")
print(f"chains/read       : min {min(nchain)} med {q(nchain,.5)} max {max(nchain)}")
print(f"seeds/chain       : min {min(nseeds)} med {q(nseeds,.5)} p99 {q(nseeds,.99)} max {max(nseeds)}")
print(f"ref window bytes  : min {min(refw)} med {q(refw,.5)} p99 {q(refw,.99)} max {max(refw)}")
print(f"alnregs out/read  : min {min(nout)} med {q(nout,.5)} p99 {q(nout,.99)} max {max(nout)}")
print(f"total alnregs out : {sum(nout):,}")
