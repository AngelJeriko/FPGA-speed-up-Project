# Golden-capture replay/verifier for the banded SWA extension kernel.
CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra -I../extend_orchestrator

all: replay_swa

replay_swa: replay_swa.cpp ../extend_orchestrator/ksw.h
	$(CXX) $(CXXFLAGS) -o $@ $<

# Acceptance test: the committed 2,000-record subset must replay bit-exact,
# and the committed divergent vectors must NOT (they are the characterised
# ksw_extend2-vs-bwa-mem2 edge cases; a pass there means the edge moved).
check: replay_swa
	@set -e; tmp=$$(mktemp -d); \
	zcat vectors/ecoli_swa_2k.bin.gz > $$tmp/g.bin; \
	./replay_swa $$tmp/g.bin | tail -1; \
	./replay_swa $$tmp/g.bin > /dev/null; \
	for v in vectors/divergent_*.bin.gz; do \
	  zcat $$v > $$tmp/d.bin; \
	  if ./replay_swa $$tmp/d.bin > /dev/null 2>&1; then \
	    echo "UNEXPECTED PASS on $$v -- characterised divergence changed"; rm -rf $$tmp; exit 1; \
	  else echo "divergence vector still red (expected): $$v"; fi; \
	done; \
	rm -rf $$tmp; echo "check: OK"

clean:
	rm -f replay_swa

.PHONY: all check clean
