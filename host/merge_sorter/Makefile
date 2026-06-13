CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
VECTORS  ?= vectors/alnreg_vectors.bin

test_sorter: test_sorter.cpp key.h folded_sorter.h
	$(CXX) $(CXXFLAGS) -o $@ test_sorter.cpp

.PHONY: run clean
run: test_sorter
	./test_sorter $(VECTORS)

clean:
	rm -f test_sorter
