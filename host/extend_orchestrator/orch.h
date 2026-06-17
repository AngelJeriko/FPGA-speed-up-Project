// orch.h — software model of mem_chain2aln_across_reads_V2 (the extension
// orchestration between seeding and the merge-sorter). Replays the captured
// per-read inputs through: seed score-sort -> left/right ksw_extend2 (band
// doubling, MAX_BAND_TRY=2) -> alnreg assembly (pen_clip global/local) ->
// seedcov containment -> cross-chain redundancy purge. Output (per-read alnreg
// array, in append order) is checked bit-exact vs the captured type-2 output.
//
// Faithful to bwamem.cpp; constants: H0_ = -99, MAX_BAND_TRY = 2, m = 5.
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>
#include "ksw.h"

static const int H0M = -99;
static const int MAX_BAND_TRY = 2;

struct Cfg {
    int a, b, o_del, e_del, o_ins, e_ins, w, zdrop, pen_clip5, pen_clip3;
    int8_t mat[25];
};
struct Seed   { int64_t rbeg; int qbeg, len, score; };
struct Chain  { int chain_idx, rid; int64_t rmax0, rmax1;
                std::vector<Seed> seeds; std::vector<uint8_t> ref; };
struct Alnreg { int64_t rb, re; int qb, qe, score, truesc, w, seedcov, seedlen0, rid; };
struct ReadVec{ int64_t read_id; int l_query; Cfg cfg;
                std::vector<uint8_t> query; std::vector<Chain> chains;
                std::vector<Alnreg> out; bool has_hdr=false, has_out=false; };

struct ExtRes { int score, qle, tle, gscore, gtle, w; };

// per-alnreg trace for unit-testing the assembly datapath in RTL: the SW results
// (left/right) + seed/cfg inputs and the expected assembled fields (excl. seedcov,
// which depends on the chain seed list and is tested separately).
struct AsmVec {
    int l_query, a, w, pen_clip5, pen_clip3;
    int64_t rbeg, rmax0; int qbeg, len, rid;
    int need_left, need_right;
    ExtRes left, right;
    int64_t rb, re; int qb, qe, score, truesc, wout, seedcov;
};

// band-doubling extension: ksw at w<<i for i in [0,MAX_BAND_TRY), accept on the
// same condition bwamem.cpp uses (score unchanged / max_off small / last try).
static inline ExtRes band_extend(int qlen, const uint8_t *q, int tlen,
        const uint8_t *t, const Cfg &o, int end_bonus, int h0, int prev) {
    ExtRes r{};
    for (int i = 0; i < MAX_BAND_TRY; ++i) {
        int w = o.w << i, qle, tle, gtle, gscore, maxoff;
        int sc = ksw_extend2(qlen, q, tlen, t, 5, o.mat, o.o_del, o.e_del,
                             o.o_ins, o.e_ins, w, end_bonus, o.zdrop, h0,
                             &qle, &tle, &gtle, &gscore, &maxoff);
        if (sc == prev || maxoff < (w >> 1) + (w >> 2) || i + 1 == MAX_BAND_TRY) {
            r = {sc, qle, tle, gscore, gtle, w};
            return r;
        }
        prev = sc;
    }
    return r;
}

static inline int seedcov_calc(const Chain &c, const Alnreg &A) {
    int sc = 0;
    for (const Seed &t : c.seeds)
        if (t.qbeg >= A.qb && t.qbeg + t.len <= A.qe &&
            t.rbeg >= A.rb && t.rbeg + t.len <= A.re)
            sc += t.len;
    return sc;
}

// ---- extension only (pre-purge): seed sort -> left/right SW -> assembly ----
// Returns the raw alnreg array in append order and fills seed_aln[chain][seed] =
// av index. This is exactly what the RTL orchestrator produces (the cross-chain
// purge is host-side); the post-purge orchestrate() wraps this + purge().
static inline std::vector<Alnreg> extend_only(
        const ReadVec &rv, std::vector<std::vector<int>> &seed_aln,
        std::vector<AsmVec> *trace = nullptr) {
    const Cfg &o = rv.cfg;
    const int l_query = rv.l_query;
    std::vector<Alnreg> av;
    seed_aln.assign(rv.chains.size(), {});

    for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
        const Chain &c = rv.chains[cj];
        const int n = (int)c.seeds.size();
        seed_aln[cj].assign(n, -1);
        std::vector<uint64_t> srt(n);
        for (int i = 0; i < n; ++i)
            srt[i] = ((uint64_t)(uint32_t)c.seeds[i].score << 32) | (uint32_t)i;
        std::sort(srt.begin(), srt.end());

        for (int k = n - 1; k >= 0; --k) {
            const int si = (int)(srt[k] & 0xffffffffu);
            const Seed &s = c.seeds[si];
            Alnreg A; memset(&A, 0, sizeof(A));
            A.w = o.w; A.score = A.truesc = -1; A.rid = c.rid; A.seedlen0 = s.len;
            A.rb = A.qb = A.re = A.qe = H0M;
            ExtRes Lr{}, Rr{};

            // --- phase 1: set up both sides (matches the per-read loop) ---
            bool need_left = false, need_right = false; int h0L = 0;
            if (s.qbeg) { A.qb = s.qbeg; A.rb = s.rbeg; need_left = true; h0L = s.len * o.a; }
            else        { A.score = A.truesc = s.len * o.a; A.qb = 0; A.rb = s.rbeg; }
            const int   qe0 = s.qbeg + s.len;
            const int64_t re0 = s.rbeg + s.len - c.rmax0;
            if (qe0 != l_query) { A.qe = qe0; A.re = c.rmax0 + re0; need_right = true; }
            else {
                A.qe = l_query; A.re = s.rbeg + s.len;
                // no right extension: bwamem computes seedcov here (rb/qb already set)
                if (A.rb != H0M && A.qb != H0M) A.seedcov = seedcov_calc(c, A);
            }

            // --- phase 2: left extension ---
            if (need_left) {
                const int64_t tmp = s.rbeg - c.rmax0;
                std::vector<uint8_t> qs(s.qbeg), rs(tmp > 0 ? tmp : 0);
                for (int i = 0; i < s.qbeg; ++i) qs[i] = rv.query[s.qbeg - 1 - i];
                for (int64_t i = 0; i < tmp; ++i) rs[i] = c.ref[tmp - 1 - i];
                ExtRes r = band_extend(s.qbeg, qs.data(), (int)tmp, rs.data(),
                                       o, o.pen_clip5, h0L, A.score);
                Lr = r;
                A.score = r.score;
                if (r.gscore <= 0 || r.gscore <= A.score - o.pen_clip5) {
                    A.qb -= r.qle; A.rb -= r.tle; A.truesc = A.score;
                } else { A.qb = 0; A.rb -= r.gtle; A.truesc = r.gscore; }
                if (A.w < r.w) A.w = r.w;
                if (A.rb != H0M && A.qb != H0M && A.qe != H0M && A.re != H0M)
                    A.seedcov = seedcov_calc(c, A);
            }
            // --- phase 3: right extension ---
            if (need_right) {
                const int len2 = l_query - qe0;
                const int64_t len1 = c.rmax1 - c.rmax0 - re0;
                std::vector<uint8_t> qs(len2), rs(len1 > 0 ? len1 : 0);
                for (int i = 0; i < len2; ++i) qs[i] = rv.query[qe0 + i];
                for (int64_t i = 0; i < len1; ++i) rs[i] = c.ref[re0 + i];
                const int h0R = A.score;
                ExtRes r = band_extend(len2, qs.data(), (int)len1, rs.data(),
                                       o, o.pen_clip3, h0R, A.score);
                Rr = r;
                A.score = r.score;
                if (r.gscore <= 0 || r.gscore <= A.score - o.pen_clip3) {
                    A.qe += r.qle; A.re += r.tle; A.truesc += A.score - h0R;
                } else { A.qe = l_query; A.re += r.gtle; A.truesc += r.gscore - h0R; }
                if (A.w < r.w) A.w = r.w;
                if (A.rb != H0M && A.qb != H0M && A.qe != H0M && A.re != H0M)
                    A.seedcov = seedcov_calc(c, A);
            }

            if (trace) {
                AsmVec t{};
                t.l_query=l_query; t.a=o.a; t.w=o.w;
                t.pen_clip5=o.pen_clip5; t.pen_clip3=o.pen_clip3;
                t.rbeg=s.rbeg; t.rmax0=c.rmax0; t.qbeg=s.qbeg; t.len=s.len; t.rid=c.rid;
                t.need_left=need_left; t.need_right=need_right; t.left=Lr; t.right=Rr;
                t.rb=A.rb; t.re=A.re; t.qb=A.qb; t.qe=A.qe;
                t.score=A.score; t.truesc=A.truesc; t.wout=A.w; t.seedcov=A.seedcov;
                trace->push_back(t);
            }
            av.push_back(A);
            seed_aln[cj][si] = (int)av.size() - 1;
        }
    }
    return av;
}

// ---- cross-chain redundancy purge (host-side): sets qb=qe=-1 on contained ----
// seeds whose extension is redundant with an existing alnreg. Mirrors the
// "discard seeds" loop at the end of mem_chain2aln_across_reads_V2. Operates
// in place on the pre-purge av from extend_only().
static inline void purge(const ReadVec &rv, std::vector<Alnreg> &av,
                         const std::vector<std::vector<int>> &seed_aln) {
    const Cfg &o = rv.cfg;
    const int l_query = rv.l_query;
    // recompute the per-chain seed sort order (same as extend_only)
    std::vector<std::vector<uint32_t>> srt2(rv.chains.size());
    for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
        const int n = (int)rv.chains[cj].seeds.size();
        std::vector<uint64_t> srt(n);
        for (int i = 0; i < n; ++i)
            srt[i] = ((uint64_t)(uint32_t)rv.chains[cj].seeds[i].score << 32) | (uint32_t)i;
        std::sort(srt.begin(), srt.end());
        srt2[cj].resize(n);
        for (int i = 0; i < n; ++i) srt2[cj][i] = (uint32_t)(srt[i] & 0xffffffffu);
    }

    int lim = 0;
    for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
        const Chain &c = rv.chains[cj];
        const int n = (int)c.seeds.size();
        for (int k = n - 1; k >= 0; --k) {
            const Seed &s = c.seeds[srt2[cj][k]];
            int v = 0;
            for (int i = 0; i < (int)av.size() && v < lim; ++i) {
                const Alnreg &p = av[i];
                if (p.qb == -1 && p.qe == -1) continue;
                if (s.rbeg < p.rb || s.rbeg + s.len > p.re ||
                    s.qbeg < p.qb || s.qbeg + s.len > p.qe) { v++; continue; }
                if (s.len - p.seedlen0 > 0.1 * l_query) { v++; continue; }
                int64_t rd; int qd, w, max_gap;
                qd = s.qbeg - p.qb; rd = s.rbeg - p.rb;
                max_gap = cal_max_gap(o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.w,
                                      (int)(qd < rd ? qd : rd));
                w = max_gap < p.w ? max_gap : p.w;
                if (qd - rd < w && rd - qd < w) break;
                qd = (int)(p.qe - (s.qbeg + s.len)); rd = p.re - (s.rbeg + s.len);
                max_gap = cal_max_gap(o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.w,
                                      (int)(qd < rd ? qd : rd));
                w = max_gap < p.w ? max_gap : p.w;
                if (qd - rd < w && rd - qd < w) break;
                v++;
            }
            if (v < lim) {
                int vv;
                for (vv = k + 1; vv < n; ++vv) {
                    if (srt2[cj][vv] == 0xffffffffu) continue;
                    const Seed &t = c.seeds[srt2[cj][vv]];
                    if (t.len < s.len * 0.95) continue;
                    if (s.qbeg <= t.qbeg && s.qbeg + s.len - t.qbeg >= s.len >> 2 &&
                        t.qbeg - s.qbeg != t.rbeg - s.rbeg) break;
                    if (t.qbeg <= s.qbeg && t.qbeg + t.len - s.qbeg >= s.len >> 2 &&
                        s.qbeg - t.qbeg != s.rbeg - t.rbeg) break;
                }
                if (vv == n) {
                    int aidx = seed_aln[cj][srt2[cj][k]];
                    av[aidx].qb = av[aidx].qe = -1;
                    srt2[cj][k] = 0xffffffffu;
                    continue;
                }
            }
            lim++;
        }
    }
}

// ---- full orchestration (extend + host-side purge) = bit-exact vs capture ----
static inline std::vector<Alnreg> orchestrate(const ReadVec &rv) {
    std::vector<std::vector<int>> seed_aln;
    std::vector<Alnreg> av = extend_only(rv, seed_aln);
    purge(rv, av, seed_aln);
    return av;
}
