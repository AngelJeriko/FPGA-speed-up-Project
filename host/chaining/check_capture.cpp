// check_capture.cpp — validate the chaining model (chain.h) bit-exact against REAL
// captured bwa-mem2 vectors (chain_capture.inc, env ALNREG_CHAIN_OUT). Two checks:
//   type 0: c_mem_chain(seed stream)      == captured pre-flt chains
//   type 1: c_mem_chain_flt(pre-flt in)   == captured post-flt chains
// This is the remote-capture leg of the chaining verification
// (docs/chaining_engine_scope.md): the real mem_chain can't compile standalone.
//
// Record format: see host/chaining/capture/chain_capture.inc.
//   CHAIN sub-record: i32 rid; i32 seqid; i64 pos; i32 is_alt; i32 n;
//                     n*{ i64 rbeg; i32 qbeg; i32 len; i32 score }
//
// Build: make checkcap     Run: ./check_capture vectors/chain_vec.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "chain.h"

template<class T> static bool rd(FILE*f, T&v){ return fread(&v,sizeof(T),1,f)==1; }

static bool read_chain(FILE* f, CChain& c) {
    int32_t rid,seqid,isalt,n; int64_t pos;
    if(!rd(f,rid)||!rd(f,seqid)||!rd(f,pos)||!rd(f,isalt)||!rd(f,n)) return false;
    c.rid=rid; c.seqid=seqid; c.pos=pos; c.is_alt=isalt!=0; c.seeds.clear();
    for (int i=0;i<n;++i){ CSeed s; int32_t qb,ln,sc; int64_t rb;
        if(!rd(f,rb)||!rd(f,qb)||!rd(f,ln)||!rd(f,sc)) return false;
        s.rbeg=rb; s.qbeg=qb; s.len=ln; s.score=sc; c.seeds.push_back(s); }
    return true;
}

// chains equal if same pos/rid/is_alt and identical seed list (rbeg,qbeg,len,score)
static bool chain_eq(const CChain&a, const CChain&b){
    if (a.pos!=b.pos || a.rid!=b.rid || a.is_alt!=b.is_alt) return false;
    if (a.seeds.size()!=b.seeds.size()) return false;
    for (size_t i=0;i<a.seeds.size();++i){
        const CSeed&x=a.seeds[i], &y=b.seeds[i];
        if (x.rbeg!=y.rbeg||x.qbeg!=y.qbeg||x.len!=y.len||x.score!=y.score) return false;
    }
    return true;
}
static bool chains_eq(const std::vector<CChain>&a, const std::vector<CChain>&b){
    if (a.size()!=b.size()) return false;
    for (size_t i=0;i<a.size();++i) if(!chain_eq(a[i],b[i])) return false;
    return true;
}

int main(int argc, char** argv){
    if (argc<2){ fprintf(stderr,"usage: %s capture.bin\n",argv[0]); return 2; }
    FILE* f=fopen(argv[1],"rb");
    if(!f){ fprintf(stderr,"cannot open %s\n",argv[1]); return 2; }
    COpt o;   // bwa-mem2 defaults (w=100, gap=10000, msl=19, a=1, mcw=0, mce=1<<30)

    long n0=0, n1=0, f0=0, f1=0;
    int32_t type;
    while (rd(f,type)){
        if (type==0){
            int64_t read_id, lpac; int32_t seqid, ns;
            if(!rd(f,read_id)||!rd(f,seqid)||!rd(f,lpac)||!rd(f,ns)){ fprintf(stderr,"trunc seedstream hdr\n"); break; }
            std::vector<CSeed> seeds; std::vector<int> rid; std::vector<bool> alt;
            bool ok=true;
            for (int i=0;i<ns;++i){
                int64_t rb; int32_t qb,ln,sc,sr,sa;
                if(!rd(f,rb)||!rd(f,qb)||!rd(f,ln)||!rd(f,sc)||!rd(f,sr)||!rd(f,sa)){ ok=false; break; }
                CSeed s; s.rbeg=rb; s.qbeg=qb; s.len=ln; s.score=sc;
                seeds.push_back(s); rid.push_back(sr); alt.push_back(sa!=0);
            }
            if(!ok){ fprintf(stderr,"trunc seeds\n"); break; }
            int32_t nch; if(!rd(f,nch)){ fprintf(stderr,"trunc nch\n"); break; }
            std::vector<CChain> cap;
            for (int i=0;i<nch;++i){ CChain c; if(!read_chain(f,c)){ ok=false; break; } cap.push_back(c); }
            if(!ok){ fprintf(stderr,"trunc prechains\n"); break; }
            n0++;
            std::vector<CChain> got = c_mem_chain(o, lpac, seqid, seeds, rid, alt);
            if (!chains_eq(got, cap)){ f0++;
                if (f0<=15) printf("[mem_chain MISMATCH] read_id=%lld seeds=%d got=%zu cap=%zu\n",
                                   (long long)read_id, ns, got.size(), cap.size());
            }
        } else if (type==1){
            int64_t flt_id; int32_t n_in;
            if(!rd(f,flt_id)||!rd(f,n_in)){ fprintf(stderr,"trunc flt hdr\n"); break; }
            std::vector<CChain> in;
            bool ok=true;
            for (int i=0;i<n_in;++i){ CChain c; if(!read_chain(f,c)){ ok=false; break; } in.push_back(c); }
            if(!ok){ fprintf(stderr,"trunc flt in\n"); break; }
            int32_t n_out; if(!rd(f,n_out)){ fprintf(stderr,"trunc n_out\n"); break; }
            std::vector<CChain> cap;
            for (int i=0;i<n_out;++i){ CChain c; if(!read_chain(f,c)){ ok=false; break; } cap.push_back(c); }
            if(!ok){ fprintf(stderr,"trunc flt out\n"); break; }
            n1++;
            std::vector<CChain> got = c_mem_chain_flt(o, in);
            if (!chains_eq(got, cap)){ f1++;
                if (f1<=15) printf("[mem_chain_flt MISMATCH] flt_id=%lld in=%d got=%zu cap=%zu\n",
                                   (long long)flt_id, n_in, got.size(), cap.size());
            }
        } else { fprintf(stderr,"bad type %d\n",type); break; }
    }
    fclose(f);
    printf("mem_chain    : %ld checked, %ld failures\n", n0, f0);
    printf("mem_chain_flt: %ld checked, %ld failures\n", n1, f1);
    bool pass = (f0==0 && f1==0 && (n0+n1)>0);
    printf("check_capture: %s\n", pass ? "ALL PASS" : "FAIL");
    return pass ? 0 : 1;
}
