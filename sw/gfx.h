// Graphics accelerator commands (hdl/pico8_gfx.sv).
//
// With the accelerator, the PICO-8 RAM is its block RAM (PICO8_RAM, uncached)
// and fake-08's graphics functions (sw/fake08.patch, graphics.cpp) send it
// commands instead of drawing, for the common cases: they do the clipping,
// camera and palette logic and send pixels that are all on the screen. The
// other cases draw on the CPU as before, in the same memory. Commands run in
// order, in parallel with the CPU; the SoC holds the CPU's accesses to the
// screen (and its writes to the sprite sheet, map and flags) until the
// queued commands are done, so the CPU sees the same memory as without it.
#pragma once

#include <stdint.h>

#include "hw.h"

namespace gfx {

/// The accelerator is used (set at startup if present).
extern bool enabled;

/// Commands used (tests): GFX_USE_SPR | GFX_USE_RECT | GFX_USE_GLYPH.
#define GFX_USE_SPR   1
#define GFX_USE_RECT  2
#define GFX_USE_GLYPH 4
#ifndef GFX_USE
#define GFX_USE 7
#endif
inline bool use(int command) { return enabled && (GFX_USE & command); }

/// PRESENTs sent.
extern uint32_t presentsSent;

/// The draw palette as last sent (PAL), valid if paletteSent.
extern uint32_t sentPalette[4];
extern bool paletteSent;

inline void cmd(uint32_t word) { REG_GFX_CMD = word; }

inline void waitIdle() {
    while (REG_GFX_STATUS & GFX_BUSY) {}
}

/// Sends the draw palette (fake-08's drawPaletteMap: color in bits 3:0,
/// transparent if bits 7:4 aren't 0) if it changed since last sent.
inline void syncPalette(const uint8_t *drawPaletteMap) {
    const uint32_t *p = (const uint32_t *)drawPaletteMap;
    uint32_t w0 = p[0], w1 = p[1], w2 = p[2], w3 = p[3];
    if (paletteSent && w0 == sentPalette[0] && w1 == sentPalette[1] && w2 == sentPalette[2] &&
        w3 == sentPalette[3]) {
        return;
    }
    sentPalette[0] = w0;
    sentPalette[1] = w1;
    sentPalette[2] = w2;
    sentPalette[3] = w3;
    paletteSent = true;
    uint32_t trans = 0, colors[2] = {0, 0};
    for (int c = 0; c < 16; c++) {
        uint8_t m = drawPaletteMap[c];
        if (m >> 4) trans |= 1u << c;
        colors[c >> 3] |= (uint32_t)(m & 0x0f) << ((c & 7) * 4);
    }
    cmd(0x10000000u | trans);
    cmd(colors[0]);
    cmd(colors[1]);
}

/// Sprite blit from the sprite sheet at 0 through the draw palette (sent
/// with syncPalette): w x h pixels at (dstX, dstY), from source (srcX, srcY)
/// on, going left / up when flipped. All on the screen and in the sheet.
inline void spr(int dstX, int dstY, int w, int h, int srcX, int srcY, bool flipX, bool flipY) {
    cmd(0x20000000u | (uint32_t)flipX << 27 | (uint32_t)flipY << 26);
    cmd((uint32_t)(h - 1) << 24 | (uint32_t)(w - 1) << 16 | (uint32_t)dstY << 8 | (uint32_t)dstX);
    cmd((uint32_t)srcY << 8 | (uint32_t)srcX);
}

/// Fills x0..x1, y0..y1 (inclusive, on the screen) with color c0, or c1 where
/// the fill pattern's bit is set (skipped if patternTransparent).
inline void rect(int x0, int x1, int y0, int y1, uint8_t c0, uint8_t c1, uint16_t pattern, bool patternTransparent) {
    cmd(0x30000000u | (uint32_t)patternTransparent << 27 | (uint32_t)(c1 & 15) << 20 | (uint32_t)(c0 & 15) << 16 | pattern);
    cmd((uint32_t)y1 << 24 | (uint32_t)y0 << 16 | (uint32_t)x1 << 8 | (uint32_t)x0);
}

/// Draws the set pixels of an 8x8 bitmap (rows: row r in bits 8r+7:8r,
/// column c in bit c of a row) with its top left corner at (x, y), in color
/// (not through the palette). The set pixels are on the screen.
inline void glyph(int x, int y, uint8_t color, uint64_t rows) {
    cmd(0x50000000u | (uint32_t)(color & 15) << 16 | (uint32_t)(y & 0xff) << 8 | (uint32_t)(x & 0xff));
    cmd((uint32_t)rows);
    cmd((uint32_t)(rows >> 32));
}

/// Queues the screen (byte offset in the PICO-8 RAM) with a display palette
/// (RGB888) to be shown, after the frames already waiting (the display is
/// triple buffered). With 2 frames waiting, the accelerator waits for a free
/// back buffer (REG_GFX_WAITS counts it): the following commands wait too,
/// the CPU goes on.
inline void present(uint32_t screenOffset, const uint32_t *rgb) {
    cmd(0x40000000u | (screenOffset >> 2));
    for (int i = 0; i < 16; i++) cmd(rgb[i]);
    presentsSent++;
}

/// Frames sent and not shown yet: waiting to be shown, or PRESENTs not done
/// (with one more counted while a PRESENT finishes between the two reads).
inline uint32_t framesAhead() {
    uint32_t done = REG_GFX_PRESENTS;
    return ((REG_VIDEO_CTRL >> 2) & 3) + (presentsSent - done);
}

}  // namespace gfx
