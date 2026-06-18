CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -msse4.2

# Golden reference = upstream bwa-mem2 ksw_align2 (ksw_ref.cpp), the bit-exact
# model for mate-rescue. ref_test is a smoke test; the scalar HW model (hw_align2)
# and its cross-check are added next.
ref_test: ref_test.cpp ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ ref_test.cpp ksw_ref.cpp

run: ref_test
	./ref_test

# Cross-check the scalar HW model (hw.h) vs the upstream ksw_align2 reference.
cross_check: cross_check.cpp hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ cross_check.cpp ksw_ref.cpp
check: cross_check
	./cross_check 200000

# Golden vectors for the RTL engine tb_matesw_top (expected = hw_align2).
gen_matesw_vectors: gen_matesw_vectors.cpp hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ gen_matesw_vectors.cpp ksw_ref.cpp
matevec: gen_matesw_vectors
	./gen_matesw_vectors vectors/matesw_vectors.txt 4000

clean:
	rm -f ref_test cross_check gen_matesw_vectors

.PHONY: run check matevec clean
