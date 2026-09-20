// bsw_kernel_cdc.sv
// -----------------------------------------------------------------------------
// Runs bsw_top in a SECOND clock domain, behind a clock-domain crossing, while
// presenting bsw_top's OWN interface to the caller.
//
// WHY THIS EXISTS
// On AWS F1 we chose the clock to suit the design: clk_main_a0 at 125 MHz (recipe A0).
// On F2 that choice is gone — clk_main_a0 is FIXED at 250 MHz and every Shell<->CL
// interface is synchronous to it. If bsw_top does not close 250 MHz on VU47P, the fix
// is to keep the AXI-Lite front end on clk_main_a0 and run only the kernel slower, on
// AWS_CLK_GEN's clk_extra_a1 (125 MHz on clock recipe A1). This module is that split.
//
// It is a DROP-IN REPLACEMENT for bsw_top: same ports, same handshake semantics, plus
// a second clock/reset pair. bsw_axil_regs picks between the two with its KERNEL_CDC
// parameter, so the single-clock path stays bit-identical to what F1 shipped.
// Whether we need it is decided by synth/ooc/impl_bsw_top_vu47p.tcl.
//
// ------------------------------- HOW IT CROSSES -------------------------------
// A two-phase (toggle) request/acknowledge handshake with quasi-static payload — the
// standard structure when the data is wide and the events are rare. Here the payload is
// 480b of query + 3072b of target + config: far too wide for an async FIFO to be worth
// it, and it only changes once per request.
//
//   A-domain (clk, 250 MHz)                    K-domain (clk_k, 125 MHz)
//   ----------------------------               ----------------------------
//   latch payload into *_hold      ──payload──▶ read directly by bsw_top
//   next cycle: req_tgl ^= 1       ──toggle──▶ 2FF sync + edge detect ─▶ run bsw_top
//   2FF sync + edge detect  ◀──toggle──         ack_tgl ^= 1 once result is latched
//   capture result_k_q      ◀──result───        result_k_q held until the next request
//
// WHY THE PAYLOAD MAY CROSS UNSYNCHRONISED. It is stable for the entire window in which
// the far side can look at it:
//   * The payload registers are written one FULL CYCLE BEFORE req_tgl flips (state
//     A_SEND exists only to create that separation). The toggle then takes at least two
//     clk_k edges to emerge from the synchroniser, so by the time the K side can act on
//     it the payload has been quiet for ≥1 clk + 2 clk_k.
//   * It cannot be rewritten until the A side is back in A_IDLE, which requires the
//     acknowledge to have made the return trip.
// The same argument runs in reverse for result_k_q: written the cycle before ack_tgl
// flips, held until the next request is accepted.
// Only the two toggles are true asynchronous inputs, and each goes through its own 2FF
// synchroniser. The payload/result paths still need a timing constraint so the tools do
// not try to close them as if they were synchronous — see the accompanying
// scripts/f2/cl_timing_user_cdc.xdc (set_max_delay -datapath_only).
//
// ROBUSTNESS. In steady state the A side never issues a request while the K side is
// busy, so neither edge can be missed. The pending flags (req_pend_k / ack_pend_a)
// exist anyway to cover reset skew: the two domains leave reset at different times, and
// a toggle that flips while the far side's synchroniser is still reset would otherwise
// be lost, deadlocking the handshake. They make a missed edge impossible rather than
// merely improbable.
// -----------------------------------------------------------------------------
`include "bsw_pkg.sv"

module bsw_kernel_cdc
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    // ---- A domain: the caller's clock (clk_main_a0 on F2) ----
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- K domain: the kernel clock (clk_extra_a1 on F2) ----
    input  logic                       clk_k,
    input  logic                       rst_k_n,

    // ---- bsw_top's interface, presented in the A domain ----
    input  logic                       restart_mode,
    input  logic                       req_valid_i,
    output logic                       req_ready_o,
    input  base_t [MAX_QLEN-1:0]       query_i,
    input  base_t [MAX_TLEN-1:0]       target_i,
    input  bsw_config_t                cfg_i,
    output logic                       result_valid_o,
    input  logic                       result_ready_i,
    output bsw_result_t                result_o
);

    // =========================================================================
    // A domain
    // =========================================================================
    typedef enum logic [1:0] { A_IDLE, A_SEND, A_WAIT, A_DONE } a_state_e;
    a_state_e a_state;

    base_t [MAX_QLEN-1:0] query_hold;
    base_t [MAX_TLEN-1:0] target_hold;
    bsw_config_t          cfg_hold;
    logic                 restart_hold;
    bsw_result_t          result_hold;
    logic                 req_tgl;

    // K->A acknowledge toggle, synchronised into the A domain.
    // ASYNC_REG keeps the pair placed together so the MTBF budget is real.
    (* ASYNC_REG = "TRUE" *) logic ack_sync0, ack_sync1;
    logic ack_sync2, ack_pend_a;
    wire  ack_edge_a = ack_sync1 ^ ack_sync2;

    // K-domain signals read from the A domain (quasi-static; constrained in XDC).
    logic        ack_tgl_k;
    bsw_result_t result_k_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {ack_sync0, ack_sync1, ack_sync2} <= 3'b000;
        end else begin
            ack_sync0 <= ack_tgl_k;
            ack_sync1 <= ack_sync0;
            ack_sync2 <= ack_sync1;
        end
    end

    assign req_ready_o    = (a_state == A_IDLE);
    assign result_valid_o = (a_state == A_DONE);
    assign result_o       = result_hold;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_state      <= A_IDLE;
            req_tgl      <= 1'b0;
            ack_pend_a   <= 1'b0;
            query_hold   <= '0;
            target_hold  <= '0;
            cfg_hold     <= '0;
            restart_hold <= 1'b0;
            result_hold  <= '0;
        end else begin
            // Latch an acknowledge whenever it arrives, even outside A_WAIT.
            if (ack_edge_a) ack_pend_a <= 1'b1;

            case (a_state)
                A_IDLE: if (req_valid_i) begin
                    query_hold   <= query_i;
                    target_hold  <= target_i;
                    cfg_hold     <= cfg_i;
                    restart_hold <= restart_mode;
                    a_state      <= A_SEND;
                end

                // One cycle of separation: the payload is already registered and quiet
                // before the toggle that lets the far side look at it.
                A_SEND: begin
                    req_tgl <= ~req_tgl;
                    a_state <= A_WAIT;
                end

                A_WAIT: if (ack_pend_a) begin
                    result_hold <= result_k_q;   // stable: written before ack toggled
                    ack_pend_a  <= 1'b0;
                    a_state     <= A_DONE;
                end

                A_DONE: if (result_ready_i) a_state <= A_IDLE;

                default: a_state <= A_IDLE;
            endcase
        end
    end

    // =========================================================================
    // K domain
    // =========================================================================
    typedef enum logic [1:0] { K_IDLE, K_REQ, K_RUN } k_state_e;
    k_state_e k_state;

    (* ASYNC_REG = "TRUE" *) logic req_sync0, req_sync1;
    logic req_sync2, req_pend_k;
    wire  req_edge_k = req_sync1 ^ req_sync2;

    logic        k_req_valid, k_req_ready;
    logic        k_result_valid;
    bsw_result_t k_result;

    always_ff @(posedge clk_k) begin
        if (!rst_k_n) begin
            {req_sync0, req_sync1, req_sync2} <= 3'b000;
        end else begin
            req_sync0 <= req_tgl;
            req_sync1 <= req_sync0;
            req_sync2 <= req_sync1;
        end
    end

    always_ff @(posedge clk_k) begin
        if (!rst_k_n) begin
            k_state     <= K_IDLE;
            k_req_valid <= 1'b0;
            req_pend_k  <= 1'b0;
            ack_tgl_k   <= 1'b0;
            result_k_q  <= '0;
        end else begin
            if (req_edge_k) req_pend_k <= 1'b1;

            case (k_state)
                K_IDLE: if (req_pend_k) begin
                    req_pend_k  <= 1'b0;
                    k_req_valid <= 1'b1;
                    k_state     <= K_REQ;
                end

                K_REQ: if (k_req_ready) begin
                    k_req_valid <= 1'b0;
                    k_state     <= K_RUN;
                end

                K_RUN: if (k_result_valid) begin
                    result_k_q <= k_result;
                    ack_tgl_k  <= ~ack_tgl_k;   // flips the cycle AFTER the data lands
                    k_state    <= K_IDLE;
                end

                default: k_state <= K_IDLE;
            endcase
        end
    end

    // The kernel itself, entirely in the K domain. Its payload comes straight from the
    // A-domain hold registers, which are quiet across the whole window it can see them.
    bsw_top #(.N_PE(N_PE)) u_bsw (
        .clk            (clk_k),
        .rst_n          (rst_k_n),
        .restart_mode   (restart_hold),
        .req_valid_i    (k_req_valid),
        .req_ready_o    (k_req_ready),
        .query_i        (query_hold),
        .target_i       (target_hold),
        .cfg_i          (cfg_hold),
        .result_valid_o (k_result_valid),
        .result_ready_i (1'b1),          // we latch into result_k_q
        .result_o       (k_result)
    );

endmodule
