// host/bsw_fpga.cpp
// Implementation of the BWA-MEM2 FPGA accelerator host-side shim.
// Wire-format constants and bit positions are defined in lockstep with
// rtl/bsw_axis_adapter.sv — see that file for the authoritative layout.

#include "bsw_fpga.h"

#include <cstring>
#include <stdexcept>

namespace bsw_fpga {

namespace {

inline void write16_le(uint8_t* dst, uint16_t v) {
    dst[0] = static_cast<uint8_t>(v & 0xFF);
    dst[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
}

inline uint16_t read16_le(const uint8_t* src) {
    return static_cast<uint16_t>(src[0]) |
           (static_cast<uint16_t>(src[1]) << 8);
}

// Pack `count` bases into `n_beats` AXIS beats starting at `dst`. Each base
// occupies one nibble (low nibble of byte k/2 = base 2k, high nibble = base
// 2k+1). Bases past `count` are zero-padded.
void pack_bases(uint8_t* dst, const uint8_t* bases, int count, int n_beats) {
    const int beat_bytes = AXIS_DATA_WIDTH_BYTES;
    std::memset(dst, 0, static_cast<std::size_t>(beat_bytes) * n_beats);
    for (int beat = 0; beat < n_beats; ++beat) {
        uint8_t* p = dst + beat * beat_bytes;
        for (int k = 0; k < BASES_PER_BEAT; ++k) {
            const int idx = beat * BASES_PER_BEAT + k;
            if (idx >= count) break;
            const uint8_t b = bases[idx] & 0x0F;
            if ((k & 1) == 0) p[k >> 1] |= b;
            else              p[k >> 1] |= static_cast<uint8_t>(b << 4);
        }
    }
}

}  // namespace

void Accelerator::pack_request(const Request& req, uint8_t* dst) {
    std::memset(dst, 0, REQ_BYTES);

    // ---- Beat 0: header. cfg packs LSB-first to match the SV packed struct
    // (last struct field == LSB of struct value). Order below is reverse of
    // the field declaration order in bsw_pkg.sv :: bsw_config_t.
    uint8_t* hdr = dst;
    write16_le(hdr +  0, static_cast<uint16_t>(req.cfg.tlen));
    write16_le(hdr +  2, static_cast<uint16_t>(req.cfg.qlen));
    write16_le(hdr +  4, static_cast<uint16_t>(req.cfg.w));
    write16_le(hdr +  6, static_cast<uint16_t>(req.cfg.end_bonus));
    write16_le(hdr +  8, static_cast<uint16_t>(req.cfg.zdrop));
    write16_le(hdr + 10, static_cast<uint16_t>(req.cfg.e_ins));
    write16_le(hdr + 12, static_cast<uint16_t>(req.cfg.o_ins));
    write16_le(hdr + 14, static_cast<uint16_t>(req.cfg.e_del));
    write16_le(hdr + 16, static_cast<uint16_t>(req.cfg.o_del));
    write16_le(hdr + 18, static_cast<uint16_t>(req.cfg.h0));
    // bytes 20..21 = tag (byte-aligned at bit 160)
    write16_le(hdr + 20, req.tag);
    // bytes 22..31 already zero from memset.

    // ---- Beats 1..QRY_BEATS: query bases.
    pack_bases(dst + AXIS_DATA_WIDTH_BYTES,
               req.query, MAX_QLEN, QRY_BEATS);

    // ---- Beats (1+QRY_BEATS)..(1+QRY_BEATS+TGT_BEATS-1): target bases.
    pack_bases(dst + AXIS_DATA_WIDTH_BYTES * (1 + QRY_BEATS),
               req.target, MAX_TLEN, TGT_BEATS);
}

void Accelerator::unpack_result(const uint8_t* src, Result& out) {
    // Result occupies low 97 bits; layout mirrors the SV bsw_result_t packed
    // struct (max_off at LSB, error at bit 96).
    out.max_off = read16_le(src + 0);
    out.gtle    = read16_le(src + 2);
    out.tle     = read16_le(src + 4);
    out.qle     = read16_le(src + 6);
    out.gscore  = static_cast<int16_t>(read16_le(src + 8));
    out.score   = static_cast<int16_t>(read16_le(src + 10));
    out.error   = (src[12] & 0x01) != 0;
    // bits[111:97] reserved -> skip
    out.tag     = read16_le(src + 14);
    // bytes 16..31 reserved
}

Accelerator::Accelerator(SendFn send, RecvFn recv, std::size_t batch_size)
    : send_(std::move(send)),
      recv_(std::move(recv)),
      batch_size_(batch_size == 0 ? 1 : batch_size) {
    pending_.reserve(batch_size_);
}

void Accelerator::submit(const Request& req) {
    if (req.cfg.qlen > MAX_QLEN || req.cfg.tlen > MAX_TLEN) {
        throw std::invalid_argument(
            "bsw_fpga::Accelerator::submit: qlen/tlen exceeds MAX_QLEN/MAX_TLEN");
    }
    pending_.push_back(req);
    if (pending_.size() >= batch_size_) {
        // Auto-flush on full batch. Caller still owns the returned results
        // via the next explicit flush() — drop them here, since auto-flush
        // is a back-pressure signal not a request for results. Most callers
        // will use explicit flush() instead.
        (void)flush();
    }
}

std::vector<Result> Accelerator::flush() {
    std::vector<Result> results;
    if (pending_.empty()) return results;

    const std::size_t n = pending_.size();
    std::vector<uint8_t> tx(REQ_BYTES * n);
    for (std::size_t i = 0; i < n; ++i) {
        pack_request(pending_[i], tx.data() + i * REQ_BYTES);
    }

    if (int rc = send_(tx.data(), tx.size()); rc != 0) {
        throw std::runtime_error("bsw_fpga: driver send failed");
    }

    std::vector<uint8_t> rx(RES_BYTES * n);
    if (int rc = recv_(rx.data(), rx.size()); rc != 0) {
        throw std::runtime_error("bsw_fpga: driver recv failed");
    }

    results.resize(n);
    for (std::size_t i = 0; i < n; ++i) {
        unpack_result(rx.data() + i * RES_BYTES, results[i]);
    }
    pending_.clear();
    return results;
}

}  // namespace bsw_fpga
