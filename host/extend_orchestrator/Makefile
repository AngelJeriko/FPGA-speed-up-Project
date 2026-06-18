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

# HW-model (full-rectangle systolic array, hw.h) end-to-end vs golden. This is
# the model bsw_top reproduces bit-exactly; ALL PASS proves the array's gscore/
# argmax behaviour drives a bit-exact orchestrator output.
test_orch_hw: test_orch.cpp orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -o $@ test_orch.cpp
runhw: test_orch_hw $(VEC)
	./test_orch_hw $(VEC)

# Full hardware-faithful model: full-rectangle SW (hw.h) + integer-only purge.
# ALL PASS proves the entire orchestrator is integer-exact vs real bwa-mem2.
test_orch_inthw: test_orch.cpp orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -DINTPURGE -o $@ test_orch.cpp
runinthw: test_orch_inthw $(VEC)
	./test_orch_inthw $(VEC)

# Per-extension SW golden for tb_bsw_ext (expected = hw.h full-rectangle array).
gen_ext_vectors: gen_ext_vectors.cpp parse.h orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -o $@ gen_ext_vectors.cpp
extvec: gen_ext_vectors $(VEC)
	./gen_ext_vectors $(VEC) vectors/ext_sw_vectors.txt

# Per-seed golden for tb_bsw_seed_unit (expected = extend_only pre-purge alnreg,
# HW model). Built with -DHWMODEL so it matches bsw_top.
gen_seedext_vectors: gen_seedext_vectors.cpp parse.h orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -o $@ gen_seedext_vectors.cpp
seedext: gen_seedext_vectors $(VEC)
	./gen_seedext_vectors $(VEC) vectors/seedext_vectors.txt

# Per-chain golden for tb_orch_chain_unit (expected = extend_only per-chain slice).
gen_chain_vectors: gen_chain_vectors.cpp parse.h orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -o $@ gen_chain_vectors.cpp
chainvec: gen_chain_vectors $(VEC)
	./gen_chain_vectors $(VEC) vectors/chain_vectors.txt

# Per-read golden for tb_orch_purge (pre-purge av in, integer post-purge qb/qe out).
gen_purge_vectors: gen_purge_vectors.cpp parse.h orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -DINTPURGE -o $@ gen_purge_vectors.cpp
purgevec: gen_purge_vectors $(VEC)
	./gen_purge_vectors $(VEC) vectors/purge_vectors.txt

# Per-read golden for tb_orch_read_top (full extend-orchestrator vs orchestrate()).
gen_read_vectors: gen_read_vectors.cpp parse.h orch.h ksw.h hw.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -DINTPURGE -o $@ gen_read_vectors.cpp
readvec: gen_read_vectors $(VEC)
	./gen_read_vectors $(VEC) vectors/read_vectors.txt

# Per-read golden for tb_accel_top (full accelerator: orchestrate->compact->v2_dedup).
gen_accel_vectors: gen_accel_vectors.cpp parse.h orch.h ksw.h hw.h ../merge_sorter/v2_dedup.h
	$(CXX) $(CXXFLAGS) -DHWMODEL -DINTPURGE -o $@ gen_accel_vectors.cpp
accelvec: gen_accel_vectors $(VEC)
	./gen_accel_vectors $(VEC) vectors/accel_vectors.txt

dp_dump: dp_dump.cpp
	$(CXX) $(CXXFLAGS) -o $@ dp_dump.cpp

clean:
	rm -f test_orch test_orch_int test_orch_full test_orch_hw test_orch_inthw gen_orch_vectors gen_asm_vectors \
	      gen_seedcov_vectors gen_window_vectors gen_ext_vectors gen_seedext_vectors \
	      gen_chain_vectors gen_purge_vectors gen_read_vectors gen_accel_vectors measure_dims \
	      check_band check_fulldp check_truedp dp_dump \
	      $(VEC) vectors/ext_prepurge.bin vectors/asm_vectors.txt \
	      vectors/seedcov_vectors.txt vectors/window_vectors.txt \
	      vectors/ext_sw_vectors.txt vectors/ext_small.txt vectors/seedext_vectors.txt \
	      vectors/chain_vectors.txt vectors/purge_vectors.txt vectors/read_vectors.txt \
	      vectors/accel_vectors.txt

.PHONY: run runfull runhw gen asm seedcov window dims extvec seedext chainvec purgevec readvec accelvec checkband checkfull clean
