// bsw_axis_adapter.sv
// AXI-Stream wrapper around bsw_top.
//
// Wire format (256-bit AXIS data, little-endian byte order on the wire):
//
//   Request: 7 beats per alignment, tlast on beat 6.
//     Beat 0 (HEADER):
//       bits[159:  0] = bsw_config_t (LSB-first: tlen at [15:0], ..., h0 at [159:144])
//       bits[175:160] = tag (16 bits, byte-aligned at byte 20)
//       bits[255:176] = reserved (0)
//     Beats 1-2 (QUERY): one base per nibble, 64 bases per beat.
//       beat 1: query[0..63], beat 2: query[64..127]
//       bits[k*4 +: 4] = base k of this slice (low nibble = even index)
//     Beats 3-6 (TARGET): one base per nibble, 64 bases per beat.
//       beat 3: target[0..63], ..., beat 6: target[192..255]
//
//   Result: 1 beat per alignment, tlast=1.
//     bits[ 96:  0] = bsw_result_t (LSB-first: max_off at [15:0], ..., error at [96])
//     bits[111: 97] = reserved (0)
//     bits[127:112] = tag (16 bits, byte-aligned at byte 14)
//     bits[255:128] = reserved (0)
//
// Tag is opaque to the adapter — round-tripped from request to result so the
// host can correlate a batched result back to its issuing request.
//
// Backpressure: standard AXI-Stream. s_axis_tready asserts only while the FSM
// is in an RX state; m_axis_tvalid asserts only while in TX_RES. A request
// must be fully streamed in (HDR + 2 QRY + 4 TGT) before the next can start,
// and the result must be drained before the next request will be accepted.
// Adding a deeper request FIFO at the front (item B+ in docs/speedup_plan.md)
// lets the host issue a burst without back-pressure between beats.

`include "bsw_pkg.sv"

module bsw_axis_adapter
    import bsw_pkg::*;
#(
    parameter int AXIS_DATA_WIDTH = 256,
    parameter int TAG_WIDTH       = 16,
    parameter int N_PE            = BAND_WIDTH
)(
    input  logic                            clk,
    input  logic                            rst_n,

    // Slave AXIS: host -> FPGA (serialized request stream)
    input  logic                            s_axis_tvalid,
    output logic                            s_axis_tready,
    input  logic [AXIS_DATA_WIDTH-1:0]      s_axis_tdata,
    input  logic                            s_axis_tlast,

    // Master AXIS: FPGA -> host (serialized result stream)
    output logic                            m_axis_tvalid,
    input  logic                            m_axis_tready,
    output logic [AXIS_DATA_WIDTH-1:0]      m_axis_tdata,
    output logic                            m_axis_tlast
);

    // ---- Sizing ----
    localparam int CFG_BITS       = $bits(bsw_config_t);     // 160
    localparam int RES_BITS       = $bits(bsw_result_t);     //  97
    localparam int BASES_PER_BEAT = AXIS_DATA_WIDTH / 4;     //  64 @ 256b
    localparam int QRY_BEATS      = (MAX_QLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT;  // 2
    localparam int TGT_BEATS      = (MAX_TLEN + BASES_PER_BEAT - 1) / BASES_PER_BEAT;  // 4

    // Generous fixed-width beat counter (max(QRY_BEATS, TGT_BEATS) fits in 8b
    // for any reasonable MAX_QLEN/MAX_TLEN).
    localparam int BEAT_W = 8;

    // ---- Buffers ----
    bsw_config_t                cfg_buf;
    logic [TAG_WIDTH-1:0]       tag_buf;
    base_t [MAX_QLEN-1:0]       query_buf;
    base_t [MAX_TLEN-1:0]       target_buf;

    bsw_result_t                result_lat;

    // ---- bsw_top handshake ----
    logic                       req_valid_int, req_ready_int;
    logic                       res_valid_int, res_ready_int;
    bsw_result_t                result_int;

    // ---- FSM ----
    typedef enum logic [2:0] {
        S_RX_HDR    = 3'd0,
        S_RX_QRY    = 3'd1,
        S_RX_TGT    = 3'd2,
        S_SUBMIT    = 3'd3,
        S_WAIT_RES  = 3'd4,
        S_TX_RES    = 3'd5
    } state_e;

    state_e state, state_n;
    logic [BEAT_W-1:0] beat_cnt, beat_cnt_n;

    wire rx_fire = s_axis_tvalid && s_axis_tready;
    wire tx_fire = m_axis_tvalid && m_axis_tready;

    // ---- Handshake glue ----
    assign s_axis_tready = (state == S_RX_HDR) ||
                           (state == S_RX_QRY) ||
                           (state == S_RX_TGT);

    assign req_valid_int = (state == S_SUBMIT);
    assign res_ready_int = (state == S_WAIT_RES);

    // ---- TX result beat assembly ----
    logic [AXIS_DATA_WIDTH-1:0] tx_beat;
    always_comb begin
        tx_beat = '0;
        tx_beat[RES_BITS-1:0]               = result_lat;
        tx_beat[127:112]                    = tag_buf;
    end

    assign m_axis_tvalid = (state == S_TX_RES);
    assign m_axis_tdata  = tx_beat;
    assign m_axis_tlast  = (state == S_TX_RES);

    // ---- State transitions ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_RX_HDR;
            beat_cnt <= '0;
        end else begin
            state    <= state_n;
            beat_cnt <= beat_cnt_n;
        end
    end

    always_comb begin
        state_n    = state;
        beat_cnt_n = beat_cnt;
        unique case (state)
            S_RX_HDR: begin
                if (rx_fire) begin
                    state_n    = S_RX_QRY;
                    beat_cnt_n = '0;
                end
            end
            S_RX_QRY: begin
                if (rx_fire) begin
                    if (beat_cnt == BEAT_W'(QRY_BEATS - 1)) begin
                        state_n    = S_RX_TGT;
                        beat_cnt_n = '0;
                    end else begin
                        beat_cnt_n = beat_cnt + BEAT_W'(1);
                    end
                end
            end
            S_RX_TGT: begin
                if (rx_fire) begin
                    if (beat_cnt == BEAT_W'(TGT_BEATS - 1)) begin
                        state_n    = S_SUBMIT;
                        beat_cnt_n = '0;
                    end else begin
                        beat_cnt_n = beat_cnt + BEAT_W'(1);
                    end
                end
            end
            S_SUBMIT: begin
                if (req_valid_int && req_ready_int) state_n = S_WAIT_RES;
            end
            S_WAIT_RES: begin
                if (res_valid_int && res_ready_int) state_n = S_TX_RES;
            end
            S_TX_RES: begin
                if (tx_fire) state_n = S_RX_HDR;
            end
            default: state_n = S_RX_HDR;
        endcase
    end

    // ---- RX capture ----
    always_ff @(posedge clk) begin
        if (rx_fire) begin
            unique case (state)
                S_RX_HDR: begin
                    cfg_buf <= s_axis_tdata[CFG_BITS-1:0];
                    tag_buf <= s_axis_tdata[CFG_BITS+TAG_WIDTH-1 -: TAG_WIDTH];
                end
                S_RX_QRY: begin
                    for (int k = 0; k < BASES_PER_BEAT; k++) begin
                        automatic int idx = int'(beat_cnt) * BASES_PER_BEAT + k;
                        if (idx < MAX_QLEN) begin
                            query_buf[idx] <= s_axis_tdata[k*4 +: BASE_WIDTH];
                        end
                    end
                end
                S_RX_TGT: begin
                    for (int k = 0; k < BASES_PER_BEAT; k++) begin
                        automatic int idx = int'(beat_cnt) * BASES_PER_BEAT + k;
                        if (idx < MAX_TLEN) begin
                            target_buf[idx] <= s_axis_tdata[k*4 +: BASE_WIDTH];
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // ---- Result latch ----
    always_ff @(posedge clk) begin
        if (!rst_n)
            result_lat <= '0;
        else if (res_valid_int && res_ready_int)
            result_lat <= result_int;
    end

    // ---- DUT instance ----
    bsw_top #(.N_PE(N_PE)) u_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid_i    (req_valid_int),
        .req_ready_o    (req_ready_int),
        .query_i        (query_buf),
        .target_i       (target_buf),
        .cfg_i          (cfg_buf),
        .result_valid_o (res_valid_int),
        .result_ready_i (res_ready_int),
        .result_o       (result_int)
    );

endmodule
