// bsw_axil_regs.sv  (board-bringup track)
// -----------------------------------------------------------------------------
// AXI4-Lite register-file wrapper around bsw_top, for AWS F1 minimal bring-up.
//
// The host (via the F1 Shell OCL/AppPF BAR) writes the query, target and config
// into buffers, pulses a GO bit, polls STATUS.done, then reads the result back.
// NO DDR4 / no PCIe DMA -- everything crosses the AXI4-Lite control port, so this
// is the smallest thing that runs bsw_top on real F1 silicon.
//
// This module is plain, portable SystemVerilog: it is Verilator-verifiable
// (tb_bsw_axil drives the AXI-Lite channels and checks the result bit-exact vs
// the same golden the bsw testbenches use) BEFORE it is ever dropped into the
// aws-fpga HDK CL wrapper (cl_bsw_top).
//
// Register map (byte offsets within the slave's address space):
//   0x000 CONTROL  W   bit0 = go (self-clearing pulse)
//   0x004 STATUS   R   bit0 busy, bit1 done, bit2 error
//   0x010.. CONFIG W   bsw_config_t, 5 x 32b words (LSW first)
//   0x100.. QUERY  W   160 bases x 3b = 480b -> 15 words
//   0x200.. TARGET W   1024 bases x 3b = 3072b -> 96 words
//   0x400.. RESULT R   bsw_result_t, 4 x 32b words (LSW first)
// -----------------------------------------------------------------------------
`include "bsw_pkg.sv"

module bsw_axil_regs
    import bsw_pkg::*;
#(
    parameter int ADDR_W = 16,   // slave address width (64 KiB window is ample)
    parameter int DATA_W = 32    // AXI4-Lite data width (F1 OCL is 32-bit)
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // ---- AXI4-Lite slave ----
    input  logic [ADDR_W-1:0]    s_awaddr,
    input  logic                 s_awvalid,
    output logic                 s_awready,
    input  logic [DATA_W-1:0]    s_wdata,
    input  logic [DATA_W/8-1:0]  s_wstrb,
    input  logic                 s_wvalid,
    output logic                 s_wready,
    output logic [1:0]           s_bresp,
    output logic                 s_bvalid,
    input  logic                 s_bready,
    input  logic [ADDR_W-1:0]    s_araddr,
    input  logic                 s_arvalid,
    output logic                 s_arready,
    output logic [DATA_W-1:0]    s_rdata,
    output logic [1:0]           s_rresp,
    output logic                 s_rvalid,
    input  logic                 s_rready
);
    // ---- buffer sizing ----
    localparam int QRY_BITS = MAX_QLEN * BASE_WIDTH;   // 160*3 = 480
    localparam int TGT_BITS = MAX_TLEN * BASE_WIDTH;   // 1024*3 = 3072
    localparam int CFG_BITS = $bits(bsw_config_t);     // 160
    localparam int RES_BITS = $bits(bsw_result_t);     // 97
    localparam int QRY_WORDS = (QRY_BITS + DATA_W-1)/DATA_W;  // 15
    localparam int TGT_WORDS = (TGT_BITS + DATA_W-1)/DATA_W;  // 96
    localparam int CFG_WORDS = (CFG_BITS + DATA_W-1)/DATA_W;  // 5
    localparam int RES_WORDS = (RES_BITS + DATA_W-1)/DATA_W;  // 4

    // Word-granular register storage (LSW-first) for the wide inputs.
    logic [DATA_W-1:0] qry_words [QRY_WORDS];
    logic [DATA_W-1:0] tgt_words [TGT_WORDS];
    logic [DATA_W-1:0] cfg_words [CFG_WORDS];

    // ---- address decode (word index within a region) ----
    // Region select by araddr/awaddr[15:8]; word index by [7:2].
    localparam logic [7:0] REG_CTRL = 8'h00;   // 0x0xx: control/status/config
    localparam logic [7:0] REG_QRY  = 8'h01;   // 0x1xx
    localparam logic [7:0] REG_TGT  = 8'h02;   // 0x2xx (+0x3xx overflow: use bit8)
    localparam logic [7:0] REG_RES  = 8'h04;   // 0x4xx

    // ---- write channel ----
    logic aw_hs, w_hs;
    logic [ADDR_W-1:0] awaddr_q;
    assign aw_hs = s_awvalid && s_awready;
    assign w_hs  = s_wvalid  && s_wready;

    // Simple two-step AXI-Lite write: accept AW, then W, then answer B.
    typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wst_t;
    wst_t wst;

    logic        go_pulse;   // 1-cycle start strobe to the engine
    // target word index for the 0x200..0x3FF region: (addr-0x200)/4 = addr[8:2]
    logic [6:0]  tgt_idx;
    assign tgt_idx = {awaddr_q[8], awaddr_q[7:2]};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0; s_bresp <= 2'b00;
            wst <= W_IDLE; awaddr_q <= '0; go_pulse <= 1'b0;
            for (int i = 0; i < QRY_WORDS; i++) qry_words[i] <= '0;
            for (int i = 0; i < TGT_WORDS; i++) tgt_words[i] <= '0;
            for (int i = 0; i < CFG_WORDS; i++) cfg_words[i] <= '0;
        end else begin
            go_pulse <= 1'b0;   // default: go is a single-cycle pulse
            unique case (wst)
                W_IDLE: begin
                    s_bvalid <= 1'b0;
                    s_awready <= 1'b1;
                    if (aw_hs) begin
                        awaddr_q  <= s_awaddr;
                        s_awready <= 1'b0;
                        s_wready  <= 1'b1;
                        wst       <= W_DATA;
                    end
                end
                W_DATA: if (w_hs) begin
                    s_wready <= 1'b0;
                    // ---- decode + store ----
                    unique case (awaddr_q[15:8])
                        REG_CTRL: begin
                            // 0x000 CONTROL(go); 0x010.. CONFIG word = (addr[7:2]-4)
                            if (awaddr_q[7:2] == 6'd0)
                                go_pulse <= s_wdata[0];
                            else if (awaddr_q[7:2] >= 6'd4 &&
                                     awaddr_q[7:2] <  6'd4 + CFG_WORDS)
                                cfg_words[awaddr_q[7:2] - 6'd4] <= s_wdata;
                        end
                        REG_QRY:  if (awaddr_q[7:2] < QRY_WORDS) qry_words[awaddr_q[7:2]] <= s_wdata;
                        REG_TGT,
                        (REG_TGT | 8'h01):   // 0x200..0x3FF
                            if (tgt_idx < TGT_WORDS) tgt_words[tgt_idx] <= s_wdata;
                        default: ; // ignore writes to RESULT / holes
                    endcase
                    s_bresp  <= 2'b00;   // OKAY
                    s_bvalid <= 1'b1;
                    wst      <= W_RESP;
                end
                W_RESP: if (s_bready) begin
                    s_bvalid <= 1'b0;
                    wst      <= W_IDLE;
                end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ---- assemble wide engine inputs from the word buffers ----
    logic [QRY_WORDS*DATA_W-1:0] qry_flat;
    logic [TGT_WORDS*DATA_W-1:0] tgt_flat;
    logic [CFG_WORDS*DATA_W-1:0] cfg_flat;
    always_comb begin
        for (int i = 0; i < QRY_WORDS; i++) qry_flat[i*DATA_W +: DATA_W] = qry_words[i];
        for (int i = 0; i < TGT_WORDS; i++) tgt_flat[i*DATA_W +: DATA_W] = tgt_words[i];
        for (int i = 0; i < CFG_WORDS; i++) cfg_flat[i*DATA_W +: DATA_W] = cfg_words[i];
    end

    base_t [MAX_QLEN-1:0] query_w;
    base_t [MAX_TLEN-1:0] target_w;
    bsw_config_t          cfg_w;
    logic                 error_bit;
    assign query_w  = qry_flat[QRY_BITS-1:0];
    assign target_w = tgt_flat[TGT_BITS-1:0];
    assign cfg_w    = cfg_flat[CFG_BITS-1:0];

    // ---- engine handshake ----
    // Latch a request on go_pulse; hold req_valid until bsw_top accepts it. Latch
    // the result on result_valid and raise done until the next go.
    logic         req_valid, req_ready;
    logic         result_valid;
    bsw_result_t  result_w, result_q;
    logic         busy, done;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_valid <= 1'b0; busy <= 1'b0; done <= 1'b0; result_q <= '0;
        end else begin
            if (go_pulse) begin
                req_valid <= 1'b1; busy <= 1'b1; done <= 1'b0;
            end else if (req_valid && req_ready) begin
                req_valid <= 1'b0;   // request accepted
            end
            if (busy && result_valid) begin
                result_q <= result_w; busy <= 1'b0; done <= 1'b1;
            end
        end
    end

    bsw_top u_bsw (
        .clk            (clk),
        .rst_n          (rst_n),
        .restart_mode   (1'b0),          // 0 = banded extension (bring-up default)
        .req_valid_i    (req_valid),
        .req_ready_o    (req_ready),
        .query_i        (query_w),
        .target_i       (target_w),
        .cfg_i          (cfg_w),
        .result_valid_o (result_valid),
        .result_ready_i (1'b1),          // always ready: we latch into result_q
        .result_o       (result_w)
    );

    // ---- read channel ----
    logic [RES_WORDS*DATA_W-1:0] res_flat;
    always_comb begin
        res_flat = '0;
        res_flat[RES_BITS-1:0] = result_q;
    end

    typedef enum logic [1:0] { R_IDLE, R_RESP } rst_e;
    rst_e rst_r;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s_arready <= 1'b0; s_rvalid <= 1'b0; s_rdata <= '0; s_rresp <= 2'b00;
            rst_r <= R_IDLE;
        end else begin
            unique case (rst_r)
                R_IDLE: begin
                    s_rvalid  <= 1'b0;
                    s_arready <= 1'b1;
                    if (s_arvalid && s_arready) begin
                        s_arready <= 1'b0;
                        // decode read
                        unique case (s_araddr[15:8])
                            REG_CTRL: s_rdata <= (s_araddr[7:2] == 6'd1)
                                                 ? {29'b0, error_bit, done, busy}  // 0x004 STATUS
                                                 : '0;
                            REG_RES:  s_rdata <= (s_araddr[7:2] < RES_WORDS)
                                                 ? res_flat[s_araddr[7:2]*DATA_W +: DATA_W] : '0;
                            default:  s_rdata <= '0;
                        endcase
                        s_rresp  <= 2'b00;
                        s_rvalid <= 1'b1;
                        rst_r    <= R_RESP;
                    end
                end
                R_RESP: if (s_rready) begin
                    s_rvalid <= 1'b0;
                    rst_r    <= R_IDLE;
                end
                default: rst_r <= R_IDLE;
            endcase
        end
    end

    assign error_bit = result_q.error;

endmodule
