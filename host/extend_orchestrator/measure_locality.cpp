// measure_locality.cpp — Decision E2 of docs/genome_fetch_options.md: the window-cache is only worth
// building if reference-window fetches actually have LOCALITY. The doc names one source we can test
// from the extension capture directly: "a read's several chains sometimes cluster near one locus", so
// their windows [rmax0,rmax1) overlap in address space and a small cache would serve the overlap.
//
// This measures the UPPER BOUND on that: per read, merge its chain windows into address intervals;
// (sum of window bytes - union bytes) is the most a perfect within-read cache could save. If that
// fraction is ~0, hypothesis (a) is dead and E2 is not justified by it (the other source — mate-rescue
// windows overlapping the read's — needs a separate mate capture). Measure, then decide.
#include <cstdio>
#include <vector>
#include <algorithm>
#include "parse.h"

int main(int argc, char** argv){
    if (argc<2){ fprintf(stderr,"usage: %s ext_vec.bin\n",argv[0]); return 1; }
    std::vector<ReadVec> reads = load_reads(argv[1]);

    long long tot_bytes=0, union_bytes=0;
    long reads_with_chains=0, reads_with_overlap=0, multichain_reads=0;
    long long pair_adjacent=0, pair_overlapping=0;   // adjacent chain pairs (by addr) that overlap
    std::vector<long> savings_pct;                    // per-read overlap % (for the distribution)

    for (auto& rv : reads){
        if (!rv.has_hdr || rv.chains.empty()) continue;
        reads_with_chains++;
        if (rv.chains.size() >= 2) multichain_reads++;

        std::vector<std::pair<long long,long long>> iv;  // [beg,end) per chain
        long long sum=0;
        for (auto& c : rv.chains){
            long long b=c.rmax0, e=c.rmax1;
            if (e<=b) continue;
            iv.push_back({b,e}); sum += (e-b);
        }
        if (iv.empty()) continue;
        std::sort(iv.begin(), iv.end());

        // merge overlapping intervals -> union length; count adjacent overlaps
        long long ub=0, cb=iv[0].first, ce=iv[0].second;
        bool overlapped=false;
        for (size_t i=1;i<iv.size();++i){
            pair_adjacent++;
            if (iv[i].first < ce){ pair_overlapping++; overlapped=true; }   // overlaps current run
            if (iv[i].first <= ce){ if (iv[i].second>ce) ce=iv[i].second; } // extend run
            else { ub += (ce-cb); cb=iv[i].first; ce=iv[i].second; }        // gap: close run
        }
        ub += (ce-cb);

        tot_bytes += sum; union_bytes += ub;
        if (overlapped) reads_with_overlap++;
        savings_pct.push_back(sum>0 ? (long)((sum-ub)*100/sum) : 0);
    }

    std::sort(savings_pct.begin(), savings_pct.end());
    double cacheable = tot_bytes ? 100.0*(tot_bytes-union_bytes)/tot_bytes : 0.0;
    auto pctl=[&](double p){ return savings_pct.empty()?0:savings_pct[(size_t)(p*(savings_pct.size()-1))]; };

    printf("reads with >=1 chain : %ld  (>=2 chains: %ld)\n", reads_with_chains, multichain_reads);
    printf("total window bytes   : %lld\n", tot_bytes);
    printf("union (distinct)     : %lld\n", union_bytes);
    printf("=> CACHEABLE (within-read overlap) : %.2f%% of fetched bytes\n", cacheable);
    printf("reads with any overlap: %ld / %ld (%.1f%% of multi-chain reads)\n",
           reads_with_overlap, multichain_reads, multichain_reads?100.0*reads_with_overlap/multichain_reads:0.0);
    printf("adjacent chain pairs overlapping: %lld / %lld (%.1f%%)\n",
           pair_overlapping, pair_adjacent, pair_adjacent?100.0*pair_overlapping/pair_adjacent:0.0);
    printf("per-read overlap%% distribution: p50=%ld p90=%ld p99=%ld max=%ld\n",
           pctl(.5), pctl(.9), pctl(.99), savings_pct.empty()?0:savings_pct.back());
    return 0;
}
