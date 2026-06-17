// measure_dims.cpp — scan the captured vectors and report the real maximum
// extension dimensions (query/target lengths actually fed to ksw_extend2) so the
// BSW engine (MAX_QLEN / MAX_TLEN / N_PE) can be sized precisely rather than guessed.
#include <cstdio>
#include <algorithm>
#include "parse.h"

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s vectors.bin\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);

    int max_lquery = 0, max_refwin = 0;
    int max_qL = 0, max_tL = 0, max_qR = 0, max_tR = 0;
    int max_q_any = 0, max_t_any = 0;
    long n_ext = 0;
    // histogram of target length in 64-wide buckets up to 1024
    long thist[20] = {0};

    for (auto &rv : reads) {
        max_lquery = std::max(max_lquery, rv.l_query);
        for (auto &c : rv.chains) {
            max_refwin = std::max(max_refwin, (int)c.ref.size());
            for (auto &s : c.seeds) {
                const int qe0 = s.qbeg + s.len;
                const long re0 = s.rbeg + s.len - c.rmax0;
                // left
                if (s.qbeg) {
                    int qL = s.qbeg;
                    int tL = (int)(s.rbeg - c.rmax0);
                    max_qL = std::max(max_qL, qL); max_tL = std::max(max_tL, tL);
                    max_q_any = std::max(max_q_any, qL); max_t_any = std::max(max_t_any, tL);
                    n_ext++;
                    int b = tL/64; if (b>19) b=19; if (b>=0) thist[b]++;
                }
                // right
                if (qe0 != rv.l_query) {
                    int qR = rv.l_query - qe0;
                    int tR = (int)(c.rmax1 - c.rmax0 - re0);
                    max_qR = std::max(max_qR, qR); max_tR = std::max(max_tR, tR);
                    max_q_any = std::max(max_q_any, qR); max_t_any = std::max(max_t_any, tR);
                    n_ext++;
                    int b = tR/64; if (b>19) b=19; if (b>=0) thist[b]++;
                }
            }
        }
    }

    printf("reads=%zu  extensions=%ld\n", reads.size(), n_ext);
    printf("max l_query   = %d\n", max_lquery);
    printf("max ref window= %d\n", max_refwin);
    printf("LEFT : max qlen=%d  max tlen=%d\n", max_qL, max_tL);
    printf("RIGHT: max qlen=%d  max tlen=%d\n", max_qR, max_tR);
    printf("ANY  : max qlen=%d  max tlen=%d\n", max_q_any, max_t_any);
    printf("target-length histogram (64-wide buckets):\n");
    for (int i = 0; i < 20; ++i)
        if (thist[i]) printf("  [%4d,%4d): %ld\n", i*64, (i+1)*64, thist[i]);
    return 0;
}
