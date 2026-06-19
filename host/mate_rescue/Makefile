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

# Golden vectors for tb_matesw_orient_unit (matesw_top + kswr->alnreg transform).
gen_orient_vectors: gen_orient_vectors.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ gen_orient_vectors.cpp ksw_ref.cpp
orientvec: gen_orient_vectors
	./gen_orient_vectors vectors/orient_vectors.txt 4000

# Golden vectors for tb_matesw_dedup (mem_sort_dedup_patch on the ma list).
# -DMR_DEDUP_INT: oracle uses the HW integer redundancy surrogate (20*ov>19*minlen).
gen_dedup_vectors: gen_dedup_vectors.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_dedup_vectors.cpp ksw_ref.cpp
dedupvec: gen_dedup_vectors
	./gen_dedup_vectors vectors/dedup_vectors.txt 6000

# Golden vectors for tb_matesw_orch_top (full mem_matesw orchestration).
gen_orchrtl_vectors: gen_orchrtl_vectors.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_orchrtl_vectors.cpp ksw_ref.cpp
orchrtlvec: gen_orchrtl_vectors
	./gen_orchrtl_vectors vectors/orchrtl_vectors.txt 3000

# Validate hw_align2 vs REAL captured kswv outputs (capture/matesw_capture.inc).
# Usage: make checkcap && ./check_capture vectors/mate_vec.bin
check_capture: check_capture.cpp hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ check_capture.cpp ksw_ref.cpp
checkcap: check_capture

# Mate-rescue ORCHESTRATION model (orch.h) — synthetic sanity test.
matesw_orch_test: matesw_orch_test.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ matesw_orch_test.cpp ksw_ref.cpp
orch: matesw_orch_test
	./matesw_orch_test

# Validate orch.h vs REAL captured mem_matesw calls (capture/orch_capture.inc).
# Usage: make checkorch && ./check_orch vectors/orch_vec.bin
check_orch: check_orch.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ check_orch.cpp ksw_ref.cpp
checkorch: check_orch

clean:
	rm -f ref_test cross_check gen_matesw_vectors check_capture matesw_orch_test check_orch

.PHONY: run check matevec checkcap orch checkorch clean
