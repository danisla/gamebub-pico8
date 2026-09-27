// Draw many circles and print a hash of the screen after each one.
#include <cstdio>
#include "PicoRam.h"
#include "graphics.h"
int main() {
    PicoRam *m = new PicoRam();
    m->Reset();
    Graphics *g = new Graphics(std::string(), m);
    int n = 0;
    for (int pattern = 0; pattern < 2; pattern++) {
        for (int r = 0; r <= 40; r++) {
            for (int cx = -20; cx < 150; cx += 17) {
                for (int cy = -20; cy < 150; cy += 13) {
                    m->drawState.fillPattern[0] = pattern ? 0x5a : 0;
                    m->drawState.fillPattern[1] = pattern ? 0xa5 : 0;
                    g->cls(0);
                    g->circfill(cx, cy, r, (r + cx) & 15);
                    uint32_t h = 2166136261u;
                    for (int k = 0; k < 8192; k++) h = (h ^ m->screenBuffer[k]) * 16777619u;
                    printf("%d r=%d c=(%d,%d) p=%d %08x\n", n++, r, cx, cy, pattern, h);
                }
            }
        }
    }
}
