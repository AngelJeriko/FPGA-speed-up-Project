# host/Makefile — build the CPU-only loopback test.
# Real board drivers live outside this Makefile (see integration.md).

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter

loopback_test: loopback_test.cpp bsw_fpga.cpp bsw_fpga.h
	$(CXX) $(CXXFLAGS) -o $@ loopback_test.cpp bsw_fpga.cpp

run: loopback_test
	./loopback_test

clean:
	rm -f loopback_test

.PHONY: run clean
