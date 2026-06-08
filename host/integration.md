# Host-side integration

This directory holds the board-agnostic host code for driving the FPGA
banded Smith-Waterman accelerator from BWA-MEM2.

## What's here

| File              | Purpose                                                     |
|-------------------|-------------------------------------------------------------|
| `bsw_fpga.h`      | API: `Request`, `Result`, `Config`, `Accelerator` class      |
| `bsw_fpga.cpp`    | Pack/unpack + request batching. No DMA / SDK dependencies.   |
| `loopback_test.cpp` | CPU-only self-checking layout test (`make run`)            |
| `Makefile`        | Builds the loopback test                                    |

The `Accelerator` class takes two function pointers at construction
(`SendFn`, `RecvFn`) so the BWA-MEM2 integration code never imports any
board SDK. Picking a board only changes the bodies of those two functions.

## Wire-format contract

The on-the-wire layout is mirrored from `rtl/bsw_axis_adapter.sv` and must
stay in lockstep with it. See the header comment of either file for the
authoritative byte map. Both `tb_bsw_axis` (Verilator) and
`loopback_test` (CPU) check the layout, so a unilateral change to either
side will surface at the next CI run.

## How to plug this into BWA-MEM2

In `bwa-mem2/src/bandedSWA.cpp` the relevant entry point is:

```cpp
int64_t BandedPairWiseSW::scalarBandedSWA(int qlen, const uint8_t *query,
                                          int tlen, const uint8_t *target,
                                          int w, int h0, ...);
```

The simplest integration is to add a thin dispatcher that builds a
`bsw_fpga::Request`, queues it, and reads back the `Result`:

```cpp
#include "bsw_fpga.h"

static bsw_fpga::Accelerator* g_acc;        // initialized at startup

int64_t BandedPairWiseSW::scalarBandedSWA(int qlen, const uint8_t *query,
                                          int tlen, const uint8_t *target,
                                          int w, int h0,
                                          int *_qle, int *_tle,
                                          int *_gtle, int *_gscore,
                                          int *_max_off) {
    bsw_fpga::Request req{};
    req.tag           = next_tag();          // host-side counter
    req.cfg.h0        = h0;
    req.cfg.o_del     = this->o_del;         // BWA-MEM2's stored penalties
    req.cfg.e_del     = this->e_del;
    req.cfg.o_ins     = this->o_ins;
    req.cfg.e_ins     = this->e_ins;
    req.cfg.zdrop     = this->zdrop;
    req.cfg.end_bonus = this->end_bonus;
    req.cfg.w         = w;
    req.cfg.qlen      = qlen;
    req.cfg.tlen      = tlen;
    std::memcpy(req.query,  query,  qlen);
    std::memcpy(req.target, target, tlen);

    g_acc->submit(req);
    auto results = g_acc->flush();           // one-at-a-time mode
    const auto& r = results.back();

    if (r.error) {
        // Fallback to the C++ kernel — qlen > N_PE, accelerator can't handle it.
        return cpu_fallback(qlen, query, tlen, target, w, h0,
                            _qle, _tle, _gtle, _gscore, _max_off);
    }
    *_qle     = r.qle;
    *_tle     = r.tle;
    *_gtle    = r.gtle;
    *_gscore  = r.gscore;
    *_max_off = r.max_off;
    return r.score;
}
```

For the throughput win, replace the per-call `flush()` with a batched mode
where the seed-extension loop pushes N requests before any `flush()`:

```cpp
for (auto& seed : seeds) g_acc->submit(build_request(seed));
auto results = g_acc->flush();
for (size_t i = 0; i < seeds.size(); ++i) apply_result(seeds[i], results[i]);
```

That is the form that actually beats the C++ scalar kernel: one DMA round
trip per N seeds instead of per seed.

## Driver bodies, per board

You wire `Accelerator(send, recv, batch_size)` with closures over the
board-specific transport. Pseudocode for the common cases:

### Intel PAC D5005 (or Stratix 10 SX dev board) — OPAE + CCI-P

```cpp
fpga_handle h = ...;     // opae fpgaOpen()
auto send = [&h](const uint8_t* p, size_t n) {
    fpgaWriteMMIO64(h, BSW_TX_FIFO_ADDR, /* descriptor pointing at p, n */);
    return 0;
};
auto recv = [&h](uint8_t* p, size_t n) {
    return opae_dma_read(h, BSW_RX_FIFO_ADDR, p, n);
};
bsw_fpga::Accelerator acc(send, recv, /*batch_size=*/64);
```

### DE10-Pro (Stratix 10) — Terasic PCIe driver

Same shape as the OPAE case but using Terasic's `PCIE_DmaWrite` /
`PCIE_DmaRead` API in place of OPAE calls.

### DE10-Standard (Cyclone V SoC) — HPS-to-FPGA AXI bridge

```cpp
volatile uint8_t* fpga_window = map_h2f_lw_axi(...);  // mmap of /dev/mem
auto send = [&](const uint8_t* p, size_t n) {
    std::memcpy(const_cast<uint8_t*>(fpga_window + TX_OFFSET), p, n);
    return 0;
};
auto recv = [&](uint8_t* p, size_t n) {
    std::memcpy(p, const_cast<const uint8_t*>(fpga_window + RX_OFFSET), n);
    return 0;
};
```

(SoC mode is the worst latency of the three but the cheapest to bring up —
useful for early validation before moving to a PCIe board.)

### Agilex 7 — OFS + AXI4-Stream DMA

Use the OFS Linux driver's character-device interface (`/dev/ofs_dma*`).
`write()` / `read()` on the FD become the `send` / `recv` bodies.

## Known limits

- **Single in-flight request.** The adapter accepts the next request only
  after the previous result has been drained. Throughput is bounded by the
  longest of (DMA send, alignment compute, DMA recv). Adding a request FIFO
  at the AXIS slave port (item B+ in `docs/speedup_plan.md`) is the
  follow-up that lets the host pipeline DMA against compute.
- **Oversize queries.** The accelerator returns `error=1` and the
  integration code must fall back to the C++ kernel.
- **Async-friendly API.** `Accelerator::submit/flush` is synchronous. A
  future iteration could expose a future-style `submit() -> std::future<Result>`
  layered on top, but for the BWA-MEM2 hot loop the batched-flush pattern
  is both simpler and faster.

## Self-test

```
cd host
make run
```

Should print `PASS` after 39 checks. This catches host-side packing
regressions without needing the FPGA in the loop. The Verilator
testbench `tb_bsw_axis` covers the same wire layout from the SV side.
