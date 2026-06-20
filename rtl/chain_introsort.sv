// chain_introsort.sv — klib ks_introsort(mem_flt) (ksort.h) for one read's chain array,
// sorting by weight DESCENDING (comparator flt_lt(x,y) = x.w > y.w). Mirrors
// host/chaining/chain.h::ks_introsort_memflt control flow EXACTLY so the UNSTABLE
// equal-weight tie order is bit-exact (a stable sorter — e.g. the merge-sorter — would
// NOT reproduce it; that was the original real-data chaining divergence).
//
// Each element is a (w, id) pair: w = sort key, id = original index (the payload tag the
// TB checks to pin down tie order). In chain_flt this carries the full chain record; here
// id stands in for "which chain", which is all the comparator-invariant reordering needs.
//
// Algorithm = median-of-3 quicksort (of {first,last,mid+1}) down to >16-size segments via
// an explicit segment stack, then ONE whole-array insertion sort. The depth limit is
// d = 2*ceil(log2 n); if quicksort ever hits it, the C runs COMBSORT, whose gap update is a
// floating-point divide we can't reproduce bit-exact in HW -> we raise `fallback` (host SW
// redo) instead. That path needs median-of-3-adversarial input, so it ~never fires for
// chain-count-sized arrays (cf. dup-pos / capacity SW-fallbacks elsewhere).
module chain_introsort #(parameter int NMAX = 512, parameter int STACKD = 48) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- element load (idx 0..n_in-1) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [31:0] ld_w,
    input  logic [15:0]        ld_id,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic               fallback,     // depth-limit hit (combsort) -> host SW redo
    output logic [15:0]        n_out,

    // ---- sorted readback ----
    input  logic [15:0]        rd_idx,
    output logic signed [31:0] o_w,
    output logic [15:0]        o_id
);
    // ---- the array being sorted in place ----
    logic signed [31:0] aw [NMAX];
    logic [15:0]        aid[NMAX];
    always_ff @(posedge clk) if (ld_en && ld_idx < NMAX[15:0]) begin
        aw[ld_idx]<=ld_w; aid[ld_idx]<=ld_id;
    end
    logic [15:0] n;
    assign n_out = n;
    assign o_w   = aw [rd_idx];
    assign o_id  = aid[rd_idx];

    // ---- segment stack ----
    logic signed [31:0] stL[STACKD], stR[STACKD];
    logic [7:0]         stD[STACKD];
    logic [7:0]         sp;

    // ---- working registers (signed indices; pointers in the C) ----
    logic signed [31:0] s, t, i, j, k, mid, ls, rs, ni, nj;
    logic [7:0]         d, dlc;
    logic signed [31:0] rp_w; logic [15:0] rp_id;

    typedef enum logic [4:0] {
        A_IDLE, A_DEPTH, A_DISP, A_N2, A_LOOP, A_DECD, A_MED, A_PIV,
        A_PI, A_PJ, A_PCHK, A_PSWAP, A_PFIN, A_TAIL, A_POP,
        A_ISO_O, A_ISO_I, A_DONE
    } st_t;
    st_t state;
    assign busy = (state != A_IDLE);

    // combinational helpers
    always_comb begin
        mid = s + ((t - s) >> 1) + 1;
        ni  = i + 32'sd1;
        nj  = j - 32'sd1;
        ls  = i - s;          // left half size = i-s
        rs  = t - i;          // right half size = t-i
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=A_IDLE; done<=1'b0; fallback<=1'b0;
        end else begin
            done<=1'b0;
            case (state)
                A_IDLE: if (start) begin
                    n<=n_in; fallback<=1'b0; dlc<=8'd2; state<=A_DEPTH;
                end

                // depth limit d = 2*ceil(log2 n): grow dlc until (1<<dlc) >= n
                A_DEPTH: begin
                    if ((32'sd1 <<< dlc) < $signed({16'd0,n})) dlc<=dlc+8'd1;
                    else begin d <= dlc << 1; state<=A_DISP; end
                end

                // dispatch the C's early cases
                A_DISP: begin
                    if (n <= 16'd1)      state<=A_DONE;           // 0/1 elements: as-is
                    else if (n == 16'd2) state<=A_N2;
                    else begin s<=32'sd0; t<=$signed({16'd0,n})-32'sd1; sp<=8'd0; state<=A_LOOP; end
                end

                A_N2: begin
                    if (aw[1] > aw[0]) begin
                        aw[0]<=aw[1]; aw[1]<=aw[0]; aid[0]<=aid[1]; aid[1]<=aid[0];
                    end
                    state<=A_DONE;
                end

                // while(1) head
                A_LOOP: begin
                    if (s < t) state<=A_DECD;
                    else if (sp == 8'd0) begin i<=32'sd1; state<=A_ISO_O; end  // -> final insertion sort
                    else state<=A_POP;
                end

                // if(--d==0) combsort(=fallback); else partition
                A_DECD: begin
                    if (d == 8'd1) begin fallback<=1'b1; state<=A_DONE; end
                    else begin d<=d-8'd1; state<=A_MED; end
                end

                // median-of-3 of {a[s], a[t], a[mid]} -> k; set i=s, j=t
                A_MED: begin
                    i<=s; j<=t;
                    if (aw[mid] > aw[s]) k <= (aw[mid] > aw[t]) ? t : mid;
                    else                 k <= (aw[t]   > aw[s]) ? s : t;
                    state<=A_PIV;
                end

                // rp = a[k]; move pivot to t
                A_PIV: begin
                    rp_w<=aw[k]; rp_id<=aid[k];
                    if (k != t) begin
                        aw[k]<=aw[t]; aw[t]<=aw[k]; aid[k]<=aid[t]; aid[t]<=aid[k];
                    end
                    state<=A_PI;
                end

                // do ++i while(a[i].w > rp.w)
                A_PI: begin
                    i<=ni;
                    if (aw[ni] > rp_w) state<=A_PI;
                    else state<=A_PJ;
                end

                // do --j while(i<=j && rp.w > a[j].w)
                A_PJ: begin
                    j<=nj;
                    if ((i <= nj) && (rp_w > aw[nj])) state<=A_PJ;
                    else state<=A_PCHK;
                end

                A_PCHK: if (j <= i) state<=A_PFIN; else state<=A_PSWAP;

                A_PSWAP: begin                              // swap a[i],a[j]; loop
                    aw[i]<=aw[j]; aw[j]<=aw[i]; aid[i]<=aid[j]; aid[j]<=aid[i];
                    state<=A_PI;
                end

                A_PFIN: begin                               // swap a[i],a[t] (pivot to i)
                    aw[i]<=aw[t]; aw[t]<=aw[i]; aid[i]<=aid[t]; aid[t]<=aid[i];
                    state<=A_TAIL;
                end

                // iterative tail recursion: push larger half (if >16), continue on the other
                A_TAIL: begin
                    if (ls > rs) begin
                        if (ls > 32'sd16) begin
                            stL[sp]<=s; stR[sp]<=i-32'sd1; stD[sp]<=d; sp<=sp+8'd1;
                        end
                        s <= (rs > 32'sd16) ? (i+32'sd1) : t;
                    end else begin
                        if (rs > 32'sd16) begin
                            stL[sp]<=i+32'sd1; stR[sp]<=t; stD[sp]<=d; sp<=sp+8'd1;
                        end
                        t <= (ls > 32'sd16) ? (i-32'sd1) : s;
                    end
                    state<=A_LOOP;
                end

                A_POP: begin
                    s<=stL[sp-8'd1]; t<=stR[sp-8'd1]; d<=stD[sp-8'd1]; sp<=sp-8'd1;
                    state<=A_LOOP;
                end

                // ---- final whole-array insertion sort: for i=1..n-1, bubble a[j] down ----
                A_ISO_O: begin
                    if (i >= $signed({16'd0,n})) state<=A_DONE;
                    else begin j<=i; state<=A_ISO_I; end
                end
                A_ISO_I: begin
                    if (j > 32'sd0 && (aw[j] > aw[j-32'sd1])) begin
                        aw[j]<=aw[j-1]; aw[j-1]<=aw[j]; aid[j]<=aid[j-1]; aid[j-1]<=aid[j];
                        j<=j-32'sd1; state<=A_ISO_I;
                    end else begin
                        i<=i+32'sd1; state<=A_ISO_O;
                    end
                end

                A_DONE: begin done<=1'b1; state<=A_IDLE; end
                default: state<=A_IDLE;
            endcase
        end
    end
endmodule
