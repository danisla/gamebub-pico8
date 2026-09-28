// Random sprite and text drawing; prints a screen hash after each call.
#include <cstdio>
#include <cstdlib>
#include "PicoRam.h"
#include "graphics.h"
#include "fontdata.h"
#include <string>
int main() {
    PicoRam *m = new PicoRam();
    m->Reset();
    Graphics *g = new Graphics(get_font_data(), m);
    uint32_t seed = getenv("SEED") ? atoi(getenv("SEED")) : 12345;
    auto rnd = [&](int n) { seed = seed * 1103515245u + 12345u; return (int)((seed >> 8) % n); };
    for (int i = 0; i < 0x2000; i++) m->spriteSheetData[i] = rnd(256);
    int N = getenv("N") ? atoi(getenv("N")) : 20000;
    for (int i = 0; i < N; i++) {
        g->cls(rnd(16));
        m->drawState.camera_x = rnd(3) ? 0 : rnd(64) - 32;
        m->drawState.camera_y = rnd(3) ? 0 : rnd(64) - 32;
        if (rnd(4) == 0) g->clip(rnd(100), rnd(100), rnd(100) + 10, rnd(100) + 10);
        else g->clip();
        for (int c = 0; c < 16; c++) m->drawState.drawPaletteMap[c] = c | (rnd(5) == 0 ? 0x10 : 0);
        int op = rnd(3);
        if (op < 2) {
            int n = rnd(256), sx = rnd(180) - 30, sy = rnd(180) - 30;
            z8::fix32 w = z8::fix32(rnd(4) + 1) / z8::fix32(rnd(2) + 1);
            z8::fix32 h = z8::fix32(rnd(4) + 1) / z8::fix32(rnd(2) + 1);
            bool fx = rnd(2), fy = rnd(2);
            if (getenv("DUMP") && atoi(getenv("DUMP")) == i)
                fprintf(stderr, "spr n=%d x=%d y=%d w=%f h=%f fx=%d fy=%d cam=%d,%d clip=%d,%d-%d,%d\n", n, sx, sy,
                    (double)w, (double)h, fx, fy, m->drawState.camera_x, m->drawState.camera_y,
                    m->drawState.clip_xb, m->drawState.clip_yb, m->drawState.clip_xe, m->drawState.clip_ye);
            g->spr(n, sx, sy, w, h, fx, fy);
        } else {
            int x = rnd(160) - 20, y = rnd(160) - 20;
            uint8_t mode = rnd(3) == 0 ? rnd(256) : 0;
            for (int k = 0; k < 8; k++) x += g->drawCharacter(32 + rnd(95), x, y, rnd(16), rnd(16), mode);
        }
        uint32_t h = 2166136261u;
        for (int k = 0; k < 8192; k++) h = (h ^ m->screenBuffer[k]) * 16777619u;
        printf("%d op%d %08x\n", i, op, h);
        if (getenv("DUMP") && atoi(getenv("DUMP")) == i) {
            FILE *f = fopen(getenv("DUMPFILE"), "wb");
            fwrite(m->screenBuffer, 1, 8192, f);
            fclose(f);
        }
    }
}
