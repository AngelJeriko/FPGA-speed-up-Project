// measure_fetch.cpp — one-off: quantify the per-chain reference-window fetch on REAL data,
// to size the on-chip genome fetch (Decision B2). Reports chains/read and window bytes.
#include <cstdio>
#include <vector>
#include <algorithm>
#include "parse.h"
static double pct(std::vector<long>& v, double p){ if(v.empty())return 0; size_t i=(size_t)(p*(v.size()-1)); return (double)v[i]; }
int main(int argc, char** argv){
    if (argc<2){ fprintf(stderr,"usage: %s ext_vec.bin\n",argv[0]); return 1; }
    std::vector<ReadVec> reads = load_reads(argv[1]);
    std::vector<long> nch, win, perread;
    long tot_win=0, tot_ch=0, tot_bytes=0;
    for (auto& rv : reads){
        if (!rv.has_hdr) continue;
        long rb=0; nch.push_back((long)rv.chains.size()); tot_ch += rv.chains.size();
        for (auto& c : rv.chains){ long w=(long)c.ref.size(); win.push_back(w); rb+=w; tot_win++; tot_bytes+=w; }
        perread.push_back(rb);
    }
    std::sort(nch.begin(),nch.end()); std::sort(win.begin(),win.end()); std::sort(perread.begin(),perread.end());
    printf("reads=%zu  chains=%ld  windows=%ld\n", reads.size(), tot_ch, tot_win);
    printf("chains/read : mean=%.2f  p50=%.0f  p95=%.0f  p99=%.0f  max=%.0f\n",
        nch.empty()?0:(double)tot_ch/nch.size(), pct(nch,.5), pct(nch,.95), pct(nch,.99), nch.empty()?0:(double)nch.back());
    printf("window bytes: mean=%.1f  p50=%.0f  p95=%.0f  p99=%.0f  max=%.0f\n",
        win.empty()?0:(double)tot_bytes/win.size(), pct(win,.5), pct(win,.95), pct(win,.99), win.empty()?0:(double)win.back());
    printf("ref bytes/read (sum of its windows): mean=%.1f  p50=%.0f  p95=%.0f  max=%.0f\n",
        perread.empty()?0:(double)tot_bytes/perread.size(), pct(perread,.5), pct(perread,.95), perread.empty()?0:(double)perread.back());
    return 0;
}
