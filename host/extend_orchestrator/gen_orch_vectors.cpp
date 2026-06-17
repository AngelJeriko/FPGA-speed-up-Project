// gen_orch_vectors.cpp — measure the cross-chain purge's impact (validates the
// host-fallback decision) and emit the PRE-purge golden alnreg arrays, which are
// what the RTL orchestrator produces (the purge is host-side). Also re-checks
// that extend_only + purge == the captured post-purge output.
//
//   make gen     # writes vectors/ext_prepurge.bin + prints stats
//
// ext_prepurge.bin (native little-endian), per read:
//   i64 read_id; i32 n; n*{i64 rb; i64 re; i32 qb; i32 qe; i32 score; i32 truesc;
//                          i32 w; i32 seedcov; i32 seedlen0; i32 rid}
#include <cstdio>
#include <cstdint>
#include <vector>
#include "parse.h"

int main(int argc, char **argv) {
    const char *in  = argc > 1 ? argv[1] : "vectors/ext_vec.bin";
    const char *out = argc > 2 ? argv[2] : "vectors/ext_prepurge.bin";
    std::vector<ReadVec> reads = load_reads(in);
    if (reads.empty()) { fprintf(stderr, "no reads loaded from %s\n", in); return 2; }

    FILE *f = fopen(out, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out); return 2; }

    long n_reads=0, reads_purged=0, total_pre=0, total_post=0, purged_regs=0;
    long post_recheck_ok=0;
    for (const ReadVec &rv : reads) {
        n_reads++;
        std::vector<std::vector<int>> seed_aln;
        std::vector<Alnreg> pre = extend_only(rv, seed_aln);   // pre-purge (RTL target)
        std::vector<Alnreg> post = pre;                        // copy, then purge
        purge(rv, post, seed_aln);

        // count purged (qb==qe==-1) in post
        long pg = 0;
        for (const Alnreg &a : post) if (a.qb == -1 && a.qe == -1) pg++;
        if (pg) reads_purged++;
        purged_regs += pg;
        total_pre += pre.size();
        total_post += post.size();

        // re-check: extend_only + purge == captured post-purge output
        bool ok = (post.size() == rv.out.size());
        for (size_t i = 0; ok && i < post.size(); ++i) {
            const Alnreg &a = post[i], &b = rv.out[i];
            ok = a.rb==b.rb&&a.re==b.re&&a.qb==b.qb&&a.qe==b.qe&&a.score==b.score&&
                 a.truesc==b.truesc&&a.w==b.w&&a.seedcov==b.seedcov&&
                 a.seedlen0==b.seedlen0&&a.rid==b.rid;
        }
        if (ok) post_recheck_ok++;

        // emit pre-purge golden
        int64_t rid = rv.read_id; int32_t nn = (int32_t)pre.size();
        fwrite(&rid,8,1,f); fwrite(&nn,4,1,f);
        for (const Alnreg &a : pre) {
            int64_t rb=a.rb, re=a.re;
            int32_t qb=a.qb,qe=a.qe,sc=a.score,ts=a.truesc,w=a.w,cov=a.seedcov,sl0=a.seedlen0,rid2=a.rid;
            fwrite(&rb,8,1,f); fwrite(&re,8,1,f);
            fwrite(&qb,4,1,f); fwrite(&qe,4,1,f); fwrite(&sc,4,1,f); fwrite(&ts,4,1,f);
            fwrite(&w,4,1,f); fwrite(&cov,4,1,f); fwrite(&sl0,4,1,f); fwrite(&rid2,4,1,f);
        }
    }
    fclose(f);

    printf("reads                    : %ld\n", n_reads);
    printf("post-purge recheck OK    : %ld / %ld %s\n", post_recheck_ok, n_reads,
           post_recheck_ok==n_reads ? "(bit-exact vs capture)" : "!! MISMATCH");
    printf("pre-purge alnregs total  : %ld\n", total_pre);
    printf("reads with >=1 purge     : %ld (%.2f%%)\n", reads_purged, 100.0*reads_purged/n_reads);
    printf("alnregs purged (qb=qe=-1): %ld (%.3f%% of pre-purge)\n",
           purged_regs, 100.0*purged_regs/total_pre);
    printf("wrote pre-purge golden   : %s\n", out);
    return post_recheck_ok==n_reads ? 0 : 1;
}
