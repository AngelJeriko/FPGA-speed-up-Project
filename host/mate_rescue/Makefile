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

clean:
	rm -f ref_test cross_check

.PHONY: run check clean
