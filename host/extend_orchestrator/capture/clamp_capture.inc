/* ============================================================================
 * clamp_capture.inc  —  PASTE-READY instrumentation for the CONTIG-CLAMP capture
 *                       (Decision C2 / the "4th capture" of genome_fetch_options.md).
 *
 * Goal: validate the contig-clamp C++ model (host/extend_orchestrator/bns_clamp.h)
 * bit-exact vs real bwa-mem2. bns_fetch_seq_v2 clamps rmax[0..1] to the contig that
 * seeds[0].rbeg lands in (flipping to reverse-strand space when is_rev) and derives
 * rid. Our accelerator does NOT model this today (the host does it); C2 pulls it on
 * chip, so we capture the real inputs->outputs of that one call.
 *
 * ONE self-contained record type (single call site), captured AROUND the
 * bns_fetch_seq_v2 call in mem_chain2aln_across_reads_V2 (bwamem.cpp:~2172). The
 * call MUTATES rmax[0]/rmax[1] in place, so beg/end are snapshotted BEFORE and read
 * AFTER. The returned reference bytes are captured too, so the SAME vectors can later
 * validate the A1 byte-fetch (seq = ref_string + beg) without re-instrumenting.
 *
 * TARGET FILE: src/bwamem.cpp. Env-gated (ALNREG_CLAMP_OUT); ALNREG_CLAMP_MAX caps
 * the number of records. The validator loads the contig table from the .ann directly
 * (host/extend_orchestrator/bns_clamp.h::bns_load_ann), so the table is not dumped.
 *
 * Record format (binary, native little-endian), one per bns_fetch_seq_v2 call:
 *   i32 type=0; i64 call_id; i64 l_pac;
 *   i64 beg_in;  i64 mid;   i64 end_in;      // inputs  (rmax0, seeds[0].rbeg, rmax1)
 *   i64 beg_out; i64 end_out; i32 rid;       // outputs (clamped rmax0, rmax1, rid)
 *   i32 nbytes;  u8 bytes[nbytes]            // returned window (nbytes == end_out-beg_out)
 * ============================================================================
 *
 * --- STEP 1: paste this INFRA block at file scope, just BEFORE the definition of
 *     mem_chain2aln_across_reads_V2 (bwamem.cpp:~2069). ---
 */
/* --- INSTRUMENTATION (temporary): contig-clamp (bns_fetch_seq_v2) capture ------ */
static FILE *g_clp_fp=NULL; static int g_clp_enabled=-1;
static long  g_clp_n=0, g_clp_max=400000;
static volatile int g_clp_lock=0;
static inline void clp_lock(void){ while(__sync_lock_test_and_set(&g_clp_lock,1)){} }
static inline void clp_unlock(void){ __sync_lock_release(&g_clp_lock); }
static void clp_init_once(void){
    if (g_clp_enabled>=0) return;
    clp_lock();
    if (g_clp_enabled<0){
        const char*p=getenv("ALNREG_CLAMP_OUT");
        if(p){ g_clp_fp=fopen(p,"wb"); g_clp_enabled=g_clp_fp?1:0; } else g_clp_enabled=0;
        const char*m=getenv("ALNREG_CLAMP_MAX"); if(m){ long v=atol(m); if(v>0) g_clp_max=v; }
    }
    clp_unlock();
}
struct ClpDumper{ ~ClpDumper(){ if(g_clp_fp) fclose(g_clp_fp); } };
static ClpDumper g_clp_dumper;
/* --- end instrumentation infra --------------------------------------------- */


/*
 * --- STEP 2: HOOK — wrap the bns_fetch_seq_v2 call (bwamem.cpp:~2172). The existing
 *     block is:
 *         {
 *             int rid = 0;
 *             // free rseq
 *             rseq = bns_fetch_seq_v2(bns, pac, &rmax[0],
 *                                     c->seeds[0].rbeg,
 *                                     &rmax[1], &rid, ref_string,
 *                                     (uint8_t*) seqPairArrayAux);
 *             assert(c->rid == rid);
 *         }
 *     Snapshot beg_in/mid/end_in BEFORE the call (it mutates rmax in place); write the
 *     full record AFTER the assert (rseq/beg_out/end_out/rid all valid).
 *     `bns`, `l_pac`, `c`, `rmax`, `rseq` are all in scope here.
 */
/* INSTRUMENTATION: clamp capture — snapshot inputs BEFORE the call */
int64_t clp_beg_in = rmax[0], clp_mid = c->seeds[0].rbeg, clp_end_in = rmax[1];
/* (the bns_fetch_seq_v2(...) call and its assert stay exactly as-is between these two) */
/* INSTRUMENTATION: clamp capture — write record AFTER the call */
{
    clp_init_once();
    if (g_clp_enabled>0) {
        clp_lock();
        if (g_clp_n < g_clp_max) {
            g_clp_n++;
            int32_t type=0, rid32=rid, nbytes=(int32_t)(rmax[1]-rmax[0]);
            int64_t cid=g_clp_n-1, lpac=l_pac;
            int64_t beg_out=rmax[0], end_out=rmax[1];
            fwrite(&type,4,1,g_clp_fp);      fwrite(&cid,8,1,g_clp_fp);
            fwrite(&lpac,8,1,g_clp_fp);
            fwrite(&clp_beg_in,8,1,g_clp_fp);fwrite(&clp_mid,8,1,g_clp_fp);
            fwrite(&clp_end_in,8,1,g_clp_fp);
            fwrite(&beg_out,8,1,g_clp_fp);   fwrite(&end_out,8,1,g_clp_fp);
            fwrite(&rid32,4,1,g_clp_fp);     fwrite(&nbytes,4,1,g_clp_fp);
            if (nbytes>0 && rseq) fwrite(rseq,1,(size_t)nbytes,g_clp_fp);
        }
        clp_unlock();
    }
}
/* --- end HOOK -------------------------------------------------------------- */
