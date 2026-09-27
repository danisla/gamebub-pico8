// Plays single-note SFX for every instrument / effect / filter combination and
// writes each case's audio (0.5 s) to stdout as raw int16, preceded by a line
// with the case name. Built against both audio implementations.
#include <cstdio>
#include <cstring>
#include <vector>

#include "Audio.h"
#include "PicoRam.h"

int main() {
    PicoRam *memory = new PicoRam();
    memory->Reset();
    const char *inst[] = {"tri", "tilt", "saw", "sqr", "pulse", "organ", "noise", "phaser"};
    for (int i = 0; i < 8; i++) {
        for (int fx = 0; fx < 8; fx++) {
            for (int filt : {0, 2, 4, 8, 16, 24, 48, 72, 144}) {
                if (fx != 0 && filt != 0) continue;
                Audio *audio = new Audio(memory);
                struct sfx &s = memory->sfx[0];
                memset(&s, 0, sizeof(s));
                s.speed = 16;
                s.filters = filt;
                for (int n = 0; n < 8; n++) {
                    s.notes[n].setKey(24 + (n % 4) * 5);
                    s.notes[n].setWaveform(i);
                    s.notes[n].setVolume(5);
                    s.notes[n].setEffect(fx);
                }
                audio->api_sfx(0, 0, 0, 0);
                std::vector<int16_t> buf(11025);
                // Fill in 60 Hz chunks, like the platform code.
                size_t pos = 0;
                while (pos < buf.size()) {
                    size_t n = std::min<size_t>(367, buf.size() - pos);
                    audio->FillMonoAudioBuffer(buf.data() + pos, 0, n);
                    pos += n;
                }
                printf("%s fx%d filt%d\n", inst[i], fx, filt);
                fwrite(buf.data(), 2, buf.size(), stdout);
                delete audio;
            }
        }
    }
}
