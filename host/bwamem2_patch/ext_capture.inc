/* ============================================================================
 * ext_capture.inc — PASTE-READY instrumentation for the EXTEND-ORCHESTRATOR
 *   capture (instrument #5 of docs/bwamem2_instrumentation.md; env ALNREG_EXT_OUT).
 *
 *   RECONSTRUCTED (2026-08-06). The original hook was applied on the capture
 *   machine, used to produce the golden, then reverted (the local checkout's
 *   src/bwamem.cpp is back to its pristine 116,545 B), so the original code is not
 *   recoverable. This reproduces its DOCUMENTED behaviour, rebuilt from the byte
 *   format in host/extend_orchestrator/README.md and the anchors in the
 *   instrumentation doc, in the idiom of the committed chain_/clamp_capture.inc.
 *
 *   VERIFIED against the local bwa-mem2 checkout @ commit 97978f9:
 *     - format is byte-exact vs the reader host/extend_orchestrator/parse.h,
 *     - anchors + local names below are the REAL ones at that commit (line refs
 *       cited per hook); confirm them if you use a different bwa-mem2 commit.
 *   STRUCTURE NOTE (found via the checkout): the cross-chain redundancy purge is
 *   NOT inside mem_chain2aln_across_reads_V2 — it runs in the CALLER via
 *   mem_sort_dedup_patch(). So HEADER+CHAIN are captured inside mem_chain2aln, but
 *   the post-purge type-2 OUTPUT is captured at the caller (two sites, joined by a
 *   thread-local read_id — same worker thread handles a batch end to end).
 *
 *   ACCEPTANCE TEST (proves the ⟨value bindings⟩ + read_id join, which static
 *   review cannot): apply + build, then
 *     ALNREG_EXT_OUT=ext_vec.bin ALNREG_EXT_MAX=30000 \
 *       ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null
 *     gzip -c ext_vec.bin > host/extend_orchestrator/vectors/ext_vec.bin.gz
 *     ( cd host/extend_orchestrator && make run )
 *   Expect: **30000/30000 reads bit-exact, 565,446 alnregs** (the committed golden).
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
 * --- STEP 1: INFRA — paste at file scope in src/bwamem.cpp, near the other
 *     *Dumper blocks. Needs <vector> (already included by bwamem.cpp). ------- */
/* --- INSTRUMENTATION (temporary): extend-orchestrator (mem_chain2aln) capture */
#include <vector>
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
/* per-read id for the CURRENT batch, indexed by l; set at HEADER (inside
 * mem_chain2aln), read at OUTPUT (in the caller). thread_local because one worker
 * thread processes a whole batch end-to-end (mem_chain2aln + the purge loop). */
static thread_local std::vector<long> g_ext_tl_rid;
/* --- end instrumentation infra --------------------------------------------- */


/* ============================ SITE 1 — mem_chain2aln_across_reads_V2 =========
 * (commit 97978f9: function at bwamem.cpp:2069; per-read loop `for (int l...)`
 *  at :2108; query/l_query at :2116-2117; chn/av at :2119-2120; per-chain loop
 *  `for (int j...)` at :2133 with `c=&chn->a[j]`; rmax[] at :2145-2166; rseq from
 *  bns_fetch_seq_v2 at :2172.)
 *
 * --- STEP 2a: at the TOP of the per-read loop body (just after :2117 where
 *     `l_query` is set), size the id vector once for this batch: --------------- */
/* INSTRUMENTATION */ ext_init_once();
/* INSTRUMENTATION */ if (g_ext_enabled>0 && (int)g_ext_tl_rid.size() < nseq) g_ext_tl_rid.assign(nseq, -1);

/* --- STEP 2b: HOOK-H (HEADER) — same spot, right after STEP 2a. `query`,
 *     `l_query`, `chn` (chn->n = n_chains) and `opt` are all in scope here.
 *     Declares `long ext_rid` used by HOOK-C below (same per-read scope). ------ */
long ext_rid = -1;
if (g_ext_enabled>0) {
    ext_lock();
    if (g_ext_rid_next < g_ext_max) ext_rid = g_ext_rid_next++;
    g_ext_tl_rid[l] = ext_rid;                       /* carry to OUTPUT (SITE 2) */
    if (ext_rid >= 0) {
        int32_t type=0, lq=(int32_t)l_query, nch=(int32_t)chn->n;
        int64_t rid64=ext_rid;
        int32_t cfg[10] = { opt->a, opt->b, opt->o_del, opt->e_del,
                            opt->o_ins, opt->e_ins, opt->w, opt->zdrop,
                            opt->pen_clip5, opt->pen_clip3 };
        fwrite(&type,4,1,g_ext_fp); fwrite(&rid64,8,1,g_ext_fp);
        fwrite(&lq,4,1,g_ext_fp);   fwrite(&nch,4,1,g_ext_fp);
        fwrite(cfg,4,10,g_ext_fp);
        fwrite(query,1,(size_t)lq,g_ext_fp);          /* one byte per encoded base */
    }
    ext_unlock();
}
/* --- end HOOK-H ------------------------------------------------------------ */

/* --- STEP 3: HOOK-C (CHAIN) — inside the per-chain loop, AFTER rseq is fetched
 *     (i.e. right after the bns_fetch_seq_v2 block, :2172-2177). `j` = chain_idx,
 *     `c` = mem_chain_t*, `rmax[0]/rmax[1]`, `rseq` = uint8_t[rmax1-rmax0]. ---- */
if (g_ext_enabled>0 && ext_rid >= 0) {
    ext_lock();
    int32_t type=1, cidx=(int32_t)j, crid=c->rid, ns=c->n;
    int64_t rid64=ext_rid, rm0=rmax[0], rm1=rmax[1];
    float fr=c->frac_rep;
    fwrite(&type,4,1,g_ext_fp);  fwrite(&rid64,8,1,g_ext_fp);
    fwrite(&cidx,4,1,g_ext_fp);  fwrite(&crid,4,1,g_ext_fp);
    fwrite(&fr,4,1,g_ext_fp);
    fwrite(&rm0,8,1,g_ext_fp);   fwrite(&rm1,8,1,g_ext_fp);
    fwrite(&ns,4,1,g_ext_fp);
    for (int i=0; i<ns; ++i){
        int64_t rb=c->seeds[i].rbeg;
        int32_t qb=c->seeds[i].qbeg, ln=c->seeds[i].len, sc=c->seeds[i].score;
        fwrite(&rb,8,1,g_ext_fp); fwrite(&qb,4,1,g_ext_fp);
        fwrite(&ln,4,1,g_ext_fp); fwrite(&sc,4,1,g_ext_fp);
    }
    int64_t rlen=rm1-rm0;
    fwrite(&rlen,8,1,g_ext_fp);
    fwrite(rseq,1,(size_t)rlen,g_ext_fp);
    ext_unlock();
}
/* --- end HOOK-C ------------------------------------------------------------ */


/* ============================ SITE 2 — the caller (post-purge) ===============
 * (commit 97978f9: mem_chain2aln called at :1111 with output vector `regs`; the
 *  per-read purge loop is `for (int l...) { regs[l].n = mem_sort_dedup_patch(
 *  opt, ..., regs[l].n, regs[l].a); }` at :1154-1155. `regs[l]` == av_v[l].)
 *
 * --- STEP 4: HOOK-O (OUTPUT) — paste INSIDE that loop, immediately AFTER the
 *     `regs[l].n = mem_sort_dedup_patch(...)` assignment (:1155), so regs[l] is
 *     the POST-purge array. Same worker thread as SITE 1 → g_ext_tl_rid[l] is the
 *     read_id assigned at HOOK-H. ---------------------------------------------- */
if (g_ext_enabled>0 && l < (int)g_ext_tl_rid.size() && g_ext_tl_rid[l] >= 0) {
    ext_lock();
    int32_t type=2, no=(int32_t)regs[l].n; int64_t rid64=g_ext_tl_rid[l];
    fwrite(&type,4,1,g_ext_fp); fwrite(&rid64,8,1,g_ext_fp);
    fwrite(&no,4,1,g_ext_fp);
    for (int oi=0; oi<no; ++oi){
        const mem_alnreg_t *r=&regs[l].a[oi];
        int64_t rb=r->rb, re=r->re;
        int32_t qb=r->qb, qe=r->qe, sc=r->score, tsc=r->truesc,
                w=r->w, scov=r->seedcov, sl0=r->seedlen0, orid=r->rid;
        fwrite(&rb,8,1,g_ext_fp);  fwrite(&re,8,1,g_ext_fp);
        fwrite(&qb,4,1,g_ext_fp);  fwrite(&qe,4,1,g_ext_fp);
        fwrite(&sc,4,1,g_ext_fp);  fwrite(&tsc,4,1,g_ext_fp);
        fwrite(&w,4,1,g_ext_fp);   fwrite(&scov,4,1,g_ext_fp);
        fwrite(&sl0,4,1,g_ext_fp); fwrite(&orid,4,1,g_ext_fp);
    }
    ext_unlock();
}
/* --- end HOOK-O ------------------------------------------------------------ */
