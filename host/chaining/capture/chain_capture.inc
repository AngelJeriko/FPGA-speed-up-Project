/* ============================================================================
 * chain_capture.inc  —  PASTE-READY instrumentation for the CHAINING capture.
 *
 * Goal: validate the chaining C++ model (host/chaining/chain.h) bit-exact vs real
 * bwa-mem2 (mem_chain can't compile standalone — kbtree/bns/FM deps). Two
 * SELF-CONTAINED record types, no cross-join needed:
 *   type 0 SEEDSTREAM: the ordered seed stream entering mem_chain + the resulting
 *                      PRE-flt chains  -> validates c_mem_chain (kbtree replacement).
 *   type 1 FLT:        the PRE-flt chains in + the POST-flt chains out of
 *                      mem_chain_flt -> validates c_mem_chain_flt (weight/overlap
 *                      filter + the ks_introsort tie-order risk).
 *
 * TARGET FILE: src/bwamem.cpp  (same file the ext-capture lives in).
 * Env-gated (ALNREG_CHAIN_OUT); ALNREG_CHAIN_MAX caps records of EACH type.
 *
 * Record format (binary, native little-endian); a CHAIN sub-record is:
 *   i32 rid; i32 seqid; i64 pos; i32 is_alt; i32 n;
 *   n*{ i64 rbeg; i32 qbeg; i32 len; i32 score }
 *
 *   type 0 SEEDSTREAM: i32 type=0; i64 read_id; i32 seqid; i64 l_pac;
 *                      i32 n_seeds;
 *                      n_seeds*{ i64 rbeg; i32 qbeg; i32 len; i32 score;
 *                                i32 rid; i32 is_alt };
 *                      i32 n_chains; n_chains*CHAIN
 *   type 1 FLT:        i32 type=1; i64 flt_id;
 *                      i32 n_in;  n_in *CHAIN;
 *                      i32 n_out; n_out*CHAIN
 * ============================================================================
 *
 * --- STEP 1: paste this INFRA block at file scope near the other *Dumper
 *     blocks in bwamem.cpp (e.g. just after the ExtDumper block, ~line 553). ---
 */
/* --- INSTRUMENTATION (temporary): chaining (mem_chain / mem_chain_flt) capture */
static FILE *g_chn_fp=NULL; static int g_chn_enabled=-1;
static long  g_chn_reads=0, g_chn_flts=0, g_chn_max=30000;
static volatile int g_chn_lock=0;
static inline void chn_lock(void){ while(__sync_lock_test_and_set(&g_chn_lock,1)){} }
static inline void chn_unlock(void){ __sync_lock_release(&g_chn_lock); }
static void chn_init_once(void){
    if (g_chn_enabled>=0) return;
    chn_lock();
    if (g_chn_enabled<0){
        const char*p=getenv("ALNREG_CHAIN_OUT");
        if(p){ g_chn_fp=fopen(p,"wb"); g_chn_enabled=g_chn_fp?1:0; } else g_chn_enabled=0;
        const char*m=getenv("ALNREG_CHAIN_MAX"); if(m){ long v=atol(m); if(v>0) g_chn_max=v; }
    }
    chn_unlock();
}
/* write one CHAIN sub-record from a mem_chain_t* (lock already held) */
static inline void chn_write_chain(const mem_chain_t *c){
    int32_t rid=c->rid, seqid=c->seqid, isalt=c->is_alt?1:0, n=c->n;
    int64_t pos=c->pos;
    fwrite(&rid,4,1,g_chn_fp);  fwrite(&seqid,4,1,g_chn_fp);
    fwrite(&pos,8,1,g_chn_fp);  fwrite(&isalt,4,1,g_chn_fp);
    fwrite(&n,4,1,g_chn_fp);
    for (int si=0; si<n; ++si){
        int64_t rb=c->seeds[si].rbeg;
        int32_t qb=c->seeds[si].qbeg, ln=c->seeds[si].len, sc=c->seeds[si].score;
        fwrite(&rb,8,1,g_chn_fp); fwrite(&qb,4,1,g_chn_fp);
        fwrite(&ln,4,1,g_chn_fp); fwrite(&sc,4,1,g_chn_fp);
    }
}
struct ChnSeed { int64_t rbeg; int32_t qbeg, len, score, rid, is_alt; };
struct ChnDumper{ ~ChnDumper(){ if(g_chn_fp) fclose(g_chn_fp); } };
static ChnDumper g_chn_dumper;
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: in the mem_chain seed loop (function around line 841; the loop
 *     building each seed `s`). Accumulate the ordered seed stream per read.
 *
 *     Anchor (existing code, ~line 945-949):
 *         rid = bns_intv2rid(bns, s.rbeg, s.rbeg + s.len);
 *         if (rid < 0) continue;
 *      >>>>  <PASTE HOOK-A HERE, immediately AFTER `if (rid < 0) continue;`>  <<<<
 *
 *     `bns`, `l_pac`, and `l` (the read/seqid) are all in scope here.
 *     Declare the per-read buffer ONCE at the top of the read loop (STEP 2a).
 */
/* STEP 2a: declare at the top of the per-read loop body (where `l` is set): */
/* INSTRUMENTATION */ std::vector<ChnSeed> chn_stream;   chn_stream.clear();

/* STEP 2b: HOOK-A — push each accepted seed (right after `if (rid<0) continue;`): */
/* INSTRUMENTATION: chaining capture — accumulate ordered seed stream */
{
    chn_init_once();
    if (g_chn_enabled>0) {
        ChnSeed cs; cs.rbeg=s.rbeg; cs.qbeg=s.qbeg; cs.len=s.len;
        cs.score=s.score; cs.rid=rid; cs.is_alt=!!bns->anns[rid].is_alt;
        chn_stream.push_back(cs);
    }
}
/* --- end HOOK-A ------------------------------------------------------------ */


/*
 * --- STEP 3: HOOK-B — after the pre-flt chains are materialised for read `l`.
 *     Anchor (existing code, ~line 991-998):
 *         #define traverse_func(p_) (chain->a[chain->n++] = *(p_))
 *             __kb_traverse(mem_chain_t, tree, traverse_func);
 *         #undef traverse_func
 *             for (i = 0; i < chain->n; ++i)
 *                 chain->a[i].frac_rep = (float)l_rep / seq_[l].l_seq;
 *      >>>>  <PASTE HOOK-B HERE, before kb_destroy(chn, tree);>  <<<<
 *             kb_destroy(chn, tree);
 *
 *     `chain` is the mem_chain_v* just filled (chain->a, chain->n).
 */
/* INSTRUMENTATION: chaining capture — SEEDSTREAM + resulting pre-flt chains */
if (g_chn_enabled>0) {
    chn_lock();
    if (g_chn_reads < g_chn_max) {
        g_chn_reads++;
        int32_t type=0, seqid=(int32_t)l, ns=(int32_t)chn_stream.size();
        int64_t rid64=g_chn_reads-1, lpac=l_pac;
        fwrite(&type,4,1,g_chn_fp);  fwrite(&rid64,8,1,g_chn_fp);
        fwrite(&seqid,4,1,g_chn_fp); fwrite(&lpac,8,1,g_chn_fp);
        fwrite(&ns,4,1,g_chn_fp);
        for (int si=0; si<ns; ++si){
            ChnSeed &cs=chn_stream[si];
            fwrite(&cs.rbeg,8,1,g_chn_fp); fwrite(&cs.qbeg,4,1,g_chn_fp);
            fwrite(&cs.len,4,1,g_chn_fp);  fwrite(&cs.score,4,1,g_chn_fp);
            fwrite(&cs.rid,4,1,g_chn_fp);  fwrite(&cs.is_alt,4,1,g_chn_fp);
        }
        int32_t nch=chain->n;
        fwrite(&nch,4,1,g_chn_fp);
        for (int ci=0; ci<chain->n; ++ci) chn_write_chain(&chain->a[ci]);
    }
    chn_unlock();
}
/* --- end HOOK-B ------------------------------------------------------------ */


/*
 * --- STEP 4: HOOK-C — wrap the mem_chain_flt call (function around line 1095).
 *     Anchor (existing code, ~line 1101-1107):
 *         printf_(VER, "6.1. Calling mem_chain_flt..\n");
 *         for (...) {
 *             mem_chain_v *chn = &chain_ar[l];
 *      >>>>  <SNAPSHOT pre-flt chains HERE>  <<<<
 *             chn->n = mem_chain_flt(opt, chn->n, chn->a, tid);
 *      >>>>  <WRITE record using post-flt chn HERE>  <<<<
 *         }
 *
 *     mem_chain_flt sorts/compacts chn->a in place, so snapshot the PRE chains
 *     (rid/seqid/pos/is_alt/seeds) into a temporary BEFORE the call.
 */
/* INSTRUMENTATION: chaining capture — FLT in/out (paste around the flt call) */
/* (a) before `chn->n = mem_chain_flt(...)`: DEEP-COPY seeds — mem_chain_flt FREES the
 *     seeds of dropped chains with m>SEEDS_PER_CHAIN(=1) during compaction, so a shallow
 *     snapshot read AFTER the call returns FREED (garbage) seeds for dropped multi-seed
 *     chains. Deep-copy makes flt_in self-contained. */
int32_t flt_n_in = chn->n; mem_chain_t *flt_in = NULL;
if (g_chn_enabled>0 && flt_n_in > 0) {
    flt_in = (mem_chain_t*)malloc(sizeof(mem_chain_t)*flt_n_in);
    for (int ci=0; ci<flt_n_in; ++ci) {
        flt_in[ci] = chn->a[ci];
        mem_seed_t* sd_ = (mem_seed_t*)malloc(sizeof(mem_seed_t)*(chn->a[ci].n>0?chn->a[ci].n:1));
        for (int si=0; si<chn->a[ci].n; ++si) sd_[si] = chn->a[ci].seeds[si];
        flt_in[ci].seeds = sd_;   /* own copy, immune to mem_chain_flt's free() */
    }
}
/* (b) after the call, with the post-flt chn: */
if (g_chn_enabled>0) {
    chn_lock();
    if (g_chn_flts < g_chn_max) {
        g_chn_flts++;
        int32_t type=1; int64_t fid=g_chn_flts-1;
        fwrite(&type,4,1,g_chn_fp); fwrite(&fid,8,1,g_chn_fp);
        fwrite(&flt_n_in,4,1,g_chn_fp);
        for (int ci=0; ci<flt_n_in; ++ci) chn_write_chain(&flt_in[ci]);
        int32_t no=chn->n;
        fwrite(&no,4,1,g_chn_fp);
        for (int ci=0; ci<chn->n; ++ci) chn_write_chain(&chn->a[ci]);
    }
    chn_unlock();
}
if (flt_in) { for (int ci=0; ci<flt_n_in; ++ci) free(flt_in[ci].seeds); free(flt_in); }
/* --- end HOOK-C ------------------------------------------------------------ */
