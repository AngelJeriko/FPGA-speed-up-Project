# Session log — 2026-06-07: CPU↔FPGA interface (layers 1 + 2)

## Goal

Add the streaming interface so the BWA-MEM2 C++ side (running on the CPU)
can drive the SystemVerilog kernel (running on the FPGA) over a standard,
board-agnostic bus. Two layers:

1. **RTL** — an AXI-Stream wrapper around `bsw_top`, with a fixed wire
   format documented in code on both sides.
2. **Host C++** — a batching shim that mirrors that wire format and
   exposes a function-pointer driver interface so the BWA-MEM2 integration
   code never imports any board SDK.

The actual board-specific DMA driver (layer 3) is deferred until a board
is picked.

## What changed

### RTL

- **`rtl/bsw_axis_adapter.sv`** (new) — AXI-Stream wrapper around
  `bsw_top`. 256-bit data bus by default, parameterized for narrower /
  wider buses. Internally:
  - 6-state FSM: `S_RX_HDR → S_RX_QRY → S_RX_TGT → S_SUBMIT → S_WAIT_RES → S_TX_RES`.
  - 7 beats per request (1 header + 2 query + 4 target).
  - 1 beat per result.
  - Tag field is byte-aligned at bit 160 in the header and at bit 112 in
    the result for clean C++ access.
  - Backpressure is honored on both sides; the host is held off mid-stream
    if the adapter is still flushing the previous result.

- **`scripts/file_list.f`** + **`scripts/run_sim.sh`** — added the new
  RTL file so `tb_bsw_axis` builds.

### Testbench

- **`tb/tb_bsw_axis.sv`** (new) — serializes a known request onto the
  slave AXIS port, captures the master AXIS result beat, deserializes,
  and self-checks. 12 checks across 4 cases:
  - T1 — `ACGT/ACGT` → score=5, error=0, tag echo `0xCAFE`
  - T2 — `AAAA/CCCC` (all mismatches) → score=h0=1, error=0, tag echo `0xBEEF`
  - T3 — oversize (qlen=100 > N_PE=64) → error=1, score=0, tag echo `0x1234`
  - T4 — back-to-back recovery, T1 vectors with tag `0xFACE`

### Host C++

- **`host/bsw_fpga.h`** + **`host/bsw_fpga.cpp`** — `Accelerator` class
  with `submit(Request)` / `flush() -> vector<Result>` API, plus public
  `pack_request` / `unpack_result` for the layout test. Bit-layout
  constants mirror `rtl/bsw_axis_adapter.sv`.
- **`host/loopback_test.cpp`** — CPU-only self-checking test. 39 checks
  across 4 groups:
  - Header byte layout (tlen, qlen, w, ..., h0, tag positions)
  - Base nibble assignment in query / target beats
  - Result unpack including sign-extension and the error bit
  - Batched flush with a loopback driver that echoes tag and computes
    `score = qlen * 10` so we can detect order / correlation bugs.
- **`host/Makefile`** — builds and runs the loopback test.
- **`host/integration.md`** — drop-in patch outline for BWA-MEM2's
  `BandedPairWiseSW::scalarBandedSWA`, plus per-board driver pseudocode
  (OPAE/CCI-P, Terasic PCIe, HPS-FPGA bridge, OFS).

## What's new on the host side

The host can now do this in a hot loop:

```cpp
for (auto& seed : seeds) g_acc->submit(build_request(seed));
auto results = g_acc->flush();   // one DMA round trip for N seeds
```

instead of one DMA round trip per seed. The win depends entirely on
board PCIe latency (microseconds per round trip on PAC / DE10-Pro), so
the batching is what turns a per-seed-DMA design from a regression into
a speedup over the CPU kernel.

## Wire format (canonical)

Defined in two places that must stay in lockstep:
`rtl/bsw_axis_adapter.sv` (header comment) and `host/bsw_fpga.h`.

Request: 7 × 32 bytes = 224 bytes.

| Beat | Content |
|------|---------|
| 0 | bytes 0-1 tlen, 2-3 qlen, 4-5 w, 6-7 end_bonus, 8-9 zdrop, 10-11 e_ins, 12-13 o_ins, 14-15 e_del, 16-17 o_del, 18-19 h0, 20-21 tag, 22-31 reserved |
| 1 | query[0..63] packed, 4 bits/base, low nibble = even index |
| 2 | query[64..127] |
| 3 | target[0..63] |
| 4 | target[64..127] |
| 5 | target[128..191] |
| 6 | target[192..255], tlast=1 |

Result: 1 × 32 bytes.

| Field   | Bytes |
|---------|-------|
| max_off | 0-1   |
| gtle    | 2-3   |
| tle     | 4-5   |
| qle     | 6-7   |
| gscore  | 8-9   |
| score   | 10-11 |
| error   | 12 bit 0 |
| tag     | 14-15 |
| reserved | 16-31 |

## Test results

| Testbench / Test         | Checks | Status |
|--------------------------|:------:|:------:|
| `tb_bsw_pe` (Verilator)  | 18     | PASS   |
| `tb_bsw_top` (Verilator) | 26     | PASS   |
| `tb_bsw_axis` (Verilator)| 12     | PASS   |
| `loopback_test` (g++)    | 39     | PASS   |
| **Total**                | **95** | **PASS** |

## Decisions worth remembering

- **Default AXIS data width: 256 bits.** 64 bases per beat is exactly
  one beat per BAND_WIDTH worth of query, which keeps the beat-count
  math simple and matches typical PCIe Gen3 ×8 DMA word widths. Narrower
  buses (e.g., 64-bit for HPS-FPGA on DE10-Standard) work too via the
  `AXIS_DATA_WIDTH` parameter, at the cost of more beats per request.
- **Byte-aligned tag.** The tag could have lived right above the cfg
  packed struct, but that put it on a non-byte boundary on the result
  side (the result struct is 97 bits). Padding the tag to byte 14 (result)
  and byte 20 (header) makes the C++ side a plain `read16_le`.
- **Function-pointer driver.** Picking a board changes ~10 lines (the
  bodies of `send` / `recv`). The BWA-MEM2 patch in `host/integration.md`
  is identical across boards. This is the same pattern most production
  FPGA hosts use.
- **No request FIFO yet.** The adapter is single-in-flight; the throughput
  gain comes from the host batching N requests into one DMA burst, not
  from on-FPGA pipelining of requests. Adding a small request FIFO
  (item B+ in `docs/speedup_plan.md`) is the next non-replication
  throughput win.
- **No bit packing to 3 bits.** Bases use a nibble (4 bits) on the wire,
  not the SV-internal 3 bits, because nibbles are byte-aligned and trivial
  to read in C++. The waste (~33% of the base payload) is small relative
  to the cfg / result overhead per request.

## Open follow-ups (not done this session)

- Generate Quartus synthesis numbers (Fmax, ALMs, M20Ks) for
  `bsw_axis_adapter` to inform board sizing.
- Item C (batch DMA descriptors) once a board is chosen.
- Item B+ (deeper request FIFO).
- Item A (instance replication) once we know the area budget.
