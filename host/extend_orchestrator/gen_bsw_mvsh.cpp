// gen_bsw_mvsh.cpp — regression generator for the bsw_pe gap-open fix.
//
// Background: rtl/bsw_pe.sv originally opened new E/F gaps from H_new=max(M,E,F);
// bwa-mem2 scalarBandedSWA (bandedSWA.cpp:190,195) opens them from M (the diagonal
// match term) — "separating H and M to disallow a cigar like 100M3I3D20M" (:184).
// This program is a faithful twin of that reference with a RUNTIME `buggy` switch
// (open from H vs M), used to (a) prove the twin == bwa on 15887 real goldens and
// (b) mine the discriminating vector vectors/disc_mvsh.txt (correct gscore=5, the
// buggy H-open gives 6). tb_bsw_ext on that vector: FAIL before fix, PASS after.
//   build:    g++ -O2 -std=c++17 -o gen_bsw_mvsh gen_bsw_mvsh.cpp
//   validate: ./gen_bsw_mvsh validate vectors/ext_sw_vectors.txt
//   mine:     ./gen_bsw_mvsh search 12345 5000000     (emits a tb_bsw_ext vector)
//
// (formerly scalar_bsw.cpp) — faithful standalone twin of bwa-mem2 scalarBandedSWA
// (src/bandedSWA.cpp:125-229), with a runtime `buggy` switch that flips ONLY
// the two gap-open bases from M (correct, upstream) to H_new (the RTL bug).
//
// Score matrix matches rtl/bsw_score_matrix.sv exactly:
//   match=+1, mismatch=-4, any-N=-1.
//
// Modes:
//   validate <ext_sw_vectors.txt> [N]  -> run correct model vs real bwa golden
//   search   [seed] [tries]            -> find a (q,t,params) where correct!=buggy
//   emit     <token-args...>           -> print one tb_bsw_ext vector (see code)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
using namespace std;

static inline int sc(int qb, int tb){
    if (qb==4 || tb==4) return -1;   // ambig / N
    return (qb==tb) ? 1 : -4;
}

struct Res { int score, qle, tle, gscore, gtle, maxoff; };

// Faithful reproduction of scalarBandedSWA. buggy=false -> open gaps from M
// (upstream); buggy=true -> open from h=H_new=max(M,E,F) (current RTL bsw_pe.sv).
static Res align(const vector<int>& query, const vector<int>& target,
                 int h0, int o_del,int e_del,int o_ins,int e_ins,
                 int zdrop,int end_bonus,int w, bool buggy, bool fulldp=false)
{
    if (fulldp) w = 1<<20;   // effectively unbanded, matching the RTL's full DP
    int qlen=(int)query.size(), tlen=(int)target.size();
    int oe_del=o_del+e_del, oe_ins=o_ins+e_ins;
    int i,j,beg,end,max,max_i,max_j,max_ins,max_del,max_ie,gscore,max_off;
    vector<int> eh_h(qlen+1,0), eh_e(qlen+1,0);      // eh[].h , eh[].e

    // first row
    eh_h[0]=h0; eh_h[1]= h0>oe_ins? h0-oe_ins : 0;
    for (j=2;j<=qlen && eh_h[j-1]>e_ins; ++j) eh_h[j]=eh_h[j-1]-e_ins;

    // adjust w (mat max score = 1)
    int matmax=1;
    max_ins=(int)((double)(qlen*matmax+end_bonus-o_ins)/e_ins+1.); max_ins=max_ins>1?max_ins:1;
    if (w>max_ins) w=max_ins;
    max_del=(int)((double)(qlen*matmax+end_bonus-o_del)/e_del+1.); max_del=max_del>1?max_del:1;
    if (w>max_del) w=max_del;

    max=h0; max_i=max_j=-1; max_ie=-1; gscore=-1; max_off=0;
    beg=0; end=qlen;
    for (i=0;i<tlen;++i){
        int t, f=0, h1, m=0, mj=-1;
        if (beg < i-w) beg=i-w;
        if (end > i+w+1) end=i+w+1;
        if (end > qlen) end=qlen;
        if (beg==0){ h1=h0-(o_del+e_del*(i+1)); if(h1<0)h1=0; } else h1=0;
        for (j=beg;j<end;++j){
            int h, M=eh_h[j], e=eh_e[j];
            eh_h[j]=h1;
            M = M ? M + sc(query[j], target[i]) : 0;
            h = M>e? M:e;  h = h>f? h:f;
            h1 = h;
            mj = m>h? mj:j;
            m  = m>h? m:h;
            int base = buggy ? h : M;      // <<< THE ONLY DIFFERENCE
            t = base - oe_del; t = t>0? t:0;
            e -= e_del; e = e>t? e:t;
            eh_e[j]=e;
            t = base - oe_ins; t = t>0? t:0;
            f -= e_ins; f = f>t? f:t;
        }
        eh_h[end]=h1; eh_e[end]=0;
        if (j==qlen){ max_ie = gscore>h1? max_ie:i; gscore = gscore>h1? gscore:h1; }
        if (m==0) break;
        if (m>max){ max=m; max_i=i; max_j=mj; int a=mj-i; if(a<0)a=-a; max_off=max_off>a?max_off:a; }
        else if (zdrop>0){
            if (i-max_i > mj-max_j){ if (max-m-((i-max_i)-(mj-max_j))*e_del > zdrop) break; }
            else { if (max-m-((mj-max_j)-(i-max_i))*e_ins > zdrop) break; }
        }
        for (j=beg;j<end && eh_h[j]==0 && eh_e[j]==0;++j);
        beg=j;
        for (j=end;j>=beg && eh_h[j]==0 && eh_e[j]==0;--j);
        end = j+2<qlen? j+2:qlen;
    }
    Res r; r.score=max; r.qle=max_j+1; r.tle=max_i+1;
    r.gscore = gscore<0?0:gscore;   // RTL/golden convention: gscore clamped >=0
    r.gtle=max_ie+1; r.maxoff=max_off;
    return r;
}

// ---- tiny xorshift so runs are deterministic & seedable ----
static uint64_t RS;
static inline uint32_t rnd(){ RS^=RS<<13; RS^=RS>>7; RS^=RS<<17; return (uint32_t)(RS>>32); }

int main(int argc,char**argv){
    string mode = argc>1? argv[1] : "search";

    if (mode=="validate"){
        FILE*fp=fopen(argv[2],"r"); if(!fp){fprintf(stderr,"open fail\n");return 1;}
        int cnt; if(fscanf(fp,"%d",&cnt)!=1)return 1;
        int N = argc>3? atoi(argv[3]) : cnt; if(N>cnt)N=cnt;
        int side,qlen,tlen,h0,eb,od,ed,oi,ei,zd,es,eq,et,eg,egt,emo;
        int pass=0,fail=0;
        for(int k=0;k<cnt;++k){
            if(fscanf(fp,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
               &side,&qlen,&tlen,&h0,&eb,&od,&ed,&oi,&ei,&zd,&es,&eq,&et,&eg,&egt,&emo)!=16) break;
            vector<int> q(qlen),t(tlen);
            for(int b=0;b<qlen;++b) if(fscanf(fp,"%d",&q[b])!=1)return 1;
            for(int b=0;b<tlen;++b) if(fscanf(fp,"%d",&t[b])!=1)return 1;
            if(k>=N) continue;
            Res r=align(q,t,h0,od,ed,oi,ei,zd,eb,100,false);
            bool ok = r.score==es && r.qle==eq && r.tle==et && r.gscore==eg &&
                      (eg>0 ? r.gtle==egt : true);
            if(ok)pass++; else { if(fail<8) printf("  DIFF[%d] sc %d/%d qle %d/%d tle %d/%d gsc %d/%d gtle %d/%d\n",
                        k,r.score,es,r.qle,eq,r.tle,et,r.gscore,eg,r.gtle,egt); fail++; }
        }
        fclose(fp);
        printf("validate: %d checked, %d pass, %d fail -> %s\n",N,pass,fail,fail==0?"MODEL==BWA":"MODEL DIVERGES");
        return fail==0?0:1;
    }

    if (mode=="search" || mode=="searchscore"){
        bool scoreonly = (mode=="searchscore");
        RS = (argc>2? strtoull(argv[2],0,10) : 88172645463325252ULL) | 1;
        long tries = argc>3? atol(argv[3]) : 2000000;
        int o_del=6,e_del=1,o_ins=6,e_ins=1,zdrop=100;
        int found=0;
        for(long it=0; it<tries; ++it){
            // match-biased: build target as query with a few random indels/subs,
            // so the optimal path is long and can route a MAX cell through a gap.
            int qlen = 10 + rnd()%30;
            int h0   = 1 + rnd()%25;
            vector<int> q(qlen), t;
            for(auto&x:q)x=rnd()%4;
            for(int b=0;b<qlen;++b){
                uint32_t r=rnd()%100;
                if(r<12){ /*deletion in target: skip*/ }
                else if(r<24){ t.push_back(rnd()%4); t.push_back(q[b]); } /*insertion*/
                else if(r<32){ t.push_back(rnd()%4); } /*subst*/
                else t.push_back(q[b]); /*match*/
            }
            if(t.size()<4||t.size()>60) continue;
            int tlen=(int)t.size(); (void)tlen;
            Res rc=align(q,t,h0,o_del,e_del,o_ins,e_ins,zdrop,5,100,false);
            Res rb=align(q,t,h0,o_del,e_del,o_ins,e_ins,zdrop,5,100,true);
            bool diff = scoreonly ? (rc.score!=rb.score || rc.qle!=rb.qle || rc.tle!=rb.tle)
                                  : (rc.score!=rb.score || rc.qle!=rb.qle || rc.tle!=rb.tle || rc.gscore!=rb.gscore);
            if(diff){
                // emit a self-contained tb_bsw_ext single-vector file to stdout
                printf("# FOUND after %ld tries: correct{sc=%d qle=%d tle=%d gsc=%d gtle=%d} buggy{sc=%d qle=%d tle=%d gsc=%d gtle=%d}\n",
                    it, rc.score,rc.qle,rc.tle,rc.gscore,rc.gtle, rb.score,rb.qle,rb.tle,rb.gscore,rb.gtle);
                printf("1\n");
                printf("0 %d %d %d 5 %d %d %d %d %d %d %d %d %d %d %d\n",
                    qlen,tlen,h0, o_del,e_del,o_ins,e_ins,zdrop,
                    rc.score,rc.qle,rc.tle,rc.gscore,rc.gtle,rc.maxoff);
                for(int b=0;b<qlen;++b) printf("%d ",q[b]); printf("\n");
                for(int b=0;b<tlen;++b) printf("%d ",t[b]); printf("\n");
                if(++found>=1) return 0;
            }
        }
        printf("# no discriminating case in %ld tries\n",tries);
        return 2;
    }
    fprintf(stderr,"unknown mode\n"); return 1;
}
