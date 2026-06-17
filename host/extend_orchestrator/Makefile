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

gen_asm_vectors: gen_asm_vectors.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ gen_asm_vectors.cpp

asm: gen_asm_vectors $(VEC)
	./gen_asm_vectors $(VEC) vectors/asm_vectors.txt

gen_seedcov_vectors: gen_seedcov_vectors.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ gen_seedcov_vectors.cpp

seedcov: gen_seedcov_vectors $(VEC)
	./gen_seedcov_vectors $(VEC) vectors/seedcov_vectors.txt

gen_window_vectors: gen_window_vectors.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ gen_window_vectors.cpp

window: gen_window_vectors $(VEC)
	./gen_window_vectors $(VEC) vectors/window_vectors.txt

# --- BSW sizing / full-DP equivalence analyses (one-shot, print to stdout) ---
measure_dims: measure_dims.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ measure_dims.cpp
dims: measure_dims $(VEC)
	./measure_dims $(VEC)

check_band: check_band.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ check_band.cpp
checkband: check_band $(VEC)
	./check_band $(VEC)

check_fulldp: check_fulldp.cpp parse.h orch.h ksw.h
	$(CXX) $(CXXFLAGS) -o $@ check_fulldp.cpp
checkfull: check_fulldp $(VEC)
	./check_fulldp $(VEC)

# HW-faithful (full-DP) end-to-end model vs the captured golden output.
test_orch_full: test_orch.cpp orch.h ksw.h
	$(CXX) $(CXXFLAGS) -DFULLDP_BAND -o $@ test_orch.cpp
runfull: test_orch_full $(VEC)
	./test_orch_full $(VEC)

clean:
	rm -f test_orch test_orch_full gen_orch_vectors gen_asm_vectors gen_seedcov_vectors \
	      gen_window_vectors measure_dims check_band check_fulldp \
	      $(VEC) vectors/ext_prepurge.bin vectors/asm_vectors.txt \
	      vectors/seedcov_vectors.txt vectors/window_vectors.txt

.PHONY: run runfull gen asm seedcov window dims checkband checkfull clean
