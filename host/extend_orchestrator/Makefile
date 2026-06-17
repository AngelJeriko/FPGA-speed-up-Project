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

gen_orch_vectors: gen_orch_vectors.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ gen_orch_vectors.cpp

gen: gen_orch_vectors $(VEC)
	./gen_orch_vectors $(VEC) vectors/ext_prepurge.bin

clean:
	rm -f test_orch gen_orch_vectors $(VEC) vectors/ext_prepurge.bin

.PHONY: run gen clean
