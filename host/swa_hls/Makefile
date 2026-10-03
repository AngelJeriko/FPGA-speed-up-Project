# Golden-capture replay/verifier for the banded SWA extension kernel.
CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra -Wno-unknown-pragmas -Wno-unused-label -I../extend_orchestrator

all: replay_swa test_div_transform fuzz_ksw

replay_swa: replay_swa.cpp ksw_hls.h ../extend_orchestrator/ksw.h
	$(CXX) $(CXXFLAGS) -o $@ $<

# Acceptance test: the committed 2,000-record subset must replay bit-exact,
# and the committed divergent vectors must NOT (they are the characterised
# ksw_extend2-vs-bwa-mem2 edge cases; a pass there means the edge moved).

test_div_transform: test_div_transform.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

fuzz_ksw: fuzz_ksw.cpp ksw_hls.h ../extend_orchestrator/ksw.h
	$(CXX) $(CXXFLAGS) -I. -o $@ $<

check: replay_swa test_div_transform fuzz_ksw
	@./check.sh

clean:
	rm -f replay_swa test_div_transform fuzz_ksw

.PHONY: all check clean
