// parse.h — load the record-tagged ext-capture binary into ReadVec[] (complete
// reads only). Shared by test_orch and gen_orch_vectors. Format documented in
// README.md; records interleave across threads, so we bucket by read_id.
#pragma once
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <unordered_map>
#include "orch.h"

struct ByteReader {
    const uint8_t *p, *end;
    template<class T> T get() { T v; memcpy(&v, p, sizeof(T)); p += sizeof(T); return v; }
    void skip(size_t n) { p += n; }
};

static inline std::vector<ReadVec> load_reads(const char *path) {
    std::vector<ReadVec> out;
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return out; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf(n);
    if ((long)fread(buf.data(), 1, n, f) != n) { fprintf(stderr, "read fail\n"); fclose(f); return out; }
    fclose(f);

    std::unordered_map<int64_t, ReadVec> reads;
    ByteReader r{buf.data(), buf.data() + n};
    while (r.p < r.end) {
        int32_t type = r.get<int32_t>();
        int64_t rid = r.get<int64_t>();
        ReadVec &rv = reads[rid]; rv.read_id = rid;
        if (type == 0) {
            rv.has_hdr = true;
            rv.l_query = r.get<int32_t>();
            r.get<int32_t>();                       // n_chains (informational)
            Cfg &c = rv.cfg; int32_t cfg[10];
            for (int i = 0; i < 10; ++i) cfg[i] = r.get<int32_t>();
            c.a=cfg[0]; c.b=cfg[1]; c.o_del=cfg[2]; c.e_del=cfg[3]; c.o_ins=cfg[4];
            c.e_ins=cfg[5]; c.w=cfg[6]; c.zdrop=cfg[7]; c.pen_clip5=cfg[8]; c.pen_clip3=cfg[9];
            bwa_fill_scmat(c.a, c.b, c.mat);
            rv.query.resize(rv.l_query);
            memcpy(rv.query.data(), r.p, rv.l_query); r.skip(rv.l_query);
        } else if (type == 1) {
            Chain ch;
            ch.chain_idx = r.get<int32_t>();
            ch.rid = r.get<int32_t>();
            r.get<float>();
            ch.rmax0 = r.get<int64_t>();
            ch.rmax1 = r.get<int64_t>();
            int32_t ns = r.get<int32_t>();
            ch.seeds.resize(ns);
            for (int i = 0; i < ns; ++i) {
                ch.seeds[i].rbeg  = r.get<int64_t>();
                ch.seeds[i].qbeg  = r.get<int32_t>();
                ch.seeds[i].len   = r.get<int32_t>();
                ch.seeds[i].score = r.get<int32_t>();
            }
            int64_t rlen = r.get<int64_t>();
            ch.ref.resize(rlen);
            memcpy(ch.ref.data(), r.p, rlen); r.skip(rlen);
            rv.chains.push_back(std::move(ch));
        } else if (type == 2) {
            rv.has_out = true;
            int32_t no = r.get<int32_t>();
            rv.out.resize(no);
            for (int i = 0; i < no; ++i) {
                Alnreg &a = rv.out[i];
                a.rb=r.get<int64_t>(); a.re=r.get<int64_t>();
                a.qb=r.get<int32_t>(); a.qe=r.get<int32_t>();
                a.score=r.get<int32_t>(); a.truesc=r.get<int32_t>();
                a.w=r.get<int32_t>(); a.seedcov=r.get<int32_t>();
                a.seedlen0=r.get<int32_t>(); a.rid=r.get<int32_t>();
            }
        } else { fprintf(stderr, "bad tag %d\n", type); break; }
    }
    for (auto &kv : reads)
        if (kv.second.has_hdr && kv.second.has_out) out.push_back(std::move(kv.second));
    return out;
}
