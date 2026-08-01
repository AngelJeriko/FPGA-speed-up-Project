# AWS F1 bring-up (board-bringup branch)

Goal: get **one kernel running on a real F1 (VU9P) FPGA** through the smallest
possible path, disregarding speedup. This is the plumbing track; it runs in
parallel with the timing track on `main`.

This branch is **not merged to `main`** so it never lands in the OOC re-synth ZIP.

## The path: Custom Logic (CL) + AWS Shell

On F1 you don't get raw board pins. Your kernel is **Custom Logic (CL)** that
plugs into the fixed **AWS Shell (SH)** via the `aws-fpga` HDK, and you talk to it
from the host over PCIe. The minimal control path is the Shell's **OCL AXI4-Lite**
port (a BAR the host peeks/pokes) — **no DDR4, no PCIe DMA needed** for a first
test. Build flow:

    aws_build_dcp_from_cl.sh  ->  DCP  ->  S3  ->  aws ec2 create-fpga-image  ->  AFI
    (on a running f1.2xlarge)  fpga-load-local-image  +  a host app using fpga_pci

## Rung A — what is built + verified here (no AWS needed yet)

| File | Role | Status |
|------|------|--------|
| `rtl/f1/bsw_axil_regs.sv` | AXI4-Lite register file wrapping `bsw_top` | ✅ built |
| `tb/tb_bsw_axil.sv` | Verilator tb: drives AXI-Lite, checks vs a bare `bsw_top` | ✅ 13/13 pass |

`bsw_axil_regs` marshals a query/target/config written over AXI-Lite into
`bsw_top`'s wide parallel ports, pulses the request, and captures the result for
read-back. The testbench proves the wrapper is **transparent**: the same vectors
run through the AXI-Lite path (DUT) and directly into a bare `bsw_top` (REF)
produce identical results (`ACGT/ACGT -> score=5`, matches `tb_bsw_top`), and a
marshalling mutation (swapped query words) makes it go red (4/13 fail). Run it:

    bash scripts/run_sim.sh tb_bsw_axil     # -> "13 pass, 0 fail / PASS"

### Register map (byte offsets in the OCL BAR)

| Offset | Reg | Acc | Contents |
|--------|-----|-----|----------|
| `0x000` | CONTROL | W | bit0 = go (self-clearing pulse) |
| `0x004` | STATUS  | R | bit0 busy, bit1 done, bit2 error |
| `0x010`..`0x023` | CONFIG | W | `bsw_config_t`, 5 words LSW-first (h0,o_del,e_del,o_ins,e_ins,zdrop,end_bonus,w,qlen,tlen) |
| `0x100`..`0x138` | QUERY  | W | 160 bases x 3b = 480b -> 15 words |
| `0x200`..`0x37C` | TARGET | W | 1024 bases x 3b = 3072b -> 96 words |
| `0x400`..`0x40C` | RESULT | R | `bsw_result_t`, 4 words LSW-first (error,score,gscore,qle,tle,gtle,max_off) |

Host sequence: write CONFIG + QUERY + TARGET, write CONTROL=1, poll STATUS until
bit1 (done), read RESULT.

## What is NOT built yet (to actually run on F1)

1. **`cl_bsw_top.sv`** — the CL wrapper matching the `aws-fpga` HDK `cl_*` port
   template. Connects `bsw_axil_regs` to the Shell's `sh_ocl_*` AXI4-Lite master,
   and ties off every unused Shell interface (DDR, PCIS, DMA, IRQ, `*_stat`).
   Start from `aws-fpga/hdk/cl/examples/cl_hello_world` and swap the peek/poke
   register block for `bsw_axil_regs`.
2. **Host app** (`host/f1/test_bsw.c`) — opens the AppPF BAR via `fpga_pci`,
   pokes CONFIG/QUERY/TARGET, pokes GO, polls STATUS, peeks RESULT, checks score.
3. **Build harness** — the HDK `build/scripts/aws_build_dcp_from_cl.sh` invocation
   + `.f1_clock_recipe` selection + AFI creation. (Needs your AWS account + S3.)

These are all developable here (RTL + C) and only the final `aws_build`/AFI needs
your AWS + Vivado + HDK side.

## The one hard prerequisite: 125 MHz

The Shell's main clock `clk_main_a0` is **125 MHz** in its slowest common recipe.
The kernel must **close timing at ≥125 MHz post-place-and-route** to load and run
at all. Current OOC estimate is ~77 MHz on a 7-series proxy and timing does not
yet close — so **the `main` timing track is a hard prerequisite for this bring-up**,
not just a nice-to-have. (Escape hatch: derive a slower divided clock in the CL,
but that adds a clock-domain crossing; 125 MHz is the practical target.)
