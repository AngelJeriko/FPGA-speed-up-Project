CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall

# Synthetic sanity test of the chaining model (chain.h). Bit-exact validation vs
# real bwa-mem2 comes after the remote capture of (seed-stream -> chains) vectors.
chain_test: chain_test.cpp chain.h
	$(CXX) $(CXXFLAGS) -o $@ chain_test.cpp
run: chain_test
	./chain_test

# Validate chain.h vs REAL captured chains (capture/chain_capture.inc).
# Usage: make checkcap && ./check_capture vectors/chain_vec.bin
check_capture: check_capture.cpp chain.h
	$(CXX) $(CXXFLAGS) -o $@ check_capture.cpp
checkcap: check_capture

clean:
	rm -f chain_test check_capture

.PHONY: run checkcap clean
