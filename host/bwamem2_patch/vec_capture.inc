/* ============================================================================
 * vec_capture.inc — PASTE-READY instrumentation for the MERGE-SORTER v1 score-sort
 *   vector dumper (instrument #2 of docs/bwamem2_instrumentation.md; env ALNREG_VEC_OUT).
 *   Produces the golden that verifies host/merge_sorter (v1 model) + rtl/msort_* (tb_msort).
 *
 *   ✅ VALIDATED (2026-08-06) — applied to bwa-mem2 @ commit 97978f9, built, and a
 *   fresh capture (50k HG00733 pairs) replayed through host/merge_sorter/test_sorter
 *   gave **7698/7698 records bit-exact, packing!=cmp = 0, ALL PASS**.
 *
 *   Captures, per post-dedup array, the (score,rb,qb) INPUT entering the score sort
 *   `ks_introsort(mem_ars, n, a)` (alnreg_slt = score DESC, rb ASC, qb ASC) plus the
 *   real ks_introsort OUTPUT (ground truth). Per-size quota 32 (env ALNREG_VEC_QUOTA),
 *   n in [2, 1060] (env ALNREG_VEC_NMAX). Env-gated (ALNREG_VEC_OUT).
 *
 *   TARGET FILE: src/bwamem.cpp, function mem_sort_dedup_patch (@ :292). Byte format
 *   matches host/merge_sorter/test_sorter.cpp:
 *     record = i32 n; n*{i32 score; i64 rb; i32 qb} INPUT; n*{i32 score; i64 rb; i32 qb} EXPECTED
 *
 *   RE-VALIDATE: ALNREG_VEC_OUT=vec.bin ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null
 *     ( cd host/merge_sorter && make test_sorter && ./test_sorter /path/vec.bin )  -> "RESULT: ALL PASS"
 * ============================================================================
 *
 * --- STEP 1: INFRA — paste at file scope (e.g. right after `#include "kbtree.h"`). */
/* --- INSTRUMENTATION (temporary): merge-sorter score-sort vector dumper ----- */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
static FILE *g_vec_fp=NULL; static int g_vec_enabled=-1;
static int  g_vec_nmax=1060, g_vec_quota=32;
static int *g_vec_seen=NULL;
static volatile int g_vec_lock=0;
static inline void vec_lock(void){ while(__sync_lock_test_and_set(&g_vec_lock,1)){} }
static inline void vec_unlock(void){ __sync_lock_release(&g_vec_lock); }
static void vec_init_once(void){
    if (g_vec_enabled>=0) return;
    vec_lock();
    if (g_vec_enabled<0){
        const char*p=getenv("ALNREG_VEC_OUT");
        if(p){ g_vec_fp=fopen(p,"wb"); g_vec_enabled=g_vec_fp?1:0; } else g_vec_enabled=0;
        const char*q=getenv("ALNREG_VEC_QUOTA"); if(q){int v=atoi(q); if(v>0) g_vec_quota=v;}
        const char*x=getenv("ALNREG_VEC_NMAX");  if(x){int v=atoi(x); if(v>0) g_vec_nmax=v;}
        if(g_vec_enabled>0){ g_vec_seen=(int*)calloc((size_t)g_vec_nmax+1,sizeof(int)); }
    }
    vec_unlock();
}
struct VecDumper{ ~VecDumper(){ if(g_vec_fp) fclose(g_vec_fp); } };
static VecDumper g_vec_dumper;
/* --- end instrumentation infra --------------------------------------------- */

/* --- STEP 2: in mem_sort_dedup_patch, REPLACE the post-dedup score sort
 *     `n = m; ks_introsort(mem_ars, n, a);` (@ :341-342) with the block below —
 *     it snapshots INPUT before the sort and writes INPUT+EXPECTED after it. ---- */
    n = m;
    /* INSTRUMENTATION: vec dumper (ALNREG_VEC_OUT) — capture score-sort INPUT/EXPECTED */
    vec_init_once();
    mem_alnreg_t *g_vec_snap = NULL; int g_vec_do = 0;
    if (g_vec_enabled>0 && n>=2 && n<=g_vec_nmax) {
        vec_lock();
        if (g_vec_seen[n] < g_vec_quota) { g_vec_seen[n]++; g_vec_do = 1; }
        vec_unlock();
        if (g_vec_do) { g_vec_snap=(mem_alnreg_t*)malloc((size_t)n*sizeof(mem_alnreg_t));
                        memcpy(g_vec_snap, a, (size_t)n*sizeof(mem_alnreg_t)); }
    }
    ks_introsort(mem_ars, n, a);
    if (g_vec_do) {
        vec_lock();
        int32_t nn=n; fwrite(&nn,4,1,g_vec_fp);
        for (int vi=0; vi<n; ++vi){ int32_t sc=g_vec_snap[vi].score; int64_t rb=g_vec_snap[vi].rb; int32_t qb=g_vec_snap[vi].qb;
            fwrite(&sc,4,1,g_vec_fp); fwrite(&rb,8,1,g_vec_fp); fwrite(&qb,4,1,g_vec_fp); }
        for (int vi=0; vi<n; ++vi){ int32_t sc=a[vi].score; int64_t rb=a[vi].rb; int32_t qb=a[vi].qb;
            fwrite(&sc,4,1,g_vec_fp); fwrite(&rb,8,1,g_vec_fp); fwrite(&qb,4,1,g_vec_fp); }
        vec_unlock(); free(g_vec_snap);
    }
/* --- end vec dumper -------------------------------------------------------- */
