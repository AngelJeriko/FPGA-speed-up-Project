// matesw_orch_test.cpp — synthetic SANITY test for the mate-rescue orchestration
// model (orch.h). Like chain_test.cpp: checks the pipeline (skip -> window-fed SW
// -> transform -> insert -> dedup) behaves sensibly. Bit-exactness vs real
// bwa-mem2 is established later by check_orch on captured vectors.
#include <cstdio>
#include <vector>
#include "macro.h"
#include "orch.h"

uint64_t tprof[LIM_R][LIM_C];

static uint64_t st = 0xC0FFEEull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main() {
    MOpt o; int64_t l_pac = 2000000000;   // huge -> forward strand, no boundary games
    int fails = 0;

    // ---- Case A: a clean rescue. One non-failed orientation (r=0, fwd), a host-fed
    // window that embeds the mate sequence -> expect one appended alnreg, score~=l_ms.
    {
        int l_ms = 60; std::vector<uint8_t> ms(l_ms);
        for (int i = 0; i < l_ms; ++i) ms[i] = rnd() % 4;
        // ref window = 50 bg + ms + 50 bg
        int pre = 50, suf = 50, rlen = pre + l_ms + suf;
        std::vector<uint8_t> ref(rlen);
        for (int i = 0; i < rlen; ++i) ref[i] = rnd() % 4;
        for (int i = 0; i < l_ms; ++i) ref[pre + i] = ms[i];

        MAln a{}; a.rb = 100000; a.re = 100100; a.qb = 0; a.qe = 100;
        a.rid = 0; a.is_alt = 0; a.score = 100;

        MPes pes[4];
        for (int r = 0; r < 4; ++r) { pes[r].failed = 1; pes[r].low = 0; pes[r].high = 0; }
        pes[0].failed = 0; pes[0].low = 100; pes[0].high = 600;

        MWin win[4];
        for (int r = 0; r < 4; ++r) { win[r].used = 0; win[r].rid = -1; }
        win[0].used = 1; win[0].rb = 100100; win[0].re = 100100 + rlen; win[0].rid = 0;
        win[0].ref = ref;

        std::vector<MAln> ma;            // start with one far-away existing hit
        MAln e{}; e.rb = 500000; e.re = 500100; e.qb = 0; e.qe = 100; e.rid = 0; e.score = 80;
        ma.push_back(e);

        int n = matesw_orchestrate(o, l_pac, a, l_ms, ms.data(), pes, win, ma);
        printf("A: n=%d ma=%zu\n", n, ma.size());
        for (auto& m : ma)
            printf("   rb=%lld re=%lld qb=%d qe=%d score=%d rid=%d seedcov=%d\n",
                   (long long)m.rb, (long long)m.re, m.qb, m.qe, m.score, m.rid, m.seedcov);
        if (n != 1) { printf("   [FAIL] expected gate to pass once\n"); fails++; }
        bool got_rescue = false;
        for (auto& m : ma) if (m.rb >= 100100 && m.rb < 100100 + rlen && m.score >= l_ms - 5) got_rescue = true;
        if (!got_rescue) { printf("   [FAIL] no high-score rescue alnreg near the window\n"); fails++; }
    }

    // ---- Case B: a consistent pair already exists in every needed orientation ->
    // all skip -> no SW, ma unchanged.
    {
        int l_ms = 60; std::vector<uint8_t> ms(l_ms, 0);
        MAln a{}; a.rb = 100000; a.rid = 0;
        MPes pes[4];
        for (int r = 0; r < 4; ++r) { pes[r].failed = 0; pes[r].low = 100; pes[r].high = 600; }
        MWin win[4]; for (int r = 0; r < 4; ++r) { win[r].used = 0; win[r].rid = -1; }
        std::vector<MAln> ma;
        // existing hit at +300 in the right direction marks its orientation skipped;
        // make all four orientations consistent by placing four mates.
        for (int k = 0; k < 4; ++k) { MAln e{}; e.rb = 100000 + 300 + k; e.rid = 0; ma.push_back(e); }
        size_t before = ma.size();
        int n = matesw_orchestrate(o, l_pac, a, l_ms, ms.data(), pes, win, ma);
        printf("B: n=%d ma=%zu (was %zu)\n", n, ma.size(), before);
        if (n != 0 || ma.size() != before) { printf("   [FAIL] expected all-skip no-op\n"); fails++; }
    }

    printf(fails == 0 ? "matesw_orch_test: sanity OK\n" : "matesw_orch_test: %d issue(s)\n", fails);
    return fails ? 1 : 0;
}
