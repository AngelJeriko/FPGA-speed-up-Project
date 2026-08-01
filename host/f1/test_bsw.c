// test_bsw.c — AWS F1 host for the BSW kernel (cl_bsw_top / bsw_axil_regs over OCL).
//
// Peeks/pokes the OCL AXI4-Lite BAR (APP_PF, BAR0) — no DDR, no DMA. Marshals a
// query/target/config into the kernel's 32-bit word registers, pulses GO, polls
// STATUS, reads back the result. Register map + word layout mirror rtl/f1/bsw_axil_regs.sv
// and the packed structs in rtl/bsw_pkg.sv (verified in sim by tb_cl_bsw_ocl / tb_bsw_axil).
//
// Build on an F1 instance (aws-fpga sourced):
//   gcc -I$SDK_DIR/userspace/include test_bsw.c -o test_bsw -lfpga_mgmt
// Run (after fpga-load-local-image -S 0 -I <agfi>):
//   sudo ./test_bsw
// GOLDEN self-check: ACGT/ACGT must return score=5 (same vector as tb T9). If the
// packing/AFI is right you get score=5; anything else means a layout/AFI mismatch.

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fpga_pci.h>
#include <fpga_mgmt.h>

// ---- register map (byte offsets; matches bsw_axil_regs.sv) ----
#define A_CTRL 0x000   // W: bit0 = GO (start one alignment)
#define A_STAT 0x004   // R: bit0 busy, bit1 done, bit2 error
#define A_CFG  0x010   // W: 5 words  (bsw_config_t, LSW-first)
#define A_QRY  0x100   // W: 15 words (query bases, 3b each, LSW-first)
#define A_TGT  0x200   // W: 96 words (target bases, 3b each, LSW-first)
#define A_RES  0x400   // R: 4 words  (bsw_result_t, LSW-first)

#define CFG_WORDS 5
#define QRY_WORDS 15
#define TGT_WORDS 96
#define BAND_WIDTH 160   // must match rtl/bsw_pkg.sv (c.w in the sim golden)

static pci_bar_handle_t h = PCI_BAR_HANDLE_INIT;
static void wr(uint32_t off, uint32_t v){ fpga_pci_poke(h, off, v); }
static uint32_t rd(uint32_t off){ uint32_t v; fpga_pci_peek(h, off, &v); return v; }

// pack base value (0..7) at index k into a 3-bit field, LSW-first, with word straddle
static void set_base(uint32_t *w, int k, uint32_t val){
    int bit = 3*k, i = bit>>5, off = bit&31;
    w[i] |= (val & 7u) << off;
    if (off > 29) w[i+1] |= (val & 7u) >> (32-off);   // spills into next word
}

// bsw_config_t packed {h0,o_del,e_del,o_ins,e_ins,zdrop,end_bonus (score_t x7),
// w,qlen,tlen (len_t x3)} — first field = MSB. cfg_words[j] = cfg_w[32j +: 32].
static void pack_cfg(uint32_t c[CFG_WORDS], int16_t h0,int16_t odel,int16_t edel,
                     int16_t oins,int16_t eins,int16_t zdrop,int16_t ebonus,
                     uint16_t w,uint16_t qlen,uint16_t tlen){
    uint16_t f[10] = { (uint16_t)h0,(uint16_t)odel,(uint16_t)edel,(uint16_t)oins,
                       (uint16_t)eins,(uint16_t)zdrop,(uint16_t)ebonus,w,qlen,tlen };
    // f[0]=h0 is MSB (cfg_w[159:144]) ... f[9]=tlen is LSB (cfg_w[15:0]).
    // cfg_w[16*m +: 16] holds field (9-m). Then c[j] = cfg_w[32j +: 32].
    uint16_t lo, hi;
    for (int j = 0; j < CFG_WORDS; j++){
        lo = f[9 - (2*j)];       // cfg_w[32j     +: 16]
        hi = f[9 - (2*j+1)];     // cfg_w[32j+16  +: 16]
        c[j] = ((uint32_t)hi << 16) | lo;
    }
}

int main(void){
    int rc = fpga_pci_init();
    if (rc){ printf("fpga_pci_init failed\n"); return 1; }
    rc = fpga_pci_attach(0 /*slot*/, FPGA_APP_PF, APP_PF_BAR0, 0, &h);
    if (rc){ printf("fpga_pci_attach failed (is the AFI loaded?)\n"); return 1; }

    // ---- ACGT / ACGT, bwa-mem2 extension defaults, h0=1 ----
    uint32_t qw[QRY_WORDS] = {0}, tw[TGT_WORDS] = {0}, cw[CFG_WORDS] = {0};
    const uint8_t seq[4] = {0,1,2,3};                 // A,C,G,T
    for (int k=0;k<4;k++){ set_base(qw,k,seq[k]); set_base(tw,k,seq[k]); }
    pack_cfg(cw, /*h0*/1, /*o_del*/6, /*e_del*/1, /*o_ins*/6, /*e_ins*/1,
                 /*zdrop*/0, /*end_bonus*/0, /*w*/BAND_WIDTH, /*qlen*/4, /*tlen*/4);

    for (int j=0;j<CFG_WORDS;j++) wr(A_CFG + 4*j, cw[j]);
    for (int j=0;j<QRY_WORDS;j++) wr(A_QRY + 4*j, qw[j]);
    for (int j=0;j<TGT_WORDS;j++) wr(A_TGT + 4*j, tw[j]);

    wr(A_CTRL, 1);                                    // GO
    uint32_t st; int spins=0;
    do { st = rd(A_STAT); } while (!(st & 0x2) && ++spins < 1000000);
    if (!(st & 0x2)){ printf("TIMEOUT waiting for done (STATUS=0x%08x)\n", st); return 1; }

    // ---- result words -> fields (bsw_result_t: error,score,gscore,qle,tle,gtle,max_off) ----
    uint32_t r0=rd(A_RES+0), r1=rd(A_RES+4), r2=rd(A_RES+8), r3=rd(A_RES+12);
    int16_t  max_off=(int16_t)(r0 & 0xFFFF), gtle=(int16_t)(r0>>16);
    int16_t  tle=(int16_t)(r1 & 0xFFFF),     qle =(int16_t)(r1>>16);
    int16_t  gscore=(int16_t)(r2 & 0xFFFF),  score=(int16_t)(r2>>16);
    int      error = r3 & 1;

    printf("BSW result: error=%d score=%d gscore=%d qle=%d tle=%d gtle=%d max_off=%d\n",
           error, score, gscore, qle, tle, gtle, max_off);
    printf(score==5 && !error ? "GOLDEN OK (ACGT/ACGT -> score=5)\n"
                              : "MISMATCH — check AFI / word layout\n");

    fpga_pci_detach(h);
    return (score==5 && !error) ? 0 : 2;
}
