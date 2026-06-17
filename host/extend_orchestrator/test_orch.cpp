// test_orch.cpp — replay captured mem_chain2aln vectors through the software
// orchestrator model and check bit-exactness vs the captured type-2 output.
//
//   make run            # build + run on vectors/ext_vec.bin
//
// Reads the record-tagged binary (host/extend_orchestrator/README.md), buckets
// records by read_id (they interleave across threads), then orchestrate()s each
// read and compares field-for-field against the golden alnreg array.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <unordered_map>
#include "orch.h"

struct Reader {
    const uint8_t *p, *end;
    bool ok() const { return p <= end; }
    template<class T> T get() { T v; memcpy(&v, p, sizeof(T)); p += sizeof(T); return v; }
    void skip(size_t n) { p += n; }
};

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "vectors/ext_vec.bin";
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf(n);
    if ((long)fread(buf.data(), 1, n, f) != n) { fprintf(stderr, "read fail\n"); return 2; }
    fclose(f);

    std::unordered_map<int64_t, ReadVec> reads;
    Reader r{buf.data(), buf.data() + n};
    while (r.p < r.end) {
        int32_t type = r.get<int32_t>();
        int64_t rid = r.get<int64_t>();
        ReadVec &rv = reads[rid];
        rv.read_id = rid;
        if (type == 0) {
            rv.has_hdr = true;
            rv.l_query = r.get<int32_t>();
            int32_t nch = r.get<int32_t>(); (void)nch;
            Cfg &c = rv.cfg;
            int32_t cfg[10]; for (int i = 0; i < 10; ++i) cfg[i] = r.get<int32_t>();
            c.a=cfg[0]; c.b=cfg[1]; c.o_del=cfg[2]; c.e_del=cfg[3]; c.o_ins=cfg[4];
            c.e_ins=cfg[5]; c.w=cfg[6]; c.zdrop=cfg[7]; c.pen_clip5=cfg[8]; c.pen_clip3=cfg[9];
            bwa_fill_scmat(c.a, c.b, c.mat);
            rv.query.resize(rv.l_query);
            memcpy(rv.query.data(), r.p, rv.l_query); r.skip(rv.l_query);
        } else if (type == 1) {
            Chain ch;
            ch.chain_idx = r.get<int32_t>();
            ch.rid = r.get<int32_t>();
            r.get<float>();                 // frac_rep (unused for output check)
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
        } else { fprintf(stderr, "bad tag %d\n", type); return 2; }
    }

    long total=0, pass=0, fail_len=0, fail_field=0, total_regs=0, bad_regs=0;
    int shown=0;
    for (auto &kv : reads) {
        ReadVec &rv = kv.second;
        if (!rv.has_hdr || !rv.has_out) continue;
        total++;
        std::vector<Alnreg> got = orchestrate(rv);
        total_regs += rv.out.size();
        bool ok = (got.size() == rv.out.size());
        if (!ok) fail_len++;
        int first_bad = -1;
        if (ok) {
            for (size_t i = 0; i < got.size(); ++i) {
                const Alnreg &a = got[i], &b = rv.out[i];
                if (a.rb!=b.rb||a.re!=b.re||a.qb!=b.qb||a.qe!=b.qe||a.score!=b.score||
                    a.truesc!=b.truesc||a.w!=b.w||a.seedcov!=b.seedcov||
                    a.seedlen0!=b.seedlen0||a.rid!=b.rid) { ok=false; bad_regs++;
                    if (first_bad<0) first_bad=(int)i; }
            }
            if (!ok) fail_field++;
        }
        if (ok) pass++;
        else if (shown < 8) {
            shown++;
            fprintf(stderr, "MISMATCH read_id=%ld nchains=%zu got=%zu exp=%zu%s\n",
                    (long)rv.read_id, rv.chains.size(), got.size(), rv.out.size(),
                    got.size()!=rv.out.size()?" [LEN]":"");
            if (first_bad >= 0) {
                const Alnreg &a=got[first_bad], &b=rv.out[first_bad];
                fprintf(stderr, "  reg[%d] got rb=%ld re=%ld qb=%d qe=%d sc=%d ts=%d w=%d cov=%d sl0=%d rid=%d\n",
                    first_bad,(long)a.rb,(long)a.re,a.qb,a.qe,a.score,a.truesc,a.w,a.seedcov,a.seedlen0,a.rid);
                fprintf(stderr, "  reg[%d] exp rb=%ld re=%ld qb=%d qe=%d sc=%d ts=%d w=%d cov=%d sl0=%d rid=%d\n",
                    first_bad,(long)b.rb,(long)b.re,b.qb,b.qe,b.score,b.truesc,b.w,b.seedcov,b.seedlen0,b.rid);
            }
        }
    }
    printf("reads tested      : %ld\n", total);
    printf("  bit-exact       : %ld\n", pass);
    printf("  fail (count)    : %ld\n", fail_len);
    printf("  fail (field)    : %ld\n", fail_field);
    printf("total alnregs     : %ld  (mismatched arrays touched %ld regs)\n", total_regs, bad_regs);
    printf("%s\n", (pass==total) ? "ALL PASS" : "FAILURES PRESENT");
    return pass==total ? 0 : 1;
}
