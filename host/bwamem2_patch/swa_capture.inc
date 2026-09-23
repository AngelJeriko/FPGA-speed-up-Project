/* ------------------------------------------------------------------------
 * swa_capture.inc -- golden I/O capture for the banded Smith-Waterman
 *                    extension kernel in bwa-mem2.
 *
 * WHY THIS FILE EXISTS (read before hooking ksw_extend):
 *
 *   The milestone wording is "dump the ksw_extend inputs/outputs".  In
 *   bwa-mem2, ksw_extend()/ksw_extend2() (src/ksw.cpp:432 and its lone
 *   wrapper at :537) are DEAD CODE -- nothing outside src/ksw* calls them.
 *   Hooking there produces an empty file.
 *
 *   The extension that actually runs is BandedPairWiseSW, driven in
 *   batches over SeqPair arrays from mem_chain2aln (src/bwamem.cpp).  Its
 *   scalar reference implementation, BandedPairWiseSW::scalarBandedSWA, has
 *   exactly ksw_extend2's signature and semantics:
 *
 *     score = scalarBandedSWA(qlen=len2, query, tlen=len1, target,
 *                             w, h0, &qle,&tle,&gtle,&gscore,&max_off)
 *
 *   so a SeqPair IS one ksw_extend call: len2/len1/h0 + the two sequence
 *   slices are the inputs, and score/qle/tle/gtle/gscore/max_off are the
 *   six outputs.  We capture at that level, which also covers the SIMD
 *   routes (getScores8 / getScores16), since they must agree bit-for-bit
 *   with the scalar reference.
 *
 * ACTIVATION
 *   Set BSW_CAPTURE_OUT=<path> in the environment.  Unset => no capture and
 *   no behavioural change.  Run bwa-mem2 with -t 1 for a deterministic,
 *   reproducible record order (the hook is mutex-guarded either way).
 *
 * FILE FORMAT  (little-endian, packed, no padding)
 *
 *   header, once:
 *     char   magic[8]      "BSWCAP01"
 *     int32  m             alphabet size (5)
 *     int8   mat[25]       substitution matrix
 *     int32  a, b          match / mismatch
 *     int32  o_del, e_del, o_ins, e_ins
 *     int32  zdrop
 *     int32  pen_clip5     == end_bonus for side 'L'
 *     int32  pen_clip3     == end_bonus for side 'R'
 *     int32  w_base        opt->w (band before the MAX_BAND_TRY widening)
 *
 *   then one record per SeqPair per band-try iteration:
 *     uint8  side          'L' (5' extension) or 'R' (3' extension)
 *     uint8  route         'S' scalar batch, '1' 16-bit SIMD, '8' 8-bit SIMD
 *     int16  band_try      MAX_BAND_TRY iteration index (0-based)
 *     int32  w             effective band for this call (opt->w << band_try)
 *     int32  qlen          == SeqPair.len2
 *     int32  tlen          == SeqPair.len1
 *     int32  h0
 *     int32  score, qle, tle, gtle, gscore, max_off      <- the six outputs
 *     uint8  query[qlen]   2-bit-coded bases, values 0..4
 *     uint8  target[tlen]
 *
 * INSERTION (see apply_swa_capture.sh, which does this mechanically):
 *   1. #include "swa_capture.inc" after the include block of src/bwamem.cpp
 *   2. one bswcap_batch(...) call immediately after each of the six
 *      extension batches in mem_chain2aln, before the tprof accounting.
 * --------------------------------------------------------------------- */

#include <pthread.h>

static FILE            *g_bswcap_fp   = NULL;
static int              g_bswcap_init = 0;
static uint64_t         g_bswcap_n    = 0;
static pthread_mutex_t  g_bswcap_mtx  = PTHREAD_MUTEX_INITIALIZER;

static void bswcap_close(void)
{
    if (g_bswcap_fp) {
        fclose(g_bswcap_fp);
        g_bswcap_fp = NULL;
        fprintf(stderr, "[bswcap] wrote %llu extension records\n",
                (unsigned long long)g_bswcap_n);
    }
}

/* caller holds g_bswcap_mtx */
static void bswcap_open(const mem_opt_t *opt)
{
    const char *path = getenv("BSW_CAPTURE_OUT");
    g_bswcap_init = 1;
    if (!path || !*path) return;

    g_bswcap_fp = fopen(path, "wb");
    if (!g_bswcap_fp) {
        fprintf(stderr, "[bswcap] cannot open '%s' for writing\n", path);
        return;
    }

    int32_t v;
    fwrite("BSWCAP01", 1, 8, g_bswcap_fp);
    v = 5;              fwrite(&v, 4, 1, g_bswcap_fp);
    fwrite(opt->mat, 1, 25, g_bswcap_fp);
    v = opt->a;         fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->b;         fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->o_del;     fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->e_del;     fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->o_ins;     fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->e_ins;     fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->zdrop;     fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->pen_clip5; fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->pen_clip3; fwrite(&v, 4, 1, g_bswcap_fp);
    v = opt->w;         fwrite(&v, 4, 1, g_bswcap_fp);

    atexit(bswcap_close);
    fprintf(stderr, "[bswcap] capturing extension I/O to '%s'\n", path);
}

static void bswcap_batch(const mem_opt_t *opt, SeqPair *pair_ar, int nump,
                         const uint8_t *seqBufRef, const uint8_t *seqBufQer,
                         int32_t w, int band_try, char side, char route)
{
    pthread_mutex_lock(&g_bswcap_mtx);

    if (!g_bswcap_init) bswcap_open(opt);
    if (!g_bswcap_fp || nump <= 0) { pthread_mutex_unlock(&g_bswcap_mtx); return; }

    for (int l = 0; l < nump; l++) {
        const SeqPair *sp = &pair_ar[l];
        /* mirrors scalarBandedSWAWrapper: ref->target(len1), qer->query(len2) */
        const uint8_t *target = seqBufRef + sp->idr;
        const uint8_t *query  = seqBufQer + sp->idq;
        uint8_t u8; int16_t i16; int32_t v;

        u8  = (uint8_t)side;      fwrite(&u8,  1, 1, g_bswcap_fp);
        u8  = (uint8_t)route;     fwrite(&u8,  1, 1, g_bswcap_fp);
        i16 = (int16_t)band_try;  fwrite(&i16, 2, 1, g_bswcap_fp);
        v = w;            fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->len2;     fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->len1;     fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->h0;       fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->score;    fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->qle;      fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->tle;      fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->gtle;     fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->gscore;   fwrite(&v, 4, 1, g_bswcap_fp);
        v = sp->max_off;  fwrite(&v, 4, 1, g_bswcap_fp);
        fwrite(query,  1, (size_t)sp->len2, g_bswcap_fp);
        fwrite(target, 1, (size_t)sp->len1, g_bswcap_fp);
        g_bswcap_n++;
    }

    pthread_mutex_unlock(&g_bswcap_mtx);
}
