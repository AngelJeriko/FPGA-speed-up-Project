// tb_orch_seedcov.sv — self-checking TB for orch_seedcov. Reads seedcov_vectors
// (+VEC=path), for each alnreg latches coords (clear), streams its chain seeds,
// and checks the accumulated seedcov against the expected value.
`timescale 1ns/1ps

module tb_orch_seedcov;
    logic               clk = 0, rst_n = 0;
    logic               clear, in_valid, in_last;
    logic signed [31:0] qb, qe, s_qbeg, s_len;
    logic signed [63:0] rb, re, s_rbeg;
    logic signed [31:0] seedcov;
    logic               done;

    orch_seedcov dut(.*);

    always #5 clk = ~clk;

    integer fd, cnt, got, i, j, ns, fails;
    integer t_qb, t_qe, t_qbeg, t_len, t_exp;
    longint t_rb, t_re, t_rbeg;
    string path;

    task automatic step; @(posedge clk); #1; endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path = "host/extend_orchestrator/vectors/seedcov_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", path); $finish; end
        clear=0; in_valid=0; in_last=0;
        repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

        got = $fscanf(fd, "%d", cnt);
        fails = 0;
        for (i = 0; i < cnt; i = i + 1) begin
            got = $fscanf(fd, "%d %d %d %d %d", t_qb, t_qe, t_rb, t_re, ns);
            // clear / latch coords
            clear=1; qb=t_qb; qe=t_qe; rb=t_rb; re=t_re;
            step(); clear=0;
            // stream seeds
            for (j = 0; j < ns; j = j + 1) begin
                got = $fscanf(fd, "%d %d %d", t_rbeg, t_qbeg, t_len);
                in_valid=1; s_rbeg=t_rbeg; s_qbeg=t_qbeg; s_len=t_len;
                in_last=(j==ns-1);
                step();
            end
            in_valid=0; in_last=0;
            // done is registered on the last-seed clock; sample now
            got = $fscanf(fd, "%d", t_exp);
            if (!done || seedcov !== t_exp) begin
                fails = fails + 1;
                if (fails <= 8)
                    $display("MISMATCH[%0d] ns=%0d got seedcov=%0d done=%0b | exp %0d",
                             i, ns, seedcov, done, t_exp);
            end
        end
        $fclose(fd);
        $display("orch_seedcov: %0d alnregs, %0d failures -> %s", cnt, fails,
                 (fails==0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
