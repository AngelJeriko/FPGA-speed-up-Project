// host/bsw_fpga.h
// Host-side C++ shim for the FPGA Banded Smith-Waterman accelerator.
//
// Responsibilities:
//   1. Batch a stream of per-alignment Requests into one DMA-friendly buffer.
//   2. Pack each Request into the on-the-wire format expected by
//      rtl/bsw_axis_adapter.sv (7 beats * 32 bytes = 224 bytes per request).
//   3. Hand the batched buffer to a board-specific driver via a function
//      pointer (so BWA-MEM2 integration code stays board-agnostic).
//   4. Unpack the result stream (32 bytes per result) into Result structs.
//
// The on-the-wire layout is mirrored from rtl/bsw_axis_adapter.sv; any change
// there MUST be mirrored here, and vice versa. The loopback test
// (host/loopback_test.cpp) checks the layout against a hand-crafted golden
// buffer so drift is caught at compile-time-ish.
//
// This file deliberately does NOT include any board SDK headers (OPAE, HPS
// bridges, PCIe drivers). The driver is injected via std::function pointers;
// see host/integration.md for per-board examples.

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

namespace bsw_fpga {

// ---- Wire-format constants (mirrors bsw_axis_adapter.sv) ----
constexpr int MAX_QLEN              = 128;
constexpr int MAX_TLEN              = 256;
constexpr int AXIS_DATA_WIDTH_BITS  = 256;
constexpr int AXIS_DATA_WIDTH_BYTES = AXIS_DATA_WIDTH_BITS / 8;     // 32
constexpr int BASES_PER_BEAT        = AXIS_DATA_WIDTH_BITS / 4;     // 64
constexpr int HDR_BEATS             = 1;
constexpr int QRY_BEATS             = (MAX_QLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT; // 2
constexpr int TGT_BEATS             = (MAX_TLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT; // 4
constexpr int REQ_BEATS             = HDR_BEATS + QRY_BEATS + TGT_BEATS;                // 7
constexpr int RES_BEATS             = 1;
constexpr std::size_t REQ_BYTES     = REQ_BEATS * AXIS_DATA_WIDTH_BYTES;  // 224
constexpr std::size_t RES_BYTES     = RES_BEATS * AXIS_DATA_WIDTH_BYTES;  //  32

// ---- BWA-MEM2 base encoding (must match score matrix in rtl/bsw_score_matrix.sv) ----
// A=0, C=1, G=2, T=3, N=4. Anything else triggers W_AMBIG.
constexpr uint8_t BASE_A = 0;
constexpr uint8_t BASE_C = 1;
constexpr uint8_t BASE_G = 2;
constexpr uint8_t BASE_T = 3;
constexpr uint8_t BASE_N = 4;

struct Config {
    int16_t  h0;        // initial seed H value
    int16_t  o_del;     // gap-open  (deletion)   — positive magnitude
    int16_t  e_del;     // gap-extend (deletion)  — positive magnitude
    int16_t  o_ins;     // gap-open  (insertion)
    int16_t  e_ins;     // gap-extend (insertion)
    int16_t  zdrop;     // 0 disables
    int16_t  end_bonus;
    uint16_t w;         // band half-width
    uint16_t qlen;      // <= MAX_QLEN, <= N_PE on the synthesized adapter
    uint16_t tlen;      // <= MAX_TLEN
};

struct Result {
    bool     error;     // true if request was rejected (e.g., qlen > N_PE)
    int16_t  score;
    int16_t  gscore;
    uint16_t qle;
    uint16_t tle;
    uint16_t gtle;
    uint16_t max_off;
    uint16_t tag;       // echoed from the originating Request
};

struct Request {
    uint16_t tag;       // opaque round-trip id, host-assigned
    Config   cfg;
    uint8_t  query  [MAX_QLEN];   // pad unused tail bases with 0
    uint8_t  target [MAX_TLEN];
};

// Driver contract.
//   send: ship `bytes` bytes of request data over the AXIS slave port.
//         Implementations may queue / DMA / poll — but must not return until
//         the buffer is no longer needed by the driver. Returns 0 on success.
//   recv: block until `bytes` bytes of result data are available from the
//         AXIS master port. Returns 0 on success.
// A loopback driver (host/loopback_test.cpp) implements both in CPU.
using SendFn = std::function<int(const uint8_t* data, std::size_t bytes)>;
using RecvFn = std::function<int(uint8_t*       data, std::size_t bytes)>;

class Accelerator {
public:
    Accelerator(SendFn send, RecvFn recv, std::size_t batch_size = 16);

    // Enqueue a request. When the internal pending count reaches batch_size,
    // automatically flush(). Returns immediately otherwise.
    void submit(const Request& req);

    // Force any pending requests to be sent and their results collected.
    // Returns results in the order submit() was called. Clears the pending
    // queue. Calling flush() with no pending requests is a no-op and returns
    // an empty vector.
    std::vector<Result> flush();

    std::size_t pending_count() const { return pending_.size(); }
    std::size_t batch_size()    const { return batch_size_; }

    // ---- Pack / unpack are public for the loopback test ----
    // Writes REQ_BYTES bytes starting at `dst`. dst must be at least
    // REQ_BYTES bytes long.
    static void pack_request(const Request& req, uint8_t* dst);

    // Reads RES_BYTES bytes starting at `src`.
    static void unpack_result(const uint8_t* src, Result& out);

private:
    SendFn               send_;
    RecvFn               recv_;
    std::size_t          batch_size_;
    std::vector<Request> pending_;
};

}  // namespace bsw_fpga
