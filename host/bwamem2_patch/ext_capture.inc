/* ============================================================================
 * ext_capture.inc — PASTE-READY instrumentation for the EXTEND-ORCHESTRATOR
 *   capture (instrument #5 of docs/bwamem2_instrumentation.md; env ALNREG_EXT_OUT).
 *
 *   ✅ VALIDATED (2026-08-06) — applied to bwa-mem2 @ commit 97978f9, built, and
 *   the acceptance test PASSED: a fresh capture (50k HG00733 pairs, ALNREG_EXT_MAX
 *   =30000) replayed through host/extend_orchestrator/test_orch reported
 *   **30000/30000 reads bit-exact, 0 field failures** (591,962 alnregs). So the
 *   format AND the value bindings AND the two-site read_id join below are all
 *   confirmed correct at that commit.
 *
 *   Reconstructed (the original hook was reverted, not committed); rebuilt from the
 *   byte format in host/extend_orchestrator/README.md + parse.h, then hardened and
 *   proven against real source. Format is byte-exact vs the reader parse.h.
 *
 *   TWO SITES in src/bwamem.cpp (line refs @ 97978f9):
 *     - HEADER + CHAIN: inside mem_chain2aln_across_reads_V2 (fn @ :2069) — HEADER
 *       at the per-read loop top (:2108, query/chn in scope), CHAIN in the per-chain
 *       loop after bns_fetch_seq_v2 (:2172).
 *     - OUTPUT: in the CALLER mem_kernel2_core (fn @ :1118), immediately AFTER the
 *       mem_chain2aln_across_reads_V2(...) call returns (:1147), BEFORE the caller's
 *       frac_rep / identical-hit / mem_sort_dedup_patch steps. KEY: capturing later
 *       (e.g. after mem_sort_dedup_patch) OVER-reduces the array — the model's purge
 *       only MARKS contained regs (qb=qe=-1), it does not remove them, so the golden
 *       OUTPUT is the full post-mem_chain2aln array. (The batched SIMD SW means av is
 *       only final once the function returns — capturing inside the per-read loop
 *       would dump H0_ placeholders.) The two sites join by a thread-local read_id
 *       (one worker thread runs a whole batch: mem_chain2aln then the purge).
 *
 *   TO RE-VALIDATE:
 *     ALNREG_EXT_OUT=ext_vec.bin ALNREG_EXT_MAX=30000 \
 *       ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null
 *     ( cd host/extend_orchestrator && make test_orch && ./test_orch /path/ext_vec.bin )
 *   Expect: "ALL PASS ... bit-exact : <N>  fail (count) : 0  fail (field) : 0".
 *
 * Record format (binary, native LE) — byte-exact vs host/extend_orchestrator/parse.h:
 *   type 0 HEADER: i32 type=0; i64 read_id; i32 l_query; i32 n_chains;
 *                  i32 cfg[10]={a,b,o_del,e_del,o_ins,e_ins,w,zdrop,pen_clip5,pen_clip3};
 *                  u8 query[l_query]
 *   type 1 CHAIN : i32 type=1; i64 read_id; i32 chain_idx; i32 rid; f32 frac_rep;
 *                  i64 rmax0; i64 rmax1; i32 n_seeds;
 *                  n_seeds*{i64 rbeg; i32 qbeg; i32 len; i32 score};
 *                  i64 ref_len(=rmax1-rmax0); u8 ref[ref_len]
 *   type 2 OUTPUT: i32 type=2; i64 read_id; i32 n_out;
 *                  n_out*{i64 rb; i64 re; i32 qb; i32 qe; i32 score; i32 truesc;
 *                         i32 w; i32 seedcov; i32 seedlen0; i32 rid}
 * ============================================================================
 *
 * --- STEP 1: INFRA — paste at file scope in src/bwamem.cpp (e.g. right after the
 *     `#include "kbtree.h"` line, before any function). ---------------------- */
/* --- INSTRUMENTATION (temporary): extend-orchestrator (mem_chain2aln) capture */
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
static FILE *g_ext_fp=NULL; static int g_ext_enabled=-1;
static long  g_ext_rid_next=0, g_ext_max=30000;
static volatile int g_ext_lock=0;
static inline void ext_lock(void){ while(__sync_lock_test_and_set(&g_ext_lock,1)){} }
static inline void ext_unlock(void){ __sync_lock_release(&g_ext_lock); }
static void ext_init_once(void){
    if (g_ext_enabled>=0) return;
    ext_lock();
    if (g_ext_enabled<0){
        const char*p=getenv("ALNREG_EXT_OUT");
        if(p){ g_ext_fp=fopen(p,"wb"); g_ext_enabled=g_ext_fp?1:0; } else g_ext_enabled=0;
        const char*m=getenv("ALNREG_EXT_MAX"); if(m){ long v=atol(m); if(v>0) g_ext_max=v; }
    }
    ext_unlock();
}
struct ExtCapDumper{ ~ExtCapDumper(){ if(g_ext_fp) fclose(g_ext_fp); } };
static ExtCapDumper g_ext_cap_dumper;
/* per-read id for the CURRENT batch, indexed by l; set at HEADER (in
 * mem_chain2aln), read at OUTPUT (in the caller). thread_local: one worker thread
 * runs a whole batch end-to-end. */
static thread_local std::vector<long> g_ext_tl_rid;
/* --- end instrumentation infra --------------------------------------------- */


/* ===== SITE 1: mem_chain2aln_across_reads_V2 (src/bwamem.cpp @ :2069) ========
 * --- STEP 2: HOOK-H (HEADER) — at the per-read loop top, right after the block
 *     `mem_chain_v *chn = &chain_ar[l]; mem_alnreg_v *av = &av_v[l]; mem_chain_t *c;
 *      _mm_prefetch((const char*) query, _MM_HINT_NTA);` (:2119-2123). Declares
 *     `long ext_rid` used by HOOK-C. `query`,`l_query`,`chn`,`opt`,`l`,`nseq` in scope. */
ext_init_once();
if (g_ext_enabled>0 && (int)g_ext_tl_rid.size() < nseq) g_ext_tl_rid.assign(nseq, -1);
long ext_rid = -1;
if (g_ext_enabled>0) {
    ext_lock();
    if (g_ext_rid_next < g_ext_max) ext_rid = g_ext_rid_next++;
    g_ext_tl_rid[l] = ext_rid;                        /* carry to OUTPUT (SITE 2) */
    if (ext_rid >= 0) {
        int32_t htype=0, lq=(int32_t)l_query, nch=(int32_t)chn->n;
        int64_t hrid=ext_rid;
        int32_t cfg[10] = { opt->a, opt->b, opt->o_del, opt->e_del,
                            opt->o_ins, opt->e_ins, opt->w, opt->zdrop,
                            opt->pen_clip5, opt->pen_clip3 };
        fwrite(&htype,4,1,g_ext_fp); fwrite(&hrid,8,1,g_ext_fp);
        fwrite(&lq,4,1,g_ext_fp);    fwrite(&nch,4,1,g_ext_fp);
        fwrite(cfg,4,10,g_ext_fp);
        fwrite(query,1,(size_t)lq,g_ext_fp);          /* one byte per encoded base */
    }
    ext_unlock();
}
/* --- end HOOK-H ------------------------------------------------------------ */

/* --- STEP 3: HOOK-C (CHAIN) — in the per-chain loop `for (int j...)`, right after
 *     the rseq retrieval block `{ ... rseq = bns_fetch_seq_v2(...); assert(c->rid==rid); }`
 *     (:2169-2177). `j`,`c`,`rmax[0/1]`,`rseq`,`ext_rid` in scope. -------------- */
if (g_ext_enabled>0 && ext_rid >= 0) {
    ext_lock();
    int32_t ctype=1, cidx=(int32_t)j, ccrid=c->rid, ns=c->n;
    int64_t crid=ext_rid, rm0=rmax[0], rm1=rmax[1];
    float fr=c->frac_rep;
    fwrite(&ctype,4,1,g_ext_fp); fwrite(&crid,8,1,g_ext_fp);
    fwrite(&cidx,4,1,g_ext_fp);  fwrite(&ccrid,4,1,g_ext_fp);
    fwrite(&fr,4,1,g_ext_fp);
    fwrite(&rm0,8,1,g_ext_fp);   fwrite(&rm1,8,1,g_ext_fp);
    fwrite(&ns,4,1,g_ext_fp);
    for (int ci=0; ci<ns; ++ci){
        int64_t rb=c->seeds[ci].rbeg;
        int32_t qb=c->seeds[ci].qbeg, ln=c->seeds[ci].len, sc=c->seeds[ci].score;
        fwrite(&rb,8,1,g_ext_fp); fwrite(&qb,4,1,g_ext_fp);
        fwrite(&ln,4,1,g_ext_fp); fwrite(&sc,4,1,g_ext_fp);
    }
    int64_t rlen=rm1-rm0;
    fwrite(&rlen,8,1,g_ext_fp);
    fwrite(rseq,1,(size_t)rlen,g_ext_fp);
    ext_unlock();
}
/* --- end HOOK-C ------------------------------------------------------------ */


/* ===== SITE 2: mem_kernel2_core (src/bwamem.cpp @ :1118) =====================
 * --- STEP 4: HOOK-O (OUTPUT) — paste immediately AFTER the mem_chain2aln call,
 *     i.e. right after
 *        printf_(VER, "9. Done mem_chain2aln...\n\n");
 *        tprof[MEM_ALN2][tid] += __rdtsc() - tim;
 *     (:1147-1148), BEFORE the frac_rep/identical-hit/mem_sort_dedup_patch loops.
 *     `regs` (= av_v), `nseq` in scope; g_ext_tl_rid was filled at HOOK-H (same
 *     worker thread/batch). ---------------------------------------------------- */
if (g_ext_enabled>0) {
    for (int lo=0; lo<nseq; ++lo){
        if (lo >= (int)g_ext_tl_rid.size() || g_ext_tl_rid[lo] < 0) continue;
        ext_lock();
        int32_t otype=2, no=(int32_t)regs[lo].n; int64_t orid=g_ext_tl_rid[lo];
        fwrite(&otype,4,1,g_ext_fp); fwrite(&orid,8,1,g_ext_fp);
        fwrite(&no,4,1,g_ext_fp);
        for (int oi=0; oi<no; ++oi){
            const mem_alnreg_t *r=&regs[lo].a[oi];
            int64_t rb=r->rb, re=r->re;
            int32_t qb=r->qb, qe=r->qe, sc=r->score, tsc=r->truesc,
                    w=r->w, scov=r->seedcov, sl0=r->seedlen0, arid=r->rid;
            fwrite(&rb,8,1,g_ext_fp);  fwrite(&re,8,1,g_ext_fp);
            fwrite(&qb,4,1,g_ext_fp);  fwrite(&qe,4,1,g_ext_fp);
            fwrite(&sc,4,1,g_ext_fp);  fwrite(&tsc,4,1,g_ext_fp);
            fwrite(&w,4,1,g_ext_fp);   fwrite(&scov,4,1,g_ext_fp);
            fwrite(&sl0,4,1,g_ext_fp); fwrite(&arid,4,1,g_ext_fp);
        }
        ext_unlock();
    }
}
/* --- end HOOK-O ------------------------------------------------------------ */
