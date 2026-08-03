// dedup_probe.cpp — characterise the DEDUP-EXCLUSION coverage gap (v2 / mate-rescue).
//
// THE GAP (docs/synth_ooc_results.md, session notes): in mem_sort_dedup_patch the
// redundancy de-overlap does, when two hits overlap by > mask_level_redun (0.95):
//     if (p->score < q->score) { p->qe = p->qb; break; }   // EXCLUDE p
//     else                       q->qe = q->qb;             // EXCLUDE q
// Mutating the RTL to DISABLE that exclusion (excl_p=excl_q=0) left tb_msort_dedup at
// 1696/0 — i.e. the exclusion decision is OUTPUT-NEUTRAL on the corpus, so the mutation
// never went red. Same "never observed to change a result" shape as the zdrop gap.
//
// This probe answers, on the REAL captured corpus (alnreg_v2_vectors.bin) AND on random
// data: (1) how often does the redundancy branch FIRE? (2) when it fires, does disabling
// it change the final survivor set? (3) if not — WHY (is the excluded hit removed anyway
// by the downstream identical-(score,rb,qb) pass, i.e. the exclusion is redundant with a
// later stage)?  Then it constructs a DIRECTED case that makes the exclusion decision
// observably change output — the vector that CLOSES the gap (unlike zdrop, dedup exclusion
// is the module's core function and DOES matter on some inputs).
//
// Build:  g++ -O2 -std=c++17 -I. dedup_probe.cpp -o dedup_probe   (run from this dir)

#include <cstdio>
#include <cstdint>
#include <vector>
#include <random>
#include <algorithm>
#include "v2_dedup.h"   // V2Key + the canonical v2_dedup (unmodified, for reference)

// ---- instrumented copy of v2_dedup: same logic, with a fire counter and an
//      EXCL_DISABLE mode (redundant -> do nothing, mirroring the RTL mutation). ----
struct Probe { long redun_fire = 0; long p_excl = 0; long q_excl = 0; };

static int v2_dedup_probe(V2Key* a, int n, bool excl_disable, Probe* pr) {
    int m, i, j;
    if (n <= 1) return n;
    std::stable_sort(a, a + n, v2_re_lt);
    for (i = 1; i < n; ++i) {
        V2Key* p = &a[i];
        if (p->rid != a[i-1].rid || p->rb >= a[i-1].re + V2_MAX_CHAIN_GAP) continue;
        for (j = i - 1; j >= 0 && p->rid == a[j].rid && p->rb < a[j].re + V2_MAX_CHAIN_GAP; --j) {
            V2Key* q = &a[j];
            int64_t or_, oq, mr, mq;
            if (q->qe == q->qb) continue;
            or_ = q->re - p->rb;
            oq = q->qb < p->qb ? q->qe - p->qb : p->qe - q->qb;
            mr = q->re - q->rb < p->re - p->rb ? q->re - q->rb : p->re - p->rb;
            mq = q->qe - q->qb < p->qe - p->qb ? q->qe - q->qb : p->qe - p->qb;
            if (or_ > V2_MASK_LEVEL_REDUN * mr && oq > V2_MASK_LEVEL_REDUN * mq) {
                if (pr) pr->redun_fire++;
                if (!excl_disable) {
                    if (p->score < q->score) { if (pr) pr->p_excl++; p->qe = p->qb; break; }
                    else                     { if (pr) pr->q_excl++; q->qe = q->qb; }
                } else {
                    // DISABLED: mimic the RTL mutation (redundant, but exclude nothing).
                    // still honour the `break` shape only when p would have been excluded?
                    // No — the RTL mutation removes BOTH writes and keeps scanning, so we do
                    // nothing and continue the j-loop, exactly like excl_p=excl_q=0.
                }
            }
        }
    }
    for (i = 0, m = 0; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    n = m;
    std::stable_sort(a, a + n, v2_score_lt);
    for (i = 1; i < n; ++i)
        if (a[i].score==a[i-1].score && a[i].rb==a[i-1].rb && a[i].qb==a[i-1].qb) a[i].qe = a[i].qb;
    for (i = 1, m = 1; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    return m;
}

static bool rd(FILE* f, void* p, size_t n) { return fread(p, 1, n, f) == n; }
static bool rd_key(FILE* f, V2Key& k) {
    return rd(f,&k.rb,8) && rd(f,&k.re,8) && rd(f,&k.qb,4) && rd(f,&k.qe,4)
        && rd(f,&k.rid,4) && rd(f,&k.score,4);
}
static bool out_eq(std::vector<V2Key>& x, std::vector<V2Key>& y) {
    if (x.size() != y.size()) return false;
    for (size_t i = 0; i < x.size(); ++i)
        if (x[i].rb!=y[i].rb||x[i].re!=y[i].re||x[i].qb!=y[i].qb||x[i].qe!=y[i].qe||
            x[i].rid!=y[i].rid||x[i].score!=y[i].score) return false;
    return true;
}

// run one array both ways; return true if the survivor set DIFFERS with exclusion off.
static bool differs(const std::vector<V2Key>& in, Probe* pr) {
    std::vector<V2Key> on = in, off = in;
    int mon  = v2_dedup_probe(on.data(),  (int)on.size(),  false, pr);
    int moff = v2_dedup_probe(off.data(), (int)off.size(), true,  nullptr);
    on.resize(mon); off.resize(moff);
    return !out_eq(on, off);
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "vectors/alnreg_v2_vectors.bin";

    // ---------- (1) REAL captured corpus ----------
    FILE* f = fopen(path, "rb");
    long records=0, arrays_fire=0, arrays_diff=0; Probe pr;
    if (!f) {
        printf("[real corpus] cannot open %s — skipping real-data pass\n", path);
    } else {
        int32_t n, m; uint8_t has_tie;
        long tiefree=0, tie=0, diff_tiefree=0, diff_tie=0;
        while (rd(f,&n,4)) {
            if (!rd(f,&has_tie,1) || !rd(f,&m,4)) break;
            std::vector<V2Key> in(n), exp(m); bool ok=true;
            for (int i=0;i<n;i++) if(!rd_key(f,in[i])){ok=false;break;}
            for (int i=0;i<m&&ok;i++) if(!rd_key(f,exp[i])){ok=false;break;}
            if (!ok) break;
            records++;
            if (has_tie) tie++; else tiefree++;
            Probe local;
            bool d = differs(in, &local);
            if (local.redun_fire) arrays_fire++;
            if (d) { arrays_diff++; if (has_tie) diff_tie++; else diff_tiefree++; }
            pr.redun_fire += local.redun_fire; pr.p_excl += local.p_excl; pr.q_excl += local.q_excl;
        }
        fclose(f);
        printf("[real corpus %s]\n", path);
        printf("  arrays                         : %ld  (tie-free %ld, tie %ld)\n", records, tiefree, tie);
        printf("  redundancy branch FIRED (times): %ld  (in %ld arrays)\n", pr.redun_fire, arrays_fire);
        printf("    -> excluded p (p.score<q)    : %ld\n", pr.p_excl);
        printf("    -> excluded q                : %ld\n", pr.q_excl);
        printf("  arrays whose OUTPUT CHANGES if exclusion disabled: %ld\n", arrays_diff);
        printf("    -> among TIE-FREE (the tb-checked hardware set): %ld  <== the coverage question\n", diff_tiefree);
        printf("    -> among TIE arrays (SW-fallback, tb skips)    : %ld\n", diff_tie);
    }

    // ---------- (2) random corpus (matches gen_dedup_vectors clustering) ----------
    std::mt19937_64 rng(0xC0FFEE);
    long rnd_arrays=2000000, r_fire=0, r_diff=0; Probe rpr;
    for (long it=0; it<rnd_arrays; ++it) {
        int nn = rng()%20;
        std::vector<V2Key> a;
        for (int k=0;k<nn;k++){
            V2Key m{};
            int64_t base=(int64_t)(rng()%3)*2000;
            m.rid=rng()%2; m.rb=base+(int64_t)(rng()%400);
            int len=20+rng()%200; m.re=m.rb+len;
            m.qb=rng()%120; m.qe=m.qb+(20+rng()%150);
            m.score=10+rng()%90;
            if(!a.empty() && (rng()%100)<15) m=a[rng()%a.size()];
            a.push_back(m);
        }
        Probe local; bool d=differs(a,&local);
        if(local.redun_fire) r_fire++;
        if(d) r_diff++;
        rpr.redun_fire+=local.redun_fire; rpr.p_excl+=local.p_excl; rpr.q_excl+=local.q_excl;
    }
    printf("\n[random corpus, %ld arrays, gen_dedup_vectors clustering]\n", rnd_arrays);
    printf("  redundancy branch FIRED (times): %ld  (in %ld arrays)\n", rpr.redun_fire, r_fire);
    printf("    -> excluded p / q            : %ld / %ld\n", rpr.p_excl, rpr.q_excl);
    printf("  arrays whose OUTPUT CHANGES if exclusion disabled: %ld\n", r_diff);

    // ---------- (3) DIRECTED case: exclusion MUST change output ----------
    // Two hits, same rid, heavily overlapping (>0.95 on both ref and query), DIFFERENT
    // scores, and NOT (score,rb,qb)-identical -> the loser is removed ONLY by the
    // redundancy exclusion, not by the downstream identical pass. Disabling exclusion
    // keeps both -> n_out changes 1 vs 2.
    {
        std::vector<V2Key> in = {
            // rb, re, qb, qe, rid, score
            {1000, 1200, 0, 200, 0, 50},   // hit A (higher score) — survivor
            {1001, 1199, 1, 199, 0, 40},   // hit B ~identical span, lower score, distinct (rb,qb)
        };
        std::vector<V2Key> on=in, off=in;
        int mon=v2_dedup_probe(on.data(),2,false,nullptr);
        int moff=v2_dedup_probe(off.data(),2,true,nullptr);
        printf("\n[directed case] two >0.95-overlap hits, distinct score & (rb,qb):\n");
        printf("  n_out with exclusion ON : %d  (redundant loser removed)\n", mon);
        printf("  n_out with exclusion OFF: %d  (loser survives -> WRONG)\n", moff);
        printf("  => exclusion is OBSERVABLE here: %s\n",
               mon!=moff ? "YES (this vector makes the mutation go RED)" : "NO");
    }

    printf("\nVERDICT: see docs/dedup_exclusion_characterization.md\n");
    return 0;
}
