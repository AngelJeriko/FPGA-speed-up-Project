CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
VECTORS  ?= vectors/alnreg_vectors.bin

V2VECTORS ?= vectors/alnreg_v2_vectors.bin

test_sorter: test_sorter.cpp key.h folded_sorter.h
	$(CXX) $(CXXFLAGS) -o $@ test_sorter.cpp

test_v2: test_v2.cpp v2_dedup.h
	$(CXX) $(CXXFLAGS) -o $@ test_v2.cpp

.PHONY: run run_v2 clean
run: test_sorter
	./test_sorter $(VECTORS)

run_v2: test_v2
	./test_v2 $(V2VECTORS)

clean:
	rm -f test_sorter test_v2
