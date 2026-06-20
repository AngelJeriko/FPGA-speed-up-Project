/* ============================================================================
 * sel_capture.inc  —  PASTE-READY instrumentation for the mate-rescue CANDIDATE
 * SELECTION capture (validates host/mate_rescue/pe.h::matesw_pe_select, i.e. the
 * b[i] selection of mem_sam_pe_batch_post — NOT the per-call rescue, which
 * orch_capture covers).
 *
 * Captures one record per mem_sam_pe_batch_post call (read pair): for each end i,
 * the candidate-source scores a[i].a[*].score, the selection params, and the real
 * b[i].n (= count of a[i] with score >= a[i].a[0].score - pen_unpaired). The host
 * validator (check_sel) confirms pe.h's prefix-break selection reproduces b[i].n
 * AND that a[i] is score-sorted descending (so the prefix assumption holds).
 *
 * TARGET FILE: src/bwamem_pair.cpp (same file as matesw_/orch_capture; all 3 can
 * be armed together). Env ALNREG_SEL_OUT / ALNREG_SEL_MAX (default 200000 pairs).
 *
 * Record format (binary, native LE):
 *   type 0 SEL: i32 type=0; i64 call_id; i32 pen_unpaired; i32 max_matesw;
 *               2 * { i32 a_n; a_n*i32 score; i32 b_n }                // ends i=0,1
 * ============================================================================
 *
 * --- STEP 1: INFRA — paste at file scope (near orch_capture.inc's infra). ---
 */
/* --- INSTRUMENTATION (temporary): mate-rescue selection capture ------------- */
static FILE *g_sel_fp=NULL; static int g_sel_enabled=-1;
static long  g_sel_n=0, g_sel_max=200000;
static volatile int g_sel_lock=0;
static inline void sel_lock(void){ while(__sync_lock_test_and_set(&g_sel_lock,1)){} }
static inline void sel_unlock(void){ __sync_lock_release(&g_sel_lock); }
static void sel_init_once(void){
    if (g_sel_enabled>=0) return;
    sel_lock();
    if (g_sel_enabled<0){
        const char*p=getenv("ALNREG_SEL_OUT");
        if(p){ g_sel_fp=fopen(p,"wb"); g_sel_enabled=g_sel_fp?1:0; } else g_sel_enabled=0;
        const char*m=getenv("ALNREG_SEL_MAX"); if(m){ long v=atol(m); if(v>0) g_sel_max=v; }
    }
    sel_unlock();
}
struct SelDumper{ ~SelDumper(){ if(g_sel_fp) fclose(g_sel_fp); } };
static SelDumper g_sel_dumper;
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: HOOK — in mem_sam_pe_batch_post, IMMEDIATELY AFTER the b[i] build
 *     double-loop (the `kv_push(mem_alnreg_t, b[i], a[i].a[j]);` loop, ~line 790),
 *     i.e. right before `for (int l=0; l<a[0].n; l++) a[0].a[l].flg = 0;`.
 *     b[0],b[1],a[0],a[1],opt are all in scope. ---
 */
/* INSTRUMENTATION: selection capture — record a[i] scores + b[i].n per read pair */
sel_init_once();
if (g_sel_enabled>0) {
    sel_lock();
    int take = (g_sel_n < g_sel_max); long long cid = take ? g_sel_n++ : 0;
    if (take) {
        int32_t type=0; fwrite(&type,4,1,g_sel_fp); fwrite(&cid,8,1,g_sel_fp);
        int32_t pen=opt->pen_unpaired, mm=opt->max_matesw;
        fwrite(&pen,4,1,g_sel_fp); fwrite(&mm,4,1,g_sel_fp);
        for (int ii=0; ii<2; ++ii){
            int32_t an=a[ii].n; fwrite(&an,4,1,g_sel_fp);
            for (int jj=0; jj<a[ii].n; ++jj){ int32_t sc=a[ii].a[jj].score; fwrite(&sc,4,1,g_sel_fp); }
            int32_t bn=b[ii].n; fwrite(&bn,4,1,g_sel_fp);
        }
    }
    sel_unlock();
}
/* --- end HOOK -------------------------------------------------------------- */
