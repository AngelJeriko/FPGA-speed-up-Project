// macro.h — minimal stub so the upstream ksw_ref.cpp (bwa-mem2 ksw.cpp) compiles
// standalone. The real macro.h carries the whole bwa-mem2 build; ksw.cpp only
// needs the dimensions of the (otherwise unused here) tprof profiling array.
#ifndef MATE_RESCUE_MACRO_H
#define MATE_RESCUE_MACRO_H
#define LIM_R 2
#define LIM_C 2
#endif
