// check_truedp.cpp — characterize WHY bsw_top (full-rectangle systolic array)
// diverges from ksw_extend2. Compares, over the same subset as gen_ext_vectors,
// ksw@w=100 (the model that matches real bwa) against two hand-rolled references:
//   (A) full-rectangle local DP, NO early stop  (pure Smith-Waterman extension)
//   (B) full-rectangle local DP, WITH ksw's mm==0 row break
// If bsw_top's 2988 mismatches line up with (A)/(B)'s divergence from ksw, that
// pins the gap to ksw's banding / early-termination semantics that the array does
// not implement.
#include <cstdio>
#include <vector>
#include <cstdlib>
#include "parse.h"

static const int BIG = 1000000;
static const int TAIL_MIN = 320, SAMPLE = 100;

struct K { int sc, qle, tle, gtle, gscore; };

static K ksw100(int qlen, const uint8_t*q, int tlen, const uint8_t*t,
                const Cfg&o, int eb, int h0) {
    K k{}; int mo;
    k.sc = ksw_extend2(qlen, q, tlen, t, 5, o.mat, o.o_del, o.e_del, o.o_ins,
                       o.e_ins, o.w, eb, o.zdrop, h0, &k.qle, &k.tle, &k.gtle,
                       &k.gscore, &mo);
    return k;
}

// Full-rectangle affine-gap local DP with seed carry-in h0 (no band).
// stop_on_zero_row mimics ksw's "if (mm==0) break".
static K fulldp(int qlen, const uint8_t*q, int tlen, const uint8_t*t,
                const Cfg&o, int h0, bool stop_on_zero_row) {
    const int oe_del = o.o_del + o.e_del, oe_ins = o.o_ins + o.e_ins;
    std::vector<int> H(qlen+1), E(qlen+1);
    // first row: eh[j].h ladder exactly like ksw init
    H[0] = h0; E[0] = 0;
    if (qlen > 0) { H[1] = h0 - oe_ins; if (H[1] < 0) H[1] = 0; E[1]=0; }
    for (int j = 2; j <= qlen; ++j) { H[j] = H[j-1]-o.e_ins; if (H[j]<0) H[j]=0; E[j]=0; }
    int max = h0, max_i=-1, max_j=-1, max_ie=-1, gscore=-1;
    for (int i = 0; i < tlen; ++i) {
        int f = 0, h1, mm = 0, mj = -1;
        const int8_t* qrow = &o.mat[t[i]*5];
        h1 = h0 - (o.o_del + o.e_del*(i+1)); if (h1 < 0) h1 = 0;
        for (int j = 0; j < qlen; ++j) {
            int M = H[j], e = E[j];
            H[j] = h1;
            M = M ? M + qrow[q[j]] : 0;
            int h = M > e ? M : e; h = h > f ? h : f;
            h1 = h;
            mj = mm > h ? mj : j; mm = mm > h ? mm : h;
            int tt = M - oe_del; tt = tt>0?tt:0; e -= o.e_del; e = e>tt?e:tt; E[j]=e;
            tt = M - oe_ins; tt = tt>0?tt:0; f -= o.e_ins; f = f>tt?f:tt;
        }
        H[qlen] = h1; E[qlen] = 0;
        // gscore at last query column
        max_ie = gscore > h1 ? max_ie : i;
        gscore = gscore > h1 ? gscore : h1;
        if (mm == 0 && stop_on_zero_row) break;
        if (mm > max) { max = mm; max_i = i; max_j = mj; }
    }
    K k{}; k.sc = max; k.qle = max_j+1; k.tle = max_i+1; k.gtle = max_ie+1; k.gscore = gscore;
    return k;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s vectors.bin\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);
    long n=0, divA=0, divB=0; long sc=0;
    auto cmp_sc=[&](const K&a,const K&b){ return a.sc!=b.sc||a.qle!=b.qle||a.tle!=b.tle; };

    for (auto& rv : reads) {
        const Cfg& o = rv.cfg; const int lq = rv.l_query;
        for (auto& c : rv.chains) for (auto& s : c.seeds) {
            int score=-1;
            if (s.qbeg) {
                const int64_t tmp=s.rbeg-c.rmax0; std::vector<uint8_t> qs(s.qbeg), rs(tmp>0?tmp:0);
                for(int i=0;i<s.qbeg;++i) qs[i]=rv.query[s.qbeg-1-i];
                for(int64_t i=0;i<tmp;++i) rs[i]=c.ref[tmp-1-i];
                int h0=s.len*o.a;
                K k=ksw100(s.qbeg,qs.data(),(int)tmp,rs.data(),o,o.pen_clip5,h0); score=k.sc;
                bool keep=((int)tmp>=TAIL_MIN)||(sc++%SAMPLE==0);
                if(keep){ n++;
                    if(cmp_sc(k,fulldp(s.qbeg,qs.data(),(int)tmp,rs.data(),o,h0,false))) divA++;
                    if(cmp_sc(k,fulldp(s.qbeg,qs.data(),(int)tmp,rs.data(),o,h0,true))) divB++;
                }
            } else score=s.len*o.a;
            const int qe0=s.qbeg+s.len; const int64_t re0=s.rbeg+s.len-c.rmax0;
            if(qe0!=lq){
                const int len2=lq-qe0; const int64_t len1=c.rmax1-c.rmax0-re0;
                std::vector<uint8_t> qs(len2), rs(len1>0?len1:0);
                for(int i=0;i<len2;++i) qs[i]=rv.query[qe0+i];
                for(int64_t i=0;i<len1;++i) rs[i]=c.ref[re0+i];
                int h0=score;
                K k=ksw100(len2,qs.data(),(int)len1,rs.data(),o,o.pen_clip3,h0);
                bool keep=((int)len1>=TAIL_MIN)||(sc++%SAMPLE==0);
                if(keep){ n++;
                    if(cmp_sc(k,fulldp(len2,qs.data(),(int)len1,rs.data(),o,h0,false))) divA++;
                    if(cmp_sc(k,fulldp(len2,qs.data(),(int)len1,rs.data(),o,h0,true))) divB++;
                }
            }
        }
    }
    printf("subset extensions = %ld\n", n);
    printf("ksw@100 vs full-DP (no break)   diverge = %ld (%.1f%%)\n", divA, 100.0*divA/n);
    printf("ksw@100 vs full-DP (mm==0 break) diverge = %ld (%.1f%%)\n", divB, 100.0*divB/n);
    printf("(tb_bsw_ext reported 2988 mismatches / 15887 = 18.8%%)\n");
    return 0;
}
