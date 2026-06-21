// chain2aln.h — the mem_chain2aln SETUP stage that bridges chaining -> extension: per chain,
// compute the reference-window bounds rmax[0..1] from the chain's seeds + query length. This is
// the deterministic glue between chaining_top (produces chains) and orch_read_top (extends them,
// taking rmax + ref window as inputs). The ref-byte FETCH (bns_fetch_seq over the packed genome)
// is a separate memory subsystem, deferred — orch_read_top already takes ref bytes externally.
//
// Faithful to bwamem.cpp:mem_chain2aln (the rmax loop) using the integer-exact cal_max_gap
// (cal_max_gap_int, ksw.h — proven == the float cal_max_gap over all captured data).
#pragma once
#include <cstdint>
#include <vector>
#include "orch.h"   // Seed, Cfg

// bwamem.cpp:cal_max_gap, integer-exact (trunc((qlen*a - o + e)/e); signed / truncates toward 0)
static inline int c2a_cal_max_gap(const Cfg& o, int qlen) {
    int l_del = (qlen*o.a - o.o_del + o.e_del) / o.e_del;
    int l_ins = (qlen*o.a - o.o_ins + o.e_ins) / o.e_ins;
    int l = l_del > l_ins ? l_del : l_ins;
    l = l > 1 ? l : 1;
    return l < (o.w << 1) ? l : (o.w << 1);
}

// mem_chain2aln rmax computation. seeds are the chain's seeds (>=1). l_pac = packed-ref length.
static inline void c_compute_rmax(const std::vector<Seed>& seeds, int l_query, int64_t l_pac,
                                  const Cfg& o, int64_t& rmax0, int64_t& rmax1) {
    rmax0 = l_pac << 1; rmax1 = 0;
    for (const Seed& s : seeds) {
        int64_t b = s.rbeg - ((int64_t)s.qbeg + c2a_cal_max_gap(o, s.qbeg));
        int     tail = l_query - s.qbeg - s.len;
        int64_t e = s.rbeg + s.len + ((int64_t)tail + c2a_cal_max_gap(o, tail));
        if (b < rmax0) rmax0 = b;
        if (e > rmax1) rmax1 = e;
    }
    if (rmax0 < 0)            rmax0 = 0;
    if (rmax1 > (l_pac << 1)) rmax1 = l_pac << 1;
    if (rmax0 < l_pac && l_pac < rmax1) {     // crossing the fwd/rev boundary -> pick one strand
        if (seeds[0].rbeg < l_pac) rmax1 = l_pac;
        else                       rmax0 = l_pac;
    }
}
