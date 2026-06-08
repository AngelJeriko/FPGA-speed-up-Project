// host/loopback_test.cpp
// CPU-only self-checking test for bsw_fpga::Accelerator's pack/unpack.
//
// What this catches:
//   - Off-by-one / endianness bugs in the request header layout
//   - Wrong base nibble assignment in the query / target beats
//   - Result field decode bugs
//   - Tag round-trip
//   - Batched pack/unpack: N requests in -> N results out, in order
//
// What this does NOT catch:
//   - SV-side bugs (those are covered by tb_bsw_axis)
//   - Real DMA transport bugs (board-specific, not in scope)
//
// Build:
//   g++ -std=c++17 -O2 -Wall -Wextra -o loopback_test \
//       bsw_fpga.cpp loopback_test.cpp
// Run:
//   ./loopback_test
// Exit code 0 = PASS.

#include "bsw_fpga.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

namespace {

int g_checks = 0;
int g_errors = 0;

void check_eq(const char* name, long got, long expected) {
    ++g_checks;
    if (got != expected) {
        ++g_errors;
        std::printf("[FAIL] %-50s got=%ld expected=%ld\n", name, got, expected);
    } else {
        std::printf("[ OK ] %-50s = %ld\n", name, got);
    }
}

bsw_fpga::Request make_acgt_request(uint16_t tag) {
    using namespace bsw_fpga;
    Request r{};
    r.tag = tag;
    r.cfg.h0        = 1;
    r.cfg.o_del     = 6;
    r.cfg.e_del     = 1;
    r.cfg.o_ins     = 6;
    r.cfg.e_ins     = 1;
    r.cfg.zdrop     = 0;
    r.cfg.end_bonus = 0;
    r.cfg.w         = 64;
    r.cfg.qlen      = 4;
    r.cfg.tlen      = 4;
    // A C G T
    r.query[0]  = BASE_A; r.query[1]  = BASE_C; r.query[2]  = BASE_G; r.query[3]  = BASE_T;
    r.target[0] = BASE_A; r.target[1] = BASE_C; r.target[2] = BASE_G; r.target[3] = BASE_T;
    return r;
}

void test_header_layout() {
    using namespace bsw_fpga;
    Request r = make_acgt_request(0xCAFE);
    uint8_t buf[REQ_BYTES] = {};
    Accelerator::pack_request(r, buf);

    // Header byte map (mirrors bsw_axis_adapter.sv):
    //   00-01 tlen, 02-03 qlen, 04-05 w, 06-07 end_bonus, 08-09 zdrop,
    //   10-11 e_ins, 12-13 o_ins, 14-15 e_del, 16-17 o_del, 18-19 h0,
    //   20-21 tag
    check_eq("hdr.tlen",      buf[0] | (buf[1] << 8),    4);
    check_eq("hdr.qlen",      buf[2] | (buf[3] << 8),    4);
    check_eq("hdr.w",         buf[4] | (buf[5] << 8),   64);
    check_eq("hdr.end_bonus", buf[6] | (buf[7] << 8),    0);
    check_eq("hdr.zdrop",     buf[8] | (buf[9] << 8),    0);
    check_eq("hdr.e_ins",     buf[10] | (buf[11] << 8),  1);
    check_eq("hdr.o_ins",     buf[12] | (buf[13] << 8),  6);
    check_eq("hdr.e_del",     buf[14] | (buf[15] << 8),  1);
    check_eq("hdr.o_del",     buf[16] | (buf[17] << 8),  6);
    check_eq("hdr.h0",        buf[18] | (buf[19] << 8),  1);
    check_eq("hdr.tag",       buf[20] | (buf[21] << 8),  0xCAFE);
}

void test_base_nibbles() {
    using namespace bsw_fpga;
    Request r = make_acgt_request(0x0000);
    uint8_t buf[REQ_BYTES] = {};
    Accelerator::pack_request(r, buf);

    // Beat 1 starts at byte 32. Query "ACGT" => bases 0,1,2,3.
    //   byte 32 low  nibble = query[0] = 0 (A)
    //   byte 32 high nibble = query[1] = 1 (C)
    //   byte 33 low  nibble = query[2] = 2 (G)
    //   byte 33 high nibble = query[3] = 3 (T)
    const uint8_t qbyte0 = buf[AXIS_DATA_WIDTH_BYTES + 0];
    const uint8_t qbyte1 = buf[AXIS_DATA_WIDTH_BYTES + 1];
    check_eq("query nibble [0]", qbyte0 & 0x0F, BASE_A);
    check_eq("query nibble [1]", (qbyte0 >> 4) & 0x0F, BASE_C);
    check_eq("query nibble [2]", qbyte1 & 0x0F, BASE_G);
    check_eq("query nibble [3]", (qbyte1 >> 4) & 0x0F, BASE_T);

    // Beat 3 = first target beat = byte 32 * (1 + QRY_BEATS) = byte 96.
    const std::size_t tbeat0 = AXIS_DATA_WIDTH_BYTES * (1 + QRY_BEATS);
    const uint8_t tbyte0 = buf[tbeat0 + 0];
    const uint8_t tbyte1 = buf[tbeat0 + 1];
    check_eq("target nibble [0]", tbyte0 & 0x0F, BASE_A);
    check_eq("target nibble [1]", (tbyte0 >> 4) & 0x0F, BASE_C);
    check_eq("target nibble [2]", tbyte1 & 0x0F, BASE_G);
    check_eq("target nibble [3]", (tbyte1 >> 4) & 0x0F, BASE_T);
}

void test_result_unpack() {
    using namespace bsw_fpga;
    // Hand-craft a result beat the way the SV adapter would emit it:
    //   max_off=7, gtle=4, tle=4, qle=4, gscore=2, score=5, error=0, tag=0xCAFE
    uint8_t rx[RES_BYTES] = {};
    auto put16 = [&](int off, uint16_t v) {
        rx[off]     = static_cast<uint8_t>(v & 0xFF);
        rx[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
    };
    put16(0,  7);          // max_off
    put16(2,  4);          // gtle
    put16(4,  4);          // tle
    put16(6,  4);          // qle
    put16(8,  2);          // gscore
    put16(10, 5);          // score
    rx[12]    = 0x00;      // error=0 in bit 0
    put16(14, 0xCAFE);     // tag

    Result out{};
    Accelerator::unpack_result(rx, out);
    check_eq("unpack.score",   out.score,   5);
    check_eq("unpack.gscore",  out.gscore,  2);
    check_eq("unpack.qle",     out.qle,     4);
    check_eq("unpack.tle",     out.tle,     4);
    check_eq("unpack.gtle",    out.gtle,    4);
    check_eq("unpack.max_off", out.max_off, 7);
    check_eq("unpack.error",   out.error ? 1 : 0, 0);
    check_eq("unpack.tag",     out.tag,     0xCAFE);

    // Sign-extension check: a negative-encoded score
    put16(10, static_cast<uint16_t>(-3));
    Accelerator::unpack_result(rx, out);
    check_eq("unpack.score (negative)", out.score, -3);

    // Error bit
    rx[12] = 0x01;
    Accelerator::unpack_result(rx, out);
    check_eq("unpack.error (set)", out.error ? 1 : 0, 1);
}

void test_batched_flush() {
    using namespace bsw_fpga;

    // Loopback driver: capture sent buffer, hand-craft a result stream that
    // echoes each request's tag back with score = (cfg.qlen * 10).
    std::vector<uint8_t> captured;
    std::vector<uint8_t> response;

    auto fake_send = [&](const uint8_t* data, std::size_t bytes) {
        captured.assign(data, data + bytes);
        const std::size_t n_req = bytes / REQ_BYTES;
        response.assign(RES_BYTES * n_req, 0);
        for (std::size_t i = 0; i < n_req; ++i) {
            const uint8_t* hdr = captured.data() + i * REQ_BYTES;
            const uint16_t qlen = static_cast<uint16_t>(hdr[2] | (hdr[3] << 8));
            const uint16_t tag  = static_cast<uint16_t>(hdr[20] | (hdr[21] << 8));
            uint8_t* dst = response.data() + i * RES_BYTES;
            auto put16 = [&](int off, uint16_t v) {
                dst[off]     = static_cast<uint8_t>(v & 0xFF);
                dst[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
            };
            put16(10, static_cast<uint16_t>(qlen * 10));  // score
            put16(14, tag);                               // tag echo
        }
        return 0;
    };

    auto fake_recv = [&](uint8_t* data, std::size_t bytes) {
        if (bytes != response.size()) return 1;
        std::memcpy(data, response.data(), bytes);
        return 0;
    };

    Accelerator acc(fake_send, fake_recv, /*batch_size=*/4);
    Request a = make_acgt_request(0x0001);
    Request b = make_acgt_request(0x0002); b.cfg.qlen = 8;
    Request c = make_acgt_request(0x0003); c.cfg.qlen = 16;
    acc.submit(a);
    acc.submit(b);
    acc.submit(c);
    check_eq("pending count before flush", static_cast<long>(acc.pending_count()), 3);

    std::vector<Result> r = acc.flush();
    check_eq("flush returns 3 results", static_cast<long>(r.size()), 3);
    check_eq("pending count after flush", static_cast<long>(acc.pending_count()), 0);
    check_eq("batch[0].tag",   r[0].tag,    0x0001);
    check_eq("batch[0].score", r[0].score,  40);   // qlen=4 * 10
    check_eq("batch[1].tag",   r[1].tag,    0x0002);
    check_eq("batch[1].score", r[1].score,  80);
    check_eq("batch[2].tag",   r[2].tag,    0x0003);
    check_eq("batch[2].score", r[2].score,  160);

    check_eq("empty flush is no-op", static_cast<long>(acc.flush().size()), 0);
}

}  // namespace

int main() {
    std::printf("==== loopback_test starting ====\n");
    test_header_layout();
    test_base_nibbles();
    test_result_unpack();
    test_batched_flush();
    std::printf("==== loopback_test done: %d checks, %d errors ====\n",
                g_checks, g_errors);
    std::printf("%s\n", g_errors == 0 ? "PASS" : "FAIL");
    return g_errors == 0 ? 0 : 1;
}
