CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall

# Synthetic sanity test of the chaining model (chain.h). Bit-exact validation vs
# real bwa-mem2 comes after the remote capture of (seed-stream -> chains) vectors.
chain_test: chain_test.cpp chain.h
	$(CXX) $(CXXFLAGS) -o $@ chain_test.cpp
run: chain_test
	./chain_test

clean:
	rm -f chain_test

.PHONY: run clean
