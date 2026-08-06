/* ============================================================================
 * ext_capture.inc — PASTE-READY instrumentation for the EXTEND-ORCHESTRATOR
 *   capture (instrument #5 of docs/bwamem2_instrumentation.md; env ALNREG_EXT_OUT).
 *
 *   ⚠️ RECONSTRUCTED (2026-08-06). The original hook was applied on the remote
 *   bwa-mem2 checkout, used to capture the golden, then reverted and never
 *   committed. This file reproduces its DOCUMENTED behaviour, in the exact idiom
 *   of the committed chain_capture.inc / clamp_capture.inc, from:
 *     - the byte format in host/extend_orchestrator/README.md, and
 *     - the anchors in docs/bwamem2_instrumentation.md (#5).
 *   The infra + fwrite sequences below are exact to the format spec; the bwa-mem2
 *   LOCAL NAMES at each hook are marked "⟨BIND⟩" — confirm them against your
 *   bwamem.cpp before building (they vary slightly by bwa-mem2 version).
 *
 *   ACCEPTANCE TEST (do this before trusting the capture):
 *     1) apply this + build (see host/bwamem2_patch/README.md),
 *     2) ALNREG_EXT_OUT=ext_vec.bin ALNREG_EXT_MAX=30000 \
 *          ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null
 *     3) gzip -c ext_vec.bin > host/extend_orchestrator/vectors/ext_vec.bin.gz
 *     4) cd host/extend_orchestrator && make run
 *   Expect: **30000/30000 reads bit-exact, 565,446 alnregs**. If it matches the
 *   committed golden, this reconstruction is byte-correct.
 *
 * Captures the inputs + output of mem_chain2aln_across_reads_V2. Three record
 * types, joined by read_id (records from concurrent threads interleave):
 *   type 0 HEADER: per read  — query + 10 opt SW-config fields
 *   type 1 CHAIN : per chain — rmax window, seeds, and the fetched ref bytes
 *   type 2 OUTPUT: per read  — assembled alnreg array, AFTER the redundancy purge
 *
 * TARGET FILE: src/bwamem.cpp (same file as chain_/clamp_capture.inc).
 * Env ALNREG_EXT_OUT / ALNREG_EXT_MAX (default 30000 reads).
 *
 * Record format (binary, native LE) — MUST equal host/extend_orchestrator/README.md:
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
 * --- STEP 1: INFRA — paste at file scope near the other *Dumper blocks in
 *     bwamem.cpp (e.g. just after the ExtDumper/ChnDumper infra). ------------- */
/* --- INSTRUMENTATION (temporary): extend-orchestrator (mem_chain2aln) capture */
static FILE *g_ext_fp=NULL; static int g_ext_enabled=-1;
static long  g_ext_reads=0, g_ext_max=30000;
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
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: HOOK-H (HEADER) — at the TOP of the per-read body of
 *     mem_chain2aln_across_reads_V2, where the read's encoded query and its
 *     chain list are in scope. Declare `long ext_rid` HERE (HOOK-C/O reuse it).
 *     ⟨BIND⟩ l_query = read length; query = const uint8_t* 2-bit-encoded bases;
 *            n_chains = number of chains for this read; opt = const mem_opt_t*.
 */
long ext_rid = -1;
ext_init_once();
if (g_ext_enabled>0) {
    ext_lock();
    if (g_ext_reads < g_ext_max) ext_rid = g_ext_reads++;
    if (ext_rid >= 0) {
        int32_t type=0, lq=(int32_t)/*⟨BIND⟩*/l_query, nch=(int32_t)/*⟨BIND⟩*/n_chains;
        int64_t rid64=ext_rid;
        int32_t cfg[10] = { opt->a, opt->b, opt->o_del, opt->e_del,
                            opt->o_ins, opt->e_ins, opt->w, opt->zdrop,
                            opt->pen_clip5, opt->pen_clip3 };
        fwrite(&type,4,1,g_ext_fp); fwrite(&rid64,8,1,g_ext_fp);
        fwrite(&lq,4,1,g_ext_fp);   fwrite(&nch,4,1,g_ext_fp);
        fwrite(cfg,4,10,g_ext_fp);
        fwrite(/*⟨BIND⟩*/query,1,(size_t)lq,g_ext_fp);  /* one byte per encoded base */
    }
    ext_unlock();
}
/* --- end HOOK-H ------------------------------------------------------------ */


/*
 * --- STEP 3: HOOK-C (CHAIN) — inside the per-chain loop, AFTER rmax[0]/rmax[1]
 *     are computed and the reference window is fetched (right after the
 *     bns_fetch_seq_v2 call that clamp_capture.inc wraps, ~bwamem.cpp:2172).
 *     ⟨BIND⟩ chain_idx = loop index; c = const mem_chain_t* (c->rid, c->n,
 *            c->frac_rep, c->seeds[]); rmax = int64_t[2]; rseq = uint8_t*
 *            reference window of length (rmax[1]-rmax[0]).
 */
if (g_ext_enabled>0 && ext_rid >= 0) {
    ext_lock();
    int32_t type=1, cidx=(int32_t)/*⟨BIND⟩*/chain_idx, crid=/*⟨BIND⟩*/c->rid, ns=/*⟨BIND⟩*/c->n;
    int64_t rid64=ext_rid, rm0=/*⟨BIND⟩*/rmax[0], rm1=/*⟨BIND⟩*/rmax[1];
    float fr=/*⟨BIND⟩*/c->frac_rep;
    fwrite(&type,4,1,g_ext_fp);  fwrite(&rid64,8,1,g_ext_fp);
    fwrite(&cidx,4,1,g_ext_fp);  fwrite(&crid,4,1,g_ext_fp);
    fwrite(&fr,4,1,g_ext_fp);
    fwrite(&rm0,8,1,g_ext_fp);   fwrite(&rm1,8,1,g_ext_fp);
    fwrite(&ns,4,1,g_ext_fp);
    for (int si=0; si<ns; ++si){
        int64_t rb=c->seeds[si].rbeg;
        int32_t qb=c->seeds[si].qbeg, ln=c->seeds[si].len, sc=c->seeds[si].score;
        fwrite(&rb,8,1,g_ext_fp); fwrite(&qb,4,1,g_ext_fp);
        fwrite(&ln,4,1,g_ext_fp); fwrite(&sc,4,1,g_ext_fp);
    }
    int64_t rlen=rm1-rm0;
    fwrite(&rlen,8,1,g_ext_fp);
    fwrite(/*⟨BIND⟩*/rseq,1,(size_t)rlen,g_ext_fp);
    ext_unlock();
}
/* --- end HOOK-C ------------------------------------------------------------ */


/*
 * --- STEP 4: HOOK-O (OUTPUT) — at the END of this read's processing, AFTER the
 *     cross-chain redundancy purge, where the final alnreg vector is complete.
 *     ⟨BIND⟩ av = mem_alnreg_v* (av->n, av->a[]) — the assembled output for the read.
 */
if (g_ext_enabled>0 && ext_rid >= 0) {
    ext_lock();
    int32_t type=2, no=(int32_t)/*⟨BIND⟩*/av->n; int64_t rid64=ext_rid;
    fwrite(&type,4,1,g_ext_fp); fwrite(&rid64,8,1,g_ext_fp);
    fwrite(&no,4,1,g_ext_fp);
    for (int oi=0; oi<no; ++oi){
        const mem_alnreg_t *r=&av->a[oi];
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
