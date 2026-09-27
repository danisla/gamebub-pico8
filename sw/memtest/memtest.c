// Hardware test for the PICO-8 core: install as pico8.bin in /cores/PICO-8/
// (instead of the emulator) and start any cart.
//
// * Tests the SDRAM continuously (0x00100000-0x01FFFFFF: words, bytes,
//   random data), and shows the results on screen:
//     green background: no errors, red: errors.
//     row 1: passes  row 2: errors  row 3: last error address
//     row 4: expected  row 5: read value  row 6: buttons
// * Plays a tone (440 Hz square wave; hold A for 880 Hz): tests audio and input.
#include <stdint.h>
#include "../hw.h"

#define TEST_START 0x00100000u
#define TEST_END   0x02000000u

static uint32_t passes, errors, last_addr, last_want, last_got;
static uint32_t tone_phase;

// 3x5 hex digit font (bits: 3 per row, 5 rows)
static const uint16_t font[16] = {
    0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249,
    0x7BEF, 0x7BCF, 0x7BED, 0x6BAE, 0x7927, 0x6B6E, 0x79E7, 0x79E4,
};

static uint32_t fb[2048];

static void set_px(int x, int y, uint32_t c) {
    uint32_t *w = &fb[y * 16 + (x >> 3)];
    int s = (x & 7) * 4;
    *w = (*w & ~(0xFu << s)) | (c << s);
}

static void draw_hex(int x, int y, uint32_t v, uint32_t c) {
    for (int d = 0; d < 8; d++) {
        uint16_t g = font[(v >> (28 - 4 * d)) & 0xF];
        for (int r = 0; r < 5; r++)
            for (int col = 0; col < 3; col++)
                if (g & (1 << (14 - (r * 3 + col))))
                    for (int sy = 0; sy < 2; sy++)
                        for (int sx = 0; sx < 2; sx++)
                            set_px(x + d * 8 + col * 2 + sx, y + r * 2 + sy, c);
    }
}

static void feed_audio(void) {
    uint32_t inc = (REG_BUTTONS & BTN_A) ? 880 : 440;
    while (REG_AUDIO < 2048) {
        tone_phase += inc;
        if (tone_phase >= AUDIO_RATE) tone_phase -= AUDIO_RATE;
        REG_AUDIO = (uint16_t)(tone_phase < AUDIO_RATE / 2 ? 6000 : -6000);
    }
}

static void show(void) {
    uint32_t bg = errors ? 8 : 3; // red / dark green
    for (int i = 0; i < 2048; i++) fb[i] = bg * 0x11111111u;
    draw_hex(8, 8, passes, 7);
    draw_hex(8, 24, errors, 7);
    draw_hex(8, 40, last_addr, 10);
    draw_hex(8, 56, last_want, 10);
    draw_hex(8, 72, last_got, 10);
    draw_hex(8, 88, REG_BUTTONS, 12);
    while (REG_VIDEO_CTRL & VIDEO_CTRL_FLIP_PENDING) feed_audio();
    for (int i = 0; i < 2048; i++) FRAMEBUFFER[i] = fb[i];
    static const uint32_t pal[16] = {
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    };
    for (int i = 0; i < 16; i++) REG_PALETTE(i) = pal[i];
    REG_VIDEO_CTRL = 1;
}

static void check(uint32_t addr, uint32_t got, uint32_t want) {
    if (got != want) {
        errors++;
        last_addr = addr;
        last_want = want;
        last_got = got;
    }
}

static uint32_t rng(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *s = x;
}

void trap_handler(uint32_t *regs) {
    (void)regs;
    errors = 0xDEAD0000u;
    show();
    for (;;) feed_audio();
}

int main(void) {
    show();
    for (;;) {
        volatile uint32_t *w = (volatile uint32_t *)TEST_START;
        uint32_t n = (TEST_END - TEST_START) / 4;
        uint32_t seed = 0x12345678u + passes * 0x9E3779B9u;
        uint32_t s = seed;
        // Random words
        for (uint32_t i = 0; i < n; i++) {
            w[i] = rng(&s);
            if ((i & 0x3FFF) == 0) feed_audio();
        }
        s = seed;
        for (uint32_t i = 0; i < n; i++) {
            check((uint32_t)&w[i], w[i], rng(&s));
            if ((i & 0x3FFF) == 0) feed_audio();
        }
        show();
        // Address in address (inverted on odd passes), with byte writes in one word of every 8
        for (uint32_t i = 0; i < n; i++) {
            uint32_t v = (uint32_t)&w[i] ^ ((passes & 1) ? 0xFFFFFFFFu : 0);
            if ((i & 7) == 3) {
                volatile uint8_t *b = (volatile uint8_t *)&w[i];
                b[0] = v; b[1] = v >> 8; b[2] = v >> 16; b[3] = v >> 24;
            } else {
                w[i] = v;
            }
            if ((i & 0x3FFF) == 0) feed_audio();
        }
        for (uint32_t i = 0; i < n; i++) {
            check((uint32_t)&w[i], w[i], (uint32_t)&w[i] ^ ((passes & 1) ? 0xFFFFFFFFu : 0));
            if ((i & 0x3FFF) == 0) feed_audio();
        }
        passes++;
        show();
    }
}
