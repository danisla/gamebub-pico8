// Bare-metal benchmark: CPU cycles per load/store for each kind of memory
// (uncached I/O blocks, block RAM, SDRAM). Uses sim/hwtest's start.S and
// link.ld. Prints the results on the console, then ends the simulation:
//
//   T=nix/result-toolchain/bin/riscv32-none-elf-
//   ${T}gcc -march=rv32imc_zicsr -mabi=ilp32 -O2 -nostdlib -ffreestanding \
//       -T sim/hwtest/link.ld sim/hwtest/start.S sim/iobench/iobench.c -o iobench.elf
//   ${T}objcopy -O binary iobench.elf iobench.bin && truncate -s %4 iobench.bin
//   cd sim && ./obj_dir_vexii/Vsim_top --frames 20 ../iobench.bin carts/btntest.p8
#include <stdint.h>
#include "../../sw/hw.h"

static void puts_(const char *s) { while (*s) REG_CONSOLE = *s++; }
static void dec(uint32_t v) {
    char buf[12];
    int i = 0;
    do { buf[i++] = '0' + v % 10; v /= 10; } while (v);
    while (i) REG_CONSOLE = buf[--i];
}

void trap_handler(uint32_t cause, uint32_t epc, uint32_t tval) {
    puts_("trap\n");
    REG_SIM_EXIT = 1;
}

#define N 1024

// Cycles per access, in tenths (8 accesses per iteration, unrolled).
static void report(const char *what, uint32_t cycles) {
    puts_(what);
    puts_(": ");
    uint32_t t = cycles * 10 / N;
    dec(t / 10);
    REG_CONSOLE = '.';
    dec(t % 10);
    puts_(" cycles\n");
}

static uint32_t __attribute__((noinline)) stores(volatile uint32_t *p) {
    uint32_t t0 = REG_CYCLE_LO;
    for (int i = 0; i < N; i += 8) {
        p[i] = i; p[i + 1] = i; p[i + 2] = i; p[i + 3] = i;
        p[i + 4] = i; p[i + 5] = i; p[i + 6] = i; p[i + 7] = i;
    }
    return REG_CYCLE_LO - t0;
}

static uint32_t sink;
static uint32_t __attribute__((noinline)) loads(volatile uint32_t *p) {
    uint32_t t0 = REG_CYCLE_LO;
    uint32_t s = 0;
    for (int i = 0; i < N; i += 8) {
        s += p[i] + p[i + 1] + p[i + 2] + p[i + 3] + p[i + 4] + p[i + 5] + p[i + 6] + p[i + 7];
    }
    sink = s;
    return REG_CYCLE_LO - t0;
}

int main(void) {
    volatile uint32_t *bram = (volatile uint32_t *)0x10008000u;
    volatile uint32_t *sdram = (volatile uint32_t *)0x00400000u;
    for (int pass = 0; pass < 2; pass++) {
        puts_(pass ? "warm:\n" : "cold:\n");
        report("  framebuffer store (I/O)", stores(FRAMEBUFFER));
        report("  shared RAM store (I/O) ", stores(SHARED_RAM));
        report("  shared RAM load (I/O)  ", loads(SHARED_RAM));
        report("  block RAM store (D$)   ", stores(bram));
        report("  block RAM load (D$)    ", loads(bram));
        report("  SDRAM store (D$)       ", stores(sdram));
        report("  SDRAM load (D$)        ", loads(sdram));
    }
    REG_SIM_EXIT = 0;
    return 0;
}
