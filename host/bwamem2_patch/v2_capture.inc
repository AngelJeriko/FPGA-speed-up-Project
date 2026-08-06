/* ============================================================================
 * v2_capture.inc — PASTE-READY instrumentation for the MERGE-SORTER v2 dedup vector
 *   dumper (instrument #4 of docs/bwamem2_instrumentation.md; env ALNREG_V2_OUT).
 *   Produces the golden that verifies host/merge_sorter/v2_dedup.h + rtl/msort_v2_* (tb_msort_v2).
 *
 *   ✅ VALIDATED (2026-08-06) — applied to bwa-mem2 @ commit 97978f9, built, and a
 *   fresh capture (50k HG00733 pairs) replayed through host/merge_sorter/test_v2 gave
 *   **tie-free 5872/5872 bit-exact, 0 fail** (tie arrays reported separately: 1933,
 *   of which 75 diverge — the expected ~5% software-fallback set). "ALL PASS".
 *
 *   Captures, per call to mem_sort_dedup_patch: the PRE-dedup INPUT array, a has_tie
 *   flag (1 iff the array contains ≥1 equal-`re` element — where ks_introsort is
 *   unstable, so the stable HW sort may diverge → software fallback), and the real
 *   post-function OUTPUT. Per-size quota 32 (ALNREG_V2_QUOTA), n in [2,1060]
 *   (ALNREG_V2_NMAX). Env-gated (ALNREG_V2_OUT).
 *
 *   TARGET FILE: src/bwamem.cpp, function mem_sort_dedup_patch (@ :292). Byte format
 *   matches host/merge_sorter/test_v2.cpp:
 *     record = i32 n; u8 has_tie; i32 m; n*V2Key INPUT; m*V2Key OUTPUT
 *     V2Key  = i64 rb; i64 re; i32 qb; i32 qe; i32 rid; i32 score
 *
 *   RE-VALIDATE: ALNREG_V2_OUT=v2.bin ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null
 *     ( cd host/merge_sorter && make test_v2 && ./test_v2 /path/v2.bin )  -> "ALL PASS (tie-free bit-exact)"
 * ============================================================================
 *
 * --- STEP 1: INFRA — paste at file scope (e.g. right after `#include "kbtree.h"`). */
/* --- INSTRUMENTATION (temporary): v2 dedup vector dumper -------------------- */
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <algorithm>
struct V2KeyRec { int64_t rb, re; int32_t qb, qe, rid, score; };
static FILE *g_v2_fp=NULL; static int g_v2_enabled=-1;
static int g_v2_nmax=1060, g_v2_quota=32; static int *g_v2_seen=NULL;
static volatile int g_v2_lock=0;
static inline void v2_lock(void){ while(__sync_lock_test_and_set(&g_v2_lock,1)){} }
static inline void v2_unlock(void){ __sync_lock_release(&g_v2_lock); }
static void v2_init_once(void){
    if (g_v2_enabled>=0) return;
    v2_lock();
    if (g_v2_enabled<0){
        const char*p=getenv("ALNREG_V2_OUT");
        if(p){ g_v2_fp=fopen(p,"wb"); g_v2_enabled=g_v2_fp?1:0; } else g_v2_enabled=0;
        const char*q=getenv("ALNREG_V2_QUOTA"); if(q){int v=atoi(q);if(v>0)g_v2_quota=v;}
        const char*x=getenv("ALNREG_V2_NMAX");  if(x){int v=atoi(x);if(v>0)g_v2_nmax=v;}
        if(g_v2_enabled>0) g_v2_seen=(int*)calloc((size_t)g_v2_nmax+1,sizeof(int));
    }
    v2_unlock();
}
struct V2Dumper{ ~V2Dumper(){ if(g_v2_fp) fclose(g_v2_fp); } };
static V2Dumper g_v2_dumper;
static inline void v2_wkey(const mem_alnreg_t*r){ int64_t rb=r->rb,re=r->re; int32_t qb=r->qb,qe=r->qe,rid=r->rid,sc=r->score;
    fwrite(&rb,8,1,g_v2_fp);fwrite(&re,8,1,g_v2_fp);fwrite(&qb,4,1,g_v2_fp);fwrite(&qe,4,1,g_v2_fp);fwrite(&rid,4,1,g_v2_fp);fwrite(&sc,4,1,g_v2_fp);}
/* --- end instrumentation infra --------------------------------------------- */

/* --- STEP 2: HOOK-A — in mem_sort_dedup_patch, immediately AFTER `if (n <= 1)
 *     return n;` (@ :297) and BEFORE `ks_introsort(mem_ars2, n, a);` (@ :298), so
 *     INPUT is the raw pre-dedup array. Declares g_v2_* used by HOOK-B. ---------- */
    V2KeyRec *g_v2_in=NULL; int g_v2_do=0, g_v2_n_in=n; unsigned char g_v2_has_tie=0;
    v2_init_once();
    if (g_v2_enabled>0 && n>=2 && n<=g_v2_nmax) {
        v2_lock();
        if (g_v2_seen[n] < g_v2_quota) { g_v2_seen[n]++; g_v2_do=1; }
        v2_unlock();
        if (g_v2_do) {
            g_v2_in=(V2KeyRec*)malloc((size_t)n*sizeof(V2KeyRec));
            std::vector<int64_t> v2re((size_t)n);
            for (int vi=0; vi<n; ++vi){ g_v2_in[vi].rb=a[vi].rb; g_v2_in[vi].re=a[vi].re;
                g_v2_in[vi].qb=a[vi].qb; g_v2_in[vi].qe=a[vi].qe; g_v2_in[vi].rid=a[vi].rid; g_v2_in[vi].score=a[vi].score;
                v2re[vi]=a[vi].re; }
            std::sort(v2re.begin(), v2re.end());
            for (int vi=1; vi<n; ++vi) if (v2re[vi]==v2re[vi-1]) { g_v2_has_tie=1; break; }
        }
    }
/* --- end HOOK-A ------------------------------------------------------------ */

/* --- STEP 3: HOOK-B — immediately BEFORE the function's final `return m;` (@ :352),
 *     where a[0..m-1] is the finished OUTPUT. --------------------------------- */
    if (g_v2_do) {
        v2_lock();
        int32_t nn=g_v2_n_in, mm=m; unsigned char ht=g_v2_has_tie;
        fwrite(&nn,4,1,g_v2_fp); fwrite(&ht,1,1,g_v2_fp); fwrite(&mm,4,1,g_v2_fp);
        for (int vi=0; vi<nn; ++vi){ V2KeyRec*k=&g_v2_in[vi];
            fwrite(&k->rb,8,1,g_v2_fp);fwrite(&k->re,8,1,g_v2_fp);fwrite(&k->qb,4,1,g_v2_fp);fwrite(&k->qe,4,1,g_v2_fp);fwrite(&k->rid,4,1,g_v2_fp);fwrite(&k->score,4,1,g_v2_fp); }
        for (int vi=0; vi<mm; ++vi) v2_wkey(&a[vi]);
        v2_unlock(); free(g_v2_in);
    }
/* --- end HOOK-B ------------------------------------------------------------ */
