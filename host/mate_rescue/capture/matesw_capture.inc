/* ============================================================================
 * matesw_capture.inc  —  PASTE-READY instrumentation for the MATE-RESCUE capture.
 *
 * Goal: dump the real batched SIMD SW (kswv / getScores8|16) inputs and outputs
 * so the host validator can confirm  kswv512 == ksw_align2 == hw_align2 (hw.h)
 * on REAL mate-rescue data. Env-gated (ALNREG_MATE_OUT); zero cost when unset.
 *
 * TARGET FILE (remote + Desktop checkout):  src/bwamem_pair.cpp
 * This is a SECOND instrumented file beyond bwamem.cpp — remember to revert BOTH.
 *
 * Record format (binary, native little-endian; join INPUT<->OUTPUT by aln_id):
 *   type 0 INPUT : i32 type=0; i64 aln_id; i32 qlen; i32 tlen; i32 xtra;
 *                  i32 a; i32 b; i32 o_del; i32 e_del; i32 o_ins; i32 e_ins;
 *                  u8 query[qlen]; u8 ref[tlen]
 *   type 1 OUTPUT: i32 type=1; i64 aln_id; i32 score; i32 qb; i32 qe;
 *                  i32 tb; i32 te
 * ============================================================================
 *
 * --- STEP 1: paste this INFRA block at file scope, near the top of
 *     bwamem_pair.cpp (after the #includes, before mem_sam_pe_batch). ---------
 */
/* --- INSTRUMENTATION (temporary): mate-rescue (kswv) golden capture --------- */
#include <vector>
static FILE *g_mate_fp=NULL; static int g_mate_enabled=-1;
static long  g_mate_n=0, g_mate_max=200000;
static volatile int g_mate_lock=0;
static inline void mate_lock(void){ while(__sync_lock_test_and_set(&g_mate_lock,1)){} }
static inline void mate_unlock(void){ __sync_lock_release(&g_mate_lock); }
static void mate_init_once(void){
    if (g_mate_enabled>=0) return;
    mate_lock();
    if (g_mate_enabled<0){
        const char*p=getenv("ALNREG_MATE_OUT");
        if(p){ g_mate_fp=fopen(p,"wb"); g_mate_enabled=g_mate_fp?1:0; } else g_mate_enabled=0;
        const char*m=getenv("ALNREG_MATE_MAX"); if(m){ long v=atol(m); if(v>0) g_mate_max=v; }
    }
    mate_unlock();
}
struct MateDumper{ ~MateDumper(){ if(g_mate_fp) fclose(g_mate_fp); } };
static MateDumper g_mate_dumper;
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: inside int mem_sam_pe_batch(...), in the AVX512 ( #else ) branch.
 *     Add a per-call snapshot vector + capture the INPUTS right BEFORE the
 *     forward getScores8/getScores16 calls (seqs are still pristine here —
 *     post-processing reverses them in place later).
 *
 *     Anchor (existing code, ~line 636-657):
 *
 *         #else   // avx512, vectorized function
 *             for (int i=0; i<pcnt; i++) { kswr_t *r=&aln[i]; r->tb=r->qb=-1; }
 *             int nthreads = 1;
 *             kswv *pwsw = new kswv(...);
 *             // Shift 16-bit
 *             for (int i=0; i<pcnt-pcnt8; i++) seqPairArray[...]=seqPairArray[...];
 *         #if __AVX512BW__
 *      >>>>  <PASTE HOOK-A HERE, immediately before getScores8>  <<<<
 *             pwsw->getScores8(...);
 *             pwsw->getScores16(...);
 *
 *     Note: opt->a/opt->b/opt->o_del/... are in scope via `opt`.
 */
/* INSTRUMENTATION: mate-rescue capture — snapshot inputs (pristine seqs) */
std::vector<std::pair<long long,int> > mate_cap;   /* (aln_id, regid) */
{
    mate_init_once();
    if (g_mate_enabled>0) {
        for (int i=0; i<pcnt; i++) {
            SeqPair sp = seqPairArray[i];
            int qlen = sp.len2, tlen = sp.len1, xtra = sp.h0, regid = sp.regid;
            const uint8_t *qs = seqBufQer + sp.idq;
            const uint8_t *rs = seqBufRef + sp.idr;
            mate_lock();
            if (g_mate_n < g_mate_max) {
                long long aid = g_mate_n++;
                int32_t type=0, q=qlen, t=tlen, x=xtra;
                int32_t a=opt->a, b=opt->b, od=opt->o_del, ed=opt->e_del,
                        oi=opt->o_ins, ei=opt->e_ins;
                fwrite(&type,4,1,g_mate_fp); fwrite(&aid,8,1,g_mate_fp);
                fwrite(&q,4,1,g_mate_fp);    fwrite(&t,4,1,g_mate_fp);
                fwrite(&x,4,1,g_mate_fp);
                fwrite(&a,4,1,g_mate_fp);    fwrite(&b,4,1,g_mate_fp);
                fwrite(&od,4,1,g_mate_fp);   fwrite(&ed,4,1,g_mate_fp);
                fwrite(&oi,4,1,g_mate_fp);   fwrite(&ei,4,1,g_mate_fp);
                fwrite(qs,1,(size_t)qlen,g_mate_fp);
                fwrite(rs,1,(size_t)tlen,g_mate_fp);
                mate_cap.push_back(std::make_pair(aid, regid));
            }
            mate_unlock();
        }
    }
}
/* --- end HOOK-A ------------------------------------------------------------ */


/*
 * --- STEP 3: capture the OUTPUTS at the very END of the AVX512 branch, AFTER
 *     the reverse-pass getScores (so aln[regid] holds final score/qb/qe/tb/te).
 *
 *     Anchor (existing code, ~line 699-708):
 *
 *         #if __AVX512BW__
 *             pwsw->getScores16(seqPairArray + pos8, ...);
 *             pwsw->getScores8 (seqPairArray, ...);
 *         #else ... #endif
 *             delete(pwsw);
 *      >>>>  <PASTE HOOK-B HERE, immediately after delete(pwsw)>  <<<<
 *         #endif
 */
/* INSTRUMENTATION: mate-rescue capture — final outputs (post reverse pass) */
if (g_mate_enabled>0 && !mate_cap.empty()) {
    mate_lock();
    for (size_t k=0; k<mate_cap.size(); ++k) {
        long long aid = mate_cap[k].first; int regid = mate_cap[k].second;
        kswr_t r = aln[regid];
        int32_t type=1, sc=r.score, qb=r.qb, qe=r.qe, tb=r.tb, te=r.te;
        fwrite(&type,4,1,g_mate_fp); fwrite(&aid,8,1,g_mate_fp);
        fwrite(&sc,4,1,g_mate_fp);   fwrite(&qb,4,1,g_mate_fp);
        fwrite(&qe,4,1,g_mate_fp);   fwrite(&tb,4,1,g_mate_fp);
        fwrite(&te,4,1,g_mate_fp);
    }
    mate_unlock();
}
/* --- end HOOK-B ------------------------------------------------------------ */
