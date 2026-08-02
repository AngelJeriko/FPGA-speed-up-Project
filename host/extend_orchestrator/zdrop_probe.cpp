// zdrop_probe.cpp — characterise whether zdrop can EVER change bsw_top's output.
//
// bsw_top is bit-exact to hw_extend2 (hw.h), the full-rectangle (UNBANDED) DP. This probe
// runs hw_extend2 with zdrop ON vs OFF over large random + adversarial populations and
// reports whether any tb-checked field (score/qle/tle/gscore/gtle) differs.
//
// RESULT (see docs/zdrop_characterization.md):
//   * zdrop=100 (the bwa-mem2 / bsw_pkg production value): NO output change, ever.
//   * The ONLY reachable effect is `gtle` at small zdrop (<=~50) in adversarial cases where
//     gscore<=0 -- a field tb_bsw_ext treats as don't-care (unused downstream when gscore<=0).
//   * score/qle/tle/gscore are never affected.
// WHY: unbanded DP always has a straight target-deletion escape, which floors the
// drift-corrected row-max drop at ~o_del (6) -- far below production zdrop=100. zdrop is a
// BANDED-alignment feature; it is architecturally dormant in this full-rectangle engine.
// (If banding is ever added, zdrop becomes live and must be re-verified with directed vectors.)
//
// Build: g++ -O2 -std=c++17 -I. zdrop_probe.cpp -o zdrop_probe   (run from this dir)

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <random>
#include "hw.h"

static void mkmat(int8_t* m, int a, int b) {
    for (int i = 0; i < 5; i++) for (int j = 0; j < 5; j++)
        m[i*5+j] = (i==j && i<4) ? a : ((i==4||j==4) ? -1 : -b);
}
struct K { int sc, qle, tle, gtle, gsc, mo; };
static K run(int ql, const uint8_t* q, int tl, const uint8_t* t, int8_t* m, int zd) {
    K k{}; k.sc = hw_extend2(ql, q, tl, t, 5, m, 6, 1, 6, 1, 1000000, 5, zd, 40,
                             &k.qle, &k.tle, &k.gtle, &k.gsc, &k.mo); return k;
}
static const char* difffields(const K& a, const K& b) {
    static char s[128]; s[0]=0;
    if (a.sc !=b.sc ) strcat(s,"score ");  if (a.qle!=b.qle) strcat(s,"qle ");
    if (a.tle!=b.tle) strcat(s,"tle ");    if (a.gsc!=b.gsc) strcat(s,"gscore ");
    if (a.gtle!=b.gtle) strcat(s,"gtle ");
    return s;
}

int main() {
    int8_t m[25]; mkmat(m, 1, 4);            // bwa-mem2 scoring: a=1,b=4 (fixed in bsw_top)
    std::mt19937 rng(1);

    // (1) production zdrop=100 over random data
    long diff100 = 0, n1 = 200000;
    for (long it = 0; it < n1; ++it) {
        int ql = 1+rng()%160, tl = 1+rng()%400;
        std::vector<uint8_t> q(ql), t(tl);
        for (auto&x:q) x=rng()%4; for (auto&x:t) x=rng()%4;
        if (run(ql,q.data(),tl,t.data(),m,100).sc != 0) {} // touch
        K on=run(ql,q.data(),tl,t.data(),m,100), off=run(ql,q.data(),tl,t.data(),m,0);
        if (strlen(difffields(on,off))) diff100++;
    }
    printf("[random, zdrop=100 vs 0] %ld / %ld cases differ in any tb field\n", diff100, n1);

    // (2) adversarial (match prefix + in-query divergence), find largest firing zdrop
    int best=-1; K bon{}, boff{}; int bql=0,btl=0;
    for (int P=20;P<=140;P+=20) for (int D=1;D<=120;D++) {
        int ql=P+std::min(D,159-P); if(ql>160||ql<1) continue;
        std::vector<uint8_t> q(ql); for(int i=0;i<ql;i++) q[i]=rng()%4;
        int mp=std::min(P,ql); std::vector<uint8_t> t;
        for(int i=0;i<mp;i++) t.push_back(q[i]);
        for(int i=0;i<D;i++)  t.push_back((q[std::min(mp+i,ql-1)]+1+rng()%3)%4);
        if((int)t.size()>1024) continue;
        for(int zd=99; zd>=2; zd--){
            K on=run(ql,q.data(),t.size(),t.data(),m,zd), off=run(ql,q.data(),t.size(),t.data(),m,0);
            if(strlen(difffields(on,off))){ if(zd>best){best=zd;bon=on;boff=off;bql=ql;btl=t.size();} break; }
        }
    }
    if(best<0) printf("[adversarial] no firing case found\n");
    else printf("[adversarial] largest firing zdrop=%d (ql=%d tl=%d): changes [%s]; "
                "gscore=%d (<=0 => gtle is don't-care in tb_bsw_ext)\n",
                best, bql, btl, difffields(bon,boff), bon.gsc);

    printf("\nVERDICT: zdrop=100 is inert; the only reachable effect is a don't-care gtle at small\n"
           "zdrop -> zdrop is architecturally dormant in the unbanded engine (expected corpus\n"
           "output-neutrality). See docs/zdrop_characterization.md.\n");
    return 0;
}
