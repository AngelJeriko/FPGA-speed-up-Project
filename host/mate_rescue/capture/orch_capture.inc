/* ============================================================================
 * orch_capture.inc  —  PASTE-READY instrumentation for the mate-rescue
 * ORCHESTRATION capture (validates host/mate_rescue/orch.h, not just the kernel).
 *
 * Captures one record per mem_matesw_batch_post call: the mapped mate alnreg `a`,
 * the unmapped mate seq, pe-stats, l_pac, scoring cfg, the entry ma list, the
 * per-orientation host-fed windows (post-bns_fetch_seq {used,rb,re,rid,ref}), and
 * the exit ma list. The host validator replays through matesw_orchestrate() and
 * compares the exit ma.
 *
 * TARGET FILE: src/bwamem_pair.cpp  (same file as matesw_capture.inc — the
 * kernel-level capture; both can be armed together). Env ALNREG_ORCH_OUT /
 * ALNREG_ORCH_MAX (default 100000 calls).
 *
 * Record format (binary, native LE). ALNREG_REC (32 B) =
 *   i64 rb; i64 re; i32 qb; i32 qe; i32 rid; i32 is_alt; i32 score; i32 seedcov
 *   type 0 ORCH: i32 type=0; i64 call_id;
 *                i64 a_rb; i32 a_rid; i32 a_is_alt;
 *                i64 l_pac; i32 l_ms; u8 ms[l_ms];
 *                i32 cfg[7]={a,b,o_del,e_del,o_ins,e_ins,min_seed_len};
 *                4*{ i32 failed; i64 low; i64 high };                  // pes[4]
 *                i32 n_in;  n_in *ALNREG_REC;                          // ma @entry
 *                4*{ i32 used; i64 rb; i64 re; i32 rid; i64 reflen; u8 ref[reflen] };
 *                i32 n_out; n_out*ALNREG_REC;                          // ma @exit
 * ============================================================================
 *
 * --- STEP 1: INFRA — paste at file scope (near matesw_capture.inc's infra). ---
 */
/* --- INSTRUMENTATION (temporary): mate-rescue orchestration capture --------- */
#include <vector>
static FILE *g_orch_fp=NULL; static int g_orch_enabled=-1;
static long  g_orch_n=0, g_orch_max=100000;
static volatile int g_orch_lock=0;
static inline void orch_lock(void){ while(__sync_lock_test_and_set(&g_orch_lock,1)){} }
static inline void orch_unlock(void){ __sync_lock_release(&g_orch_lock); }
static void orch_init_once(void){
    if (g_orch_enabled>=0) return;
    orch_lock();
    if (g_orch_enabled<0){
        const char*p=getenv("ALNREG_ORCH_OUT");
        if(p){ g_orch_fp=fopen(p,"wb"); g_orch_enabled=g_orch_fp?1:0; } else g_orch_enabled=0;
        const char*m=getenv("ALNREG_ORCH_MAX"); if(m){ long v=atol(m); if(v>0) g_orch_max=v; }
    }
    orch_unlock();
}
struct OrchWin { int used; int64_t rb, re; int rid; std::vector<uint8_t> ref; };
/* per-call thread-local capture state */
struct OrchCap {
    int on; long long id;
    int64_t a_rb; int a_rid, a_is_alt;
    int64_t l_pac; int l_ms; const uint8_t* ms;
    int cfg[7]; int pes_failed[4]; int64_t pes_low[4], pes_high[4];
    std::vector<int64_t> in_rb, in_re; std::vector<int> in_qb,in_qe,in_rid,in_alt,in_sc,in_cov;
    OrchWin win[4];
    void reset(){ on=0; in_rb.clear(); in_re.clear(); in_qb.clear(); in_qe.clear();
        in_rid.clear(); in_alt.clear(); in_sc.clear(); in_cov.clear();
        for(int r=0;r<4;++r){ win[r].used=0; win[r].rid=-1; win[r].ref.clear(); } }
};
static thread_local OrchCap g_oc;
static inline void orch_wrec(int64_t rb,int64_t re,int qb,int qe,int rid,int alt,int sc,int cov){
    fwrite(&rb,8,1,g_orch_fp); fwrite(&re,8,1,g_orch_fp);
    int32_t a=qb,b=qe,c=rid,d=alt,e=sc,f=cov;
    fwrite(&a,4,1,g_orch_fp); fwrite(&b,4,1,g_orch_fp); fwrite(&c,4,1,g_orch_fp);
    fwrite(&d,4,1,g_orch_fp); fwrite(&e,4,1,g_orch_fp); fwrite(&f,4,1,g_orch_fp);
}
struct OrchDumper{ ~OrchDumper(){ if(g_orch_fp) fclose(g_orch_fp); } };
static OrchDumper g_orch_dumper;
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: HOOK-ENTRY — at the TOP of mem_matesw_batch_post, right after
 *     `int64_t l_pac = bns->l_pac;` (~line 1113). Snapshot the entry state. ---
 */
/* INSTRUMENTATION: orchestration capture — entry snapshot */
orch_init_once();
g_oc.reset();
if (g_orch_enabled>0) {
    orch_lock(); int take = (g_orch_n < g_orch_max); if (take) g_oc.id = g_orch_n++;
    orch_unlock();
    if (take) {
        g_oc.on = 1;
        g_oc.a_rb = a->rb; g_oc.a_rid = a->rid; g_oc.a_is_alt = a->is_alt;
        g_oc.l_pac = l_pac; g_oc.l_ms = l_ms; g_oc.ms = ms;
        g_oc.cfg[0]=opt->a; g_oc.cfg[1]=opt->b; g_oc.cfg[2]=opt->o_del; g_oc.cfg[3]=opt->e_del;
        g_oc.cfg[4]=opt->o_ins; g_oc.cfg[5]=opt->e_ins; g_oc.cfg[6]=opt->min_seed_len;
        for (int r=0;r<4;++r){ g_oc.pes_failed[r]=pes[r].failed; g_oc.pes_low[r]=pes[r].low; g_oc.pes_high[r]=pes[r].high; }
        for (int i=0;i<ma->n;++i){ mem_alnreg_t*x=&ma->a[i];
            g_oc.in_rb.push_back(x->rb); g_oc.in_re.push_back(x->re);
            g_oc.in_qb.push_back(x->qb); g_oc.in_qe.push_back(x->qe);
            g_oc.in_rid.push_back(x->rid); g_oc.in_alt.push_back(x->is_alt);
            g_oc.in_sc.push_back(x->score); g_oc.in_cov.push_back(x->seedcov); }
    }
}
/* --- end HOOK-ENTRY -------------------------------------------------------- */


/*
 * --- STEP 3: HOOK-WIN — inside the r-loop, immediately AFTER the gate-entry line
 *     `if (a->rid == rid && re - rb >= opt->min_seed_len) {` (~line 1158), i.e.
 *     as the FIRST statement inside that block. (Only fetched/gate-passing
 *     orientations reach here; skipped ones `continue` earlier and no-fetch ones
 *     fail the gate — both correctly leave win[r].used=0.)  `ref`,`rb`,`re`,`rid`
 *     are the post-bns_fetch_seq values. ---
 */
/* INSTRUMENTATION: orchestration capture — per-orientation window */
if (g_oc.on) {
    g_oc.win[r].used = 1; g_oc.win[r].rb = rb; g_oc.win[r].re = re; g_oc.win[r].rid = rid;
    g_oc.win[r].ref.assign(ref, ref + (re - rb));
}
/* --- end HOOK-WIN ---------------------------------------------------------- */


/*
 * --- STEP 4: HOOK-EXIT — at EVERY return of mem_matesw_batch_post: the
 *     early `return 0;` (all-skip, ~line 1128) AND the final `return n;` (~line
 *     1247). Paste this block right before each. It writes the full record using
 *     the CURRENT ma (= exit list). ---
 */
/* INSTRUMENTATION: orchestration capture — write record (paste before each return) */
if (g_oc.on) {
    orch_lock();
    int32_t type=0; int64_t cid=g_oc.id;
    fwrite(&type,4,1,g_orch_fp); fwrite(&cid,8,1,g_orch_fp);
    int64_t arb=g_oc.a_rb; int32_t arid=g_oc.a_rid, aalt=g_oc.a_is_alt;
    fwrite(&arb,8,1,g_orch_fp); fwrite(&arid,4,1,g_orch_fp); fwrite(&aalt,4,1,g_orch_fp);
    int64_t lp=g_oc.l_pac; int32_t lms=g_oc.l_ms;
    fwrite(&lp,8,1,g_orch_fp); fwrite(&lms,4,1,g_orch_fp);
    fwrite(g_oc.ms,1,(size_t)g_oc.l_ms,g_orch_fp);
    fwrite(g_oc.cfg,4,7,g_orch_fp);
    for (int r=0;r<4;++r){ int32_t fl=g_oc.pes_failed[r]; int64_t lo=g_oc.pes_low[r], hi=g_oc.pes_high[r];
        fwrite(&fl,4,1,g_orch_fp); fwrite(&lo,8,1,g_orch_fp); fwrite(&hi,8,1,g_orch_fp); }
    int32_t nin=(int32_t)g_oc.in_rb.size(); fwrite(&nin,4,1,g_orch_fp);
    for (int i=0;i<nin;++i) orch_wrec(g_oc.in_rb[i],g_oc.in_re[i],g_oc.in_qb[i],g_oc.in_qe[i],
                                      g_oc.in_rid[i],g_oc.in_alt[i],g_oc.in_sc[i],g_oc.in_cov[i]);
    for (int r=0;r<4;++r){ int32_t u=g_oc.win[r].used; int64_t wrb=g_oc.win[r].rb,wre=g_oc.win[r].re;
        int32_t wrid=g_oc.win[r].rid; int64_t rl=(int64_t)g_oc.win[r].ref.size();
        fwrite(&u,4,1,g_orch_fp); fwrite(&wrb,8,1,g_orch_fp); fwrite(&wre,8,1,g_orch_fp);
        fwrite(&wrid,4,1,g_orch_fp); fwrite(&rl,8,1,g_orch_fp);
        if (rl) fwrite(g_oc.win[r].ref.data(),1,(size_t)rl,g_orch_fp); }
    int32_t nout=ma->n; fwrite(&nout,4,1,g_orch_fp);
    for (int i=0;i<ma->n;++i){ mem_alnreg_t*x=&ma->a[i];
        orch_wrec(x->rb,x->re,x->qb,x->qe,x->rid,x->is_alt,x->score,x->seedcov); }
    g_oc.on=0;
    orch_unlock();
}
/* --- end HOOK-EXIT --------------------------------------------------------- */
