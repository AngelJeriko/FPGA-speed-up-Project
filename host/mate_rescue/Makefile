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

# Golden vectors for tb_matesw_pe_top (paired-end candidate loop).
gen_petop_vectors: gen_petop_vectors.cpp orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_petop_vectors.cpp ksw_ref.cpp
petopvec: gen_petop_vectors
	./gen_petop_vectors vectors/petop_vectors.txt 2000

# Golden vectors for tb_matesw_pe_sel_top (on-chip candidate selection + loop).
gen_pesel_vectors: gen_pesel_vectors.cpp pe.h orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_pesel_vectors.cpp ksw_ref.cpp
peselvec: gen_pesel_vectors
	./gen_pesel_vectors vectors/pesel_vectors.txt 2000

# FULL closed-loop golden for tb_accel_pe2_loop: parses accel_vectors.txt (read i's accel
# output = candidate source, read !i's = entry ma), then runs pe.h rescue. Mate headers
# only (the accel output is already verified == RTL by tb_accel_pe2_top). -DMR_DEDUP_INT.
gen_pe2_vectors: gen_pe2_vectors.cpp pe.h orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_pe2_vectors.cpp ksw_ref.cpp
pe2vec: gen_pe2_vectors
	./gen_pe2_vectors ../extend_orchestrator/vectors/accel_vectors.txt vectors/pe2_vectors.txt 300

# THE JOIN's golden for tb_chaining_pe2_top: same trick one stage further back — parses
# chainingext_vectors.txt (read i's chaining->extend->sort output = candidate source, read !i's
# = entry ma), then runs pe.h rescue. The RTL regenerates both from RAW SEEDS on chip, chaining
# included (already verified == the golden by tb_chaining_extend_top). -DMR_DEDUP_INT.
gen_chaining_pe2_vectors: gen_chaining_pe2_vectors.cpp pe.h orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_chaining_pe2_vectors.cpp ksw_ref.cpp
chainpe2vec: gen_chaining_pe2_vectors
	./gen_chaining_pe2_vectors ../extend_orchestrator/vectors/chainingext_vectors.txt vectors/chaining_pe2_vectors.txt 200

# Both-directions golden for tb_chaining_pe_pair_top: THE JOIN for a full pair (a[0]' + a[1]'),
# driven from raw seeds. Also emits each direction's rescue fb, so the pair-level tb can check
# tie==fb (gen_pe2pair_vectors omits it -- that check only existed one level down).
gen_chaining_pe2pair_vectors: gen_chaining_pe2pair_vectors.cpp pe.h orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_chaining_pe2pair_vectors.cpp ksw_ref.cpp
chainpe2pairvec: gen_chaining_pe2pair_vectors
	./gen_chaining_pe2pair_vectors ../extend_orchestrator/vectors/chainingext_vectors.txt vectors/chaining_pe2pair_vectors.txt 100

# Both-directions closed-loop golden for tb_accel_pe_pair_top (full pair: a[0]' + a[1]').
gen_pe2pair_vectors: gen_pe2pair_vectors.cpp pe.h orch.h hw.h ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -DMR_DEDUP_INT -o $@ gen_pe2pair_vectors.cpp ksw_ref.cpp
pe2pairvec: gen_pe2pair_vectors
	./gen_pe2pair_vectors ../extend_orchestrator/vectors/accel_vectors.txt vectors/pe2pair_vectors.txt 300

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

# Validate the pe.h SELECTION model vs REAL captured b[i] (capture/sel_capture.inc).
# Usage: make checksel && ./check_sel vectors/sel_vec.bin   (self-contained, no deps)
check_sel: check_sel.cpp
	$(CXX) $(CXXFLAGS) -o $@ check_sel.cpp
checksel: check_sel

clean:
	rm -f ref_test cross_check gen_matesw_vectors check_capture matesw_orch_test check_orch

.PHONY: run check matevec checkcap orch checkorch clean
