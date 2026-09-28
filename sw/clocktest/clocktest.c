// Clock / SDRAM timing test for the PICO-8 core: install as pico8.bin in
// /cores/PICO-8/ (instead of the emulator) and start any cart. See README.txt.
//
// The program runs from block RAM (see start.S), so bad SDRAM timing can't
// crash it. It:
// 1. Sweeps the SDRAM clock phase over a full clock period (56 points), for
//    CAS latency 2 and 3 and extra read capture delays of 0-2 cycles, testing
//    the SDRAM at each point. Each row on screen shows one configuration:
//    green = passed, red = failed; the yellow tick is the built-in phase (the
//    one the PICO-8 core uses, with CL2 +0).
// 2. Then runs a stress test at the built-in configuration: the SDRAM (30
//    MiB, several patterns) and CPU test kernels (from block RAM and from
//    SDRAM), counting passes and errors.
//
// Press A to sweep again. The results are also written to the log (saved as
// <cart>.p8.log next to the cart when the core exits).
#include <stdarg.h>
#include <stdint.h>
#include "../hw.h"
#include "seeds.h"
#include "expected.h"

#define KERNEL_SCRATCH 8192

typedef uint32_t (*kernel_fn)(uint32_t, uint32_t *);
#define KERNELS(X) X(k_crc) X(k_mul) X(k_div) X(k_sort) X(k_interp) X(k_mem)
#define DECLARE(n) uint32_t n(uint32_t, uint32_t *); uint32_t n##_sdram(uint32_t, uint32_t *);
KERNELS(DECLARE)
#define BRAM_FN(n) n,
#define SDRAM_FN(n) n##_sdram,
#define NAME(n) #n,
static const kernel_fn kernels_bram[] = { KERNELS(BRAM_FN) };
static const kernel_fn kernels_sdram[] = { KERNELS(SDRAM_FN) };
static const char *const kernel_names[] = { KERNELS(NAME) };
#define NUM_KERNELS ((int)(sizeof(kernels_bram) / sizeof(kernels_bram[0])))

// SDRAM areas (the image is at 0, the SDRAM kernels in it)
#define EVICT_BASE     0x00080000u  // 128 KiB, read to write back the data cache
#define EVICT_SIZE     0x00020000u
#define SCRATCH_SDRAM  ((uint32_t *)0x000C0000u)
#define QUICK_BASE     0x00100000u  // sweep test: 512 KiB
#define STRESS_BASE    0x00200000u  // stress test: 30 MiB
#ifdef CLOCKTEST_SIM
// Smaller areas for the simulation (sim/, make -C sw/clocktest sim)
#define QUICK_SIZE     0x00010000u
#define STRESS_SIZE    0x00100000u
#else
#define QUICK_SIZE     0x00080000u
#define STRESS_SIZE    0x01E00000u
#endif

#define POINTS 56     // phase sweep points per clock period
#define CENTER 28     // the built-in phase
static const uint8_t configs[] = {
    0,                                      // CL2 +0 (the built-in configuration)
    SDRAM_CFG_EXTRA(1), SDRAM_CFG_EXTRA(2),
    SDRAM_CFG_CL3, SDRAM_CFG_CL3 | SDRAM_CFG_EXTRA(1), SDRAM_CFG_CL3 | SDRAM_CFG_EXTRA(2),
};
#define NUM_CONFIGS ((int)sizeof(configs))

extern uint32_t _sdram_text_start[], _sdram_text_end[];

static uint32_t clock_hz, divider;
static uint32_t kernel_backup[2048];
static uint32_t scratch_bram[KERNEL_SCRATCH / 4];
static uint8_t sweep_result[NUM_CONFIGS][POINTS];  // 1 = passed
static int swept;
static uint32_t mem_passes, mem_errors, cpu_passes, cpu_errors;
static uint32_t kernel_errors[NUM_KERNELS][2];
static uint32_t last_addr, last_want, last_got;
static uint64_t stress_start;

////////////////////////////////////////////////////////////////////////////
// Text output (console / log and screen)
////////////////////////////////////////////////////////////////////////////

static char *put_u(char *o, uint32_t v, int width, int base, char pad) {
    char tmp[12];
    int n = 0;
    do {
        tmp[n++] = "0123456789ABCDEF"[v % base];
        v /= base;
    } while (v);
    while (n < width) tmp[n++] = pad;
    while (n) *o++ = tmp[--n];
    return o;
}

// Minimal printf: %d %u %x %s %c, with an optional width (0: zero padded).
static int vformat(char *out, const char *f, va_list ap) {
    char *o = out;
    for (; *f; f++) {
        if (*f != '%') { *o++ = *f; continue; }
        int width = 0;
        f++;
        char pad = *f == '0' ? '0' : ' ';
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        switch (*f) {
        case 'd': {
            int v = va_arg(ap, int);
            if (v < 0) { *o++ = '-'; v = -v; width--; }
            o = put_u(o, (uint32_t)v, width, 10, pad);
            break;
        }
        case 'u': o = put_u(o, va_arg(ap, uint32_t), width, 10, pad); break;
        case 'x': o = put_u(o, va_arg(ap, uint32_t), width, 16, pad); break;
        case 'c': *o++ = (char)va_arg(ap, int); break;
        case 's': for (const char *s = va_arg(ap, const char *); *s; s++) *o++ = *s; break;
        default: *o++ = *f; break;
        }
    }
    *o = 0;
    return o - out;
}

static void log_printf(const char *f, ...) {
    char buf[160];
    va_list ap;
    va_start(ap, f);
    vformat(buf, f, ap);
    va_end(ap);
    for (char *s = buf; *s; s++) REG_CONSOLE = (uint8_t)*s;
}

// 3x5 font: rows of 3 bits, top first.
#define G(a, b, c, d, e) (((a) << 12) | ((b) << 9) | ((c) << 6) | ((d) << 3) | (e))
static uint16_t glyph(char c) {
    static const uint16_t digits[10] = {
        G(7,5,5,5,7), G(2,6,2,2,7), G(7,1,7,4,7), G(7,1,3,1,7), G(5,5,7,1,1),
        G(7,4,7,1,7), G(7,4,7,5,7), G(7,1,2,2,2), G(7,5,7,5,7), G(7,5,7,1,7),
    };
    static const uint16_t letters[26] = {
        G(2,5,7,5,5), G(6,5,6,5,6), G(3,4,4,4,3), G(6,5,5,5,6), G(7,4,6,4,7),
        G(7,4,6,4,4), G(3,4,5,5,3), G(5,5,7,5,5), G(7,2,2,2,7), G(1,1,1,5,2),
        G(5,5,6,5,5), G(4,4,4,4,7), G(5,7,7,5,5), G(6,5,5,5,5), G(2,5,5,5,2),
        G(6,5,6,4,4), G(2,5,5,6,3), G(6,5,6,5,5), G(3,4,2,1,6), G(7,2,2,2,2),
        G(5,5,5,5,7), G(5,5,5,5,2), G(5,5,7,7,5), G(5,5,2,5,5), G(5,5,2,2,2),
        G(7,1,2,4,7),
    };
    if (c >= '0' && c <= '9') return digits[c - '0'];
    if (c >= 'a' && c <= 'z') c -= 32;
    if (c >= 'A' && c <= 'Z') return letters[c - 'A'];
    switch (c) {
    case '.': return G(0,0,0,0,2);
    case ':': return G(0,2,0,2,0);
    case '+': return G(0,2,7,2,0);
    case '-': return G(0,0,7,0,0);
    case '/': return G(1,1,2,4,4);
    case '%': return G(5,1,2,4,5);
    case '(': return G(2,4,4,4,2);
    case ')': return G(2,1,1,1,2);
    case '=': return G(0,7,0,7,0);
    case '!': return G(2,2,2,0,2);
    case '?': return G(6,1,2,0,2);
    case '>': return G(4,2,1,2,4);
    case '<': return G(1,2,4,2,1);
    case ',': return G(0,0,0,2,4);
    case '_': return G(0,0,0,0,7);
    default: return 0;
    }
}

static uint32_t fb[2048];  // 128x128, 4 bits per pixel

static void set_px(int x, int y, uint32_t c) {
    if (x < 0 || x >= 128 || y < 0 || y >= 128) return;
    uint32_t *w = &fb[y * 16 + (x >> 3)];
    int s = (x & 7) * 4;
    *w = (*w & ~(0xFu << s)) | (c << s);
}

static void fill_rect(int x, int y, int w, int h, uint32_t c) {
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) set_px(x + i, y + j, c);
}

static void draw_text(int x, int y, uint32_t c, const char *f, ...) {
    char buf[64];
    va_list ap;
    va_start(ap, f);
    vformat(buf, f, ap);
    va_end(ap);
    for (const char *s = buf; *s; s++, x += 4) {
        uint16_t g = glyph(*s);
        for (int r = 0; r < 5; r++)
            for (int col = 0; col < 3; col++)
                if (g & (1 << (14 - (r * 3 + col)))) set_px(x + col, y + r, c);
    }
}

static void present(void) {
    static const uint32_t pal[16] = {
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    };
    while (REG_VIDEO_CTRL & VIDEO_CTRL_FLIP_PENDING) {}
    for (int i = 0; i < 2048; i++) FRAMEBUFFER[i] = fb[i];
    for (int i = 0; i < 16; i++) REG_PALETTE(i) = pal[i];
    REG_VIDEO_CTRL = 1;
}

////////////////////////////////////////////////////////////////////////////
// SDRAM control
////////////////////////////////////////////////////////////////////////////

// Write back (and drop) the data cache's SDRAM lines by reading elsewhere.
static void evict_dcache(void) {
    volatile uint32_t *p = (volatile uint32_t *)EVICT_BASE;
    for (uint32_t i = 0; i < EVICT_SIZE / 4; i += 16) (void)p[i];
    __asm__ volatile("fence" ::: "memory");
}

static void delay_cycles(uint32_t n) {
    uint32_t start = REG_CYCLE_LO;
    while (REG_CYCLE_LO - start < n) {}
}

// Initialize the SDRAM again with a configuration (loses its contents).
static void sdram_config(uint32_t cfg) {
    evict_dcache();
    delay_cycles(64);
    REG_SDRAM_CFG = cfg | SDRAM_CFG_REINIT;
    while (!(REG_SDRAM_CFG & SDRAM_CFG_READY)) {}
}

static int phase_position(void) { return (int16_t)(REG_SDRAM_PHASE >> 16); }

// Move the SDRAM clock phase to `target` steps (1/56 VCO period each) from
// the built-in phase.
static void phase_move(int target) {
    int pos = phase_position();
    while (pos != target) {
        while (REG_SDRAM_PHASE & 1) {}
        REG_SDRAM_PHASE = pos < target ? 1 : 0;
        pos += pos < target ? 1 : -1;
    }
    while (REG_SDRAM_PHASE & 1) {}
}

// Put the SDRAM copy of the CPU kernels back (after an SDRAM test).
static void restore_kernels(void) {
    uint32_t n = _sdram_text_end - _sdram_text_start;
    for (uint32_t i = 0; i < n; i++) _sdram_text_start[i] = kernel_backup[i];
    evict_dcache();
    __asm__ volatile("fence.i" ::: "memory");
}

////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////

static inline uint32_t xs(uint32_t x) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

// Write a pattern to [base, base + size), then read it back; returns errors.
// (The area is much larger than the data cache, so the reads come from the
// SDRAM.) Patterns: 0 random, 1 address, 2 inverted address, 3 random inverted.
static uint32_t pattern_test(uint32_t base, uint32_t size, int pattern, uint32_t seed) {
    volatile uint32_t *p = (volatile uint32_t *)base;
    uint32_t n = size / 4, x = seed | 1, errors = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t a = base + 4 * i, v;
        switch (pattern) {
        case 0: v = x = xs(x); break;
        case 1: v = a ^ seed; break;
        case 2: v = ~a ^ seed; break;
        default: v = ~(x = xs(x)); break;
        }
        p[i] = v;
    }
    x = seed | 1;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t a = base + 4 * i, v;
        switch (pattern) {
        case 0: v = x = xs(x); break;
        case 1: v = a ^ seed; break;
        case 2: v = ~a ^ seed; break;
        default: v = ~(x = xs(x)); break;
        }
        uint32_t got = p[i];
        if (got != v) {
            if (!errors) { last_addr = a; last_want = v; last_got = got; }
            errors++;
        }
    }
    return errors;
}

static const char *config_name(uint32_t cfg) {
    static char name[8];
    name[0] = 'C'; name[1] = 'L'; name[2] = (cfg & SDRAM_CFG_CL3) ? '3' : '2';
    name[3] = '+'; name[4] = (char)('0' + ((cfg >> 1) & 3)); name[5] = 0;
    return name;
}

// Longest run of passing points (circular); returns its length, center in *mid.
static int best_window(const uint8_t *r, int *mid) {
    int best = 0, best_start = 0;
    for (int s = 0; s < POINTS; s++) {
        if (!r[s] || r[(s + POINTS - 1) % POINTS]) continue;  // run starts here
        int len = 0;
        while (len < POINTS && r[(s + len) % POINTS]) len++;
        if (len > best) { best = len; best_start = s; }
    }
    if (best == 0 && r[0]) best = POINTS;  // all passed
    *mid = (best_start + best / 2) % POINTS;
    return best;
}

static void sweep(void) {
    uint32_t step = divider;  // phase steps per point: period / 56
    uint32_t period_ps = 1000000000u / (clock_hz / 1000);
    log_printf("sweep: %u points per period, %u ps each, for each configuration\n"
               "  (# = passed, . = failed; point %d is the built-in phase, 0)\n",
               POINTS, period_ps / POINTS, CENTER);
    for (int c = 0; c < NUM_CONFIGS; c++) {
        phase_move(-(int)(CENTER * step));
        for (int pt = 0; pt < POINTS; pt++) {
            sdram_config(configs[c]);
            uint32_t e = pattern_test(QUICK_BASE, QUICK_SIZE, 0, 0x1234567u + pt)
                + pattern_test(QUICK_BASE, QUICK_SIZE, 2, 0x89ABCDEFu);
            sweep_result[c][pt] = e == 0;
            if (pt < POINTS - 1) phase_move(phase_position() + (int)step);
        }
        char line[POINTS + 4];
        for (int pt = 0; pt < POINTS; pt++) line[pt] = sweep_result[c][pt] ? '#' : '.';
        line[POINTS] = 0;
        int mid, len = best_window(sweep_result[c], &mid);
        log_printf("  %s %s  window %d points, center %d\n", config_name(configs[c]), line, len, mid - CENTER);
    }
    phase_move(0);
    sdram_config(0);
    restore_kernels();
    swept = 1;

    int bc = 0, bmid = 0, blen = 0;
    for (int c = 0; c < NUM_CONFIGS; c++) {
        int mid, len = best_window(sweep_result[c], &mid);
        if (len > blen) { blen = len; bc = c; bmid = mid; }
    }
    // Margin of the built-in phase (CL2 +0, point CENTER) to the failures.
    int left = 0, right = 0;
    if (sweep_result[0][CENTER]) {
        while (left < POINTS && sweep_result[0][(CENTER - left - 1 + POINTS) % POINTS]) left++;
        while (right < POINTS && sweep_result[0][(CENTER + right + 1) % POINTS]) right++;
    }
    log_printf("built-in phase (CL2+0): %s, margin -%d/+%d points (%d/%d ps)\n",
               sweep_result[0][CENTER] ? "passed" : "FAILED", left, right,
               left * (int)(period_ps / POINTS), right * (int)(period_ps / POINTS));
    log_printf("widest window: %s, %d points, center %d points (%d deg) from the built-in phase\n",
               config_name(configs[bc]), blen, bmid - CENTER, (bmid - CENTER) * 360 / POINTS);
}

static void cpu_test(void) {
    for (int k = 0; k < NUM_KERNELS; k++) {
        for (int s = 0; s < NUM_SEEDS; s++) {
            uint32_t want = expected[k][s];
            if (kernels_bram[k](seed_of(s), scratch_bram) != want) { kernel_errors[k][0]++; cpu_errors++; }
            if (kernels_sdram[k](seed_of(s), SCRATCH_SDRAM) != want) { kernel_errors[k][1]++; cpu_errors++; }
        }
    }
    cpu_passes++;
}

static void mem_test(void) {
    int pattern = mem_passes & 3;
    uint32_t e = pattern_test(STRESS_BASE, STRESS_SIZE, pattern, 0xC0FFEEu + mem_passes);
    if (e) log_printf("mem pass %u (pattern %d): %u errors, first at %08x: want %08x got %08x\n",
                      mem_passes, pattern, e, last_addr, last_want, last_got);
    mem_errors += e;
    mem_passes++;
    // The stress area doesn't overlap the kernels, but a failure could
    // have corrupted anything.
    if (e) restore_kernels();
}

////////////////////////////////////////////////////////////////////////////
// Screen
////////////////////////////////////////////////////////////////////////////

static void draw(void) {
    for (int i = 0; i < 2048; i++) fb[i] = 0;
    uint32_t mhz10 = (clock_hz + 50000) / 100000;
    draw_text(1, 1, 7, "CLOCKTEST %u.%u MHZ", mhz10 / 10, mhz10 % 10);
    draw_text(1, 8, 6, "SDRAM PHASE SWEEP (1 PERIOD)");
    for (int c = 0; c < NUM_CONFIGS; c++) {
        int y = 15 + c * 8;
        draw_text(1, y, 6, "%s", config_name(configs[c]) + 2);
        for (int pt = 0; pt < POINTS; pt++) {
            uint32_t col = !swept ? 5 : sweep_result[c][pt] ? 11 : 8;
            fill_rect(16 + pt * 2, y, 2, 5, col);
        }
        fill_rect(16 + CENTER * 2, y + 5, 2, 2, 10);
    }
    int y = 15 + NUM_CONFIGS * 8 + 2;
    if (swept) {
        int mid, len = best_window(sweep_result[0], &mid);
        draw_text(1, y, sweep_result[0][CENTER] ? 11 : 8, "BUILT-IN: %s WINDOW %d",
                  sweep_result[0][CENTER] ? "PASS" : "FAIL", len);
        y += 7;
    }
    uint32_t secs = (uint32_t)((hw_cycles() - stress_start) / clock_hz);
    draw_text(1, y, 7, "STRESS %u:%02u", secs / 60, secs % 60);
    y += 7;
    draw_text(1, y, mem_errors ? 8 : 11, "MEM PASS %u ERR %u", mem_passes, mem_errors);
    y += 7;
    draw_text(1, y, cpu_errors ? 8 : 11, "CPU PASS %u ERR %u", cpu_passes, cpu_errors);
    y += 7;
    for (int k = 0; k < NUM_KERNELS; k++) {
        if (kernel_errors[k][0] || kernel_errors[k][1]) {
            draw_text(1, y, 8, "%s B%u S%u", kernel_names[k] + 2, kernel_errors[k][0], kernel_errors[k][1]);
            y += 6;
        }
    }
    if (mem_errors) draw_text(1, 121, 8, "%08x %08x %08x", last_addr, last_want, last_got);
    else draw_text(1, 121, 5, "A: SWEEP AGAIN");
    present();
}

void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    log_printf("trap: mcause %x mepc %x mtval %x\n", mcause, mepc, mtval);
    for (int i = 0; i < 2048; i++) fb[i] = 0x88888888u;
    draw_text(1, 1, 7, "TRAP %x", mcause);
    draw_text(1, 8, 7, "PC %x", mepc);
    draw_text(1, 15, 7, "VAL %x", mtval);
    present();
    for (;;) {}
}

int main(void) {
    uint32_t n = _sdram_text_end - _sdram_text_start;
    if (n > sizeof(kernel_backup) / 4) {
        log_printf("clocktest: SDRAM kernels too large (%u words)\n", n);
        for (;;) {}
    }
    for (uint32_t i = 0; i < n; i++) kernel_backup[i] = _sdram_text_start[i];

    clock_hz = REG_CLOCK_HZ;
    divider = (1000000000u + clock_hz / 2) / clock_hz;
    log_printf("clocktest: clock %u Hz (VCO 1000 MHz / %u), SDRAM kernels %u bytes\n",
               clock_hz, divider, n * 4);
    draw();

    // Sanity check at the built-in configuration, before the sweep.
    cpu_test();
    log_printf("initial CPU test: %s\n", cpu_errors ? "FAILED" : "passed");

    sweep();
    stress_start = hw_cycles();
    mem_passes = mem_errors = cpu_passes = cpu_errors = 0;
    for (int k = 0; k < NUM_KERNELS; k++) kernel_errors[k][0] = kernel_errors[k][1] = 0;

    uint32_t last_log = 0, prev_buttons = 0;
    for (;;) {
        mem_test();
        cpu_test();
        draw();
        uint32_t secs = (uint32_t)((hw_cycles() - stress_start) / clock_hz);
        if (secs >= last_log + 60) {
            last_log = secs;
            log_printf("stress %u s: mem %u passes %u errors, cpu %u passes %u errors\n",
                       secs, mem_passes, mem_errors, cpu_passes, cpu_errors);
        }
        uint32_t buttons = REG_BUTTONS;
        if ((buttons & BTN_A) && !(prev_buttons & BTN_A)) {
            sweep();
            draw();
        }
        prev_buttons = buttons;
    }
}
