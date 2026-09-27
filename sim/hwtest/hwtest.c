// Bare-metal hardware test for the PICO-8 SoC (no libc).
#include <stdint.h>
#include "../../sw/hw.h"

static void puts_(const char *s) { while (*s) REG_CONSOLE = *s++; }
static void hex(uint32_t v) {
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) REG_CONSOLE = "0123456789abcdef"[(v >> i) & 0xF];
}

static uint32_t xorshift(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *s = x;
}

static int errors;
static void check(const char *what, uint32_t addr, uint32_t got, uint32_t want) {
    if (got != want) {
        if (errors < 10) {
            puts_("FAIL "); puts_(what); puts_(" @"); hex(addr);
            puts_(" got "); hex(got); puts_(" want "); hex(want); puts_("\n");
        }
        errors++;
    }
}

// Region well past the program, larger than the D$ (16 KiB) to force evictions.
#define TEST_BASE 0x00400000u
#define TEST_WORDS (64 * 1024)

void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    puts_("trap mcause="); hex(mcause); puts_(" mepc="); hex(mepc); puts_(" mtval="); hex(mtval); puts_("\n");
    REG_SIM_EXIT = 99;
    for (;;) {}
}

int main(void) {
    puts_("hwtest: id="); hex(REG_ID); puts_(" clock="); hex(REG_CLOCK_HZ); puts_("\n");

    // Word writes/reads
    volatile uint32_t *w = (volatile uint32_t *)TEST_BASE;
    uint32_t seed = 1;
    for (int i = 0; i < TEST_WORDS; i++) w[i] = xorshift(&seed);
    seed = 1;
    for (int i = 0; i < TEST_WORDS; i++) check("word", (uint32_t)&w[i], w[i], xorshift(&seed));
    puts_("words done\n");

    // Byte and halfword writes
    volatile uint8_t *b = (volatile uint8_t *)(TEST_BASE + 0x100000);
    volatile uint16_t *h = (volatile uint16_t *)(TEST_BASE + 0x200000);
    for (int i = 0; i < 40000; i++) b[i] = (uint8_t)(i * 7 + 3);
    for (int i = 0; i < 40000; i++) h[i] = (uint16_t)(i * 13 + 5);
    for (int i = 0; i < 40000; i++) check("byte", (uint32_t)&b[i], b[i], (uint8_t)(i * 7 + 3));
    for (int i = 0; i < 40000; i++) check("half", (uint32_t)&h[i], h[i], (uint16_t)(i * 13 + 5));
    // Mixed: overwrite single bytes of words
    volatile uint32_t *m = (volatile uint32_t *)(TEST_BASE + 0x300000);
    for (int i = 0; i < 8192; i++) m[i] = 0x11223344;
    for (int i = 0; i < 8192; i++) ((volatile uint8_t *)&m[i])[i & 3] = 0xAA;
    for (int i = 0; i < 8192; i++) {
        uint32_t want = (0x11223344 & ~(0xFFu << (8 * (i & 3)))) | (0xAAu << (8 * (i & 3)));
        check("mixed", (uint32_t)&m[i], m[i], want);
    }
    puts_("bytes done\n");

    // BRAM
    volatile uint32_t *r = (volatile uint32_t *)0x10000000;
    for (int i = 0; i < 16384; i++) r[i] = i * 0x01010101u ^ 0xDEADBEEF;
    ((volatile uint8_t *)r)[5] = 0x5A;
    for (int i = 0; i < 16384; i++) {
        uint32_t want = i * 0x01010101u ^ 0xDEADBEEF;
        if (i == 1) want = (want & 0xFFFF00FF) | 0x5A00;
        check("bram", (uint32_t)&r[i], r[i], want);
    }
    puts_("bram done\n");

    // Timing: line refill cost
    uint64_t t0 = hw_cycles();
    uint32_t sum = 0;
    for (int i = 0; i < TEST_WORDS; i += 8) sum += w[i];
    uint64_t t1 = hw_cycles();
    puts_("cycles per line refill: "); hex((uint32_t)((t1 - t0) / (TEST_WORDS / 8))); puts_("\n");
    (void)sum;

    // Video: color bars, all 16 colors, in both buffers.
    static const uint32_t pal[16] = {
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    };
    for (int f = 0; f < 3; f++) {
        while (REG_VIDEO_CTRL & VIDEO_CTRL_FLIP_PENDING) {}
        for (int y = 0; y < 128; y++) {
            for (int xw = 0; xw < 16; xw++) {
                uint32_t word = 0;
                for (int p = 0; p < 8; p++) {
                    int x = xw * 8 + p;
                    uint32_t c = (x / 8 + y / 32 + f) & 15;
                    if (x == y) c = 7;
                    word |= c << (4 * p);
                }
                FRAMEBUFFER[y * 16 + xw] = word;
            }
        }
        for (int i = 0; i < 16; i++) REG_PALETTE(i) = pal[i];
        REG_VIDEO_CTRL = 1;
        // Audio: square wave
        for (int i = 0; i < 1000; i++) REG_AUDIO = (i / 25) & 1 ? 8000 : (uint16_t)-8000;
    }
    while (REG_VIDEO_CTRL & VIDEO_CTRL_FLIP_PENDING) {}
    puts_("audio queued: "); hex(REG_AUDIO); puts_("\n");

    puts_(errors ? "hwtest FAILED, errors: " : "hwtest PASSED "); hex(errors); puts_("\n");
    uint32_t f0 = REG_FRAME_COUNT;
    while (REG_FRAME_COUNT < f0 + 3) {}
    REG_SIM_EXIT = errors ? 1 : 0;
    for (;;) {}
}
