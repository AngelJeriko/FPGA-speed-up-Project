CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -msse4.2

# Golden reference = upstream bwa-mem2 ksw_align2 (ksw_ref.cpp), the bit-exact
# model for mate-rescue. ref_test is a smoke test; the scalar HW model (hw_align2)
# and its cross-check are added next.
ref_test: ref_test.cpp ksw_ref.cpp ksw_ref.h macro.h
	$(CXX) $(CXXFLAGS) -o $@ ref_test.cpp ksw_ref.cpp

run: ref_test
	./ref_test

clean:
	rm -f ref_test

.PHONY: run clean
