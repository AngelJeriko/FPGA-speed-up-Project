CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall

VEC_GZ := vectors/ext_vec.bin.gz
VEC    := vectors/ext_vec.bin

test_orch: test_orch.cpp orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ test_orch.cpp

$(VEC): $(VEC_GZ)
	gunzip -kc $(VEC_GZ) > $(VEC)

run: test_orch $(VEC)
	./test_orch $(VEC)

clean:
	rm -f test_orch $(VEC)

.PHONY: run clean
