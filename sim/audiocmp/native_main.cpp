// Native (x86) fake-08 audio harness: runs a cart for N 60 Hz frames and writes
// the audio (22050 Hz mono) to a WAV file. Built twice: with fake-08's original
// audio and with sw/audio.cpp, to compare them.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <array>

#include "Audio.h"
#include "PicoRam.h"
#include "host.h"
#include "vm.h"

// Deterministic time (fake-08 seeds rnd() from the clock), so runs can be compared.
#include <time.h>
extern "C" int clock_gettime(clockid_t, struct timespec *ts) {
    static long long t = 1000000000LL;
    t += 1000;
    ts->tv_sec = t / 1000000000LL;
    ts->tv_nsec = t % 1000000000LL;
    return 0;
}

void setInputState(uint8_t kDown, uint8_t kHeld, int16_t mouseX, int16_t mouseY, uint8_t mouseBtns);

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s cart frames out.wav [press_frame]\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "rb");
    std::vector<unsigned char> cart;
    int c;
    while ((c = fgetc(f)) != EOF) cart.push_back(c);
    fclose(f);
    int frames = atoi(argv[2]);
    int press = argc > 4 ? atoi(argv[4]) : -1;

    Host *host = new Host();
    PicoRam *memory = new PicoRam();
    memory->Reset();
    Audio *audio = new Audio(memory);
    Vm *vm = new Vm(host, memory, nullptr, nullptr, audio);
    host->setUpPaletteColors();
    host->oneTimeSetup(audio);
    vm->QueueCartChange(cart.data(), cart.size());

    if (getenv("MEM_TRACE")) {
        for (int i = 0; i < 3; i++) vm->Step();
        struct { const char *name; int start, end; } regions[] = {
            {"gfx", 0x0000, 0x2000}, {"map", 0x2000, 0x3000}, {"flags", 0x3000, 0x3100},
            {"music", 0x3100, 0x3200}, {"sfx", 0x3200, 0x4300}};
        for (auto &r : regions) {
            int nz = 0;
            for (int a = r.start; a < r.end; a++) nz += memory->data[a] != 0;
            fprintf(stderr, "%-6s nonzero %d / %d\n", r.name, nz, r.end - r.start);
        }
    }
    std::vector<int16_t> samples;
    double due = 0;
    uint8_t prev = 0;
    // PRESSES="frame:mask:length,..." (PICO-8 button bits)
    std::vector<std::array<int, 3>> presses;
    if (const char *ps = getenv("PRESSES")) {
        int f, m, l, n;
        while (sscanf(ps, "%d:%d:%d%n", &f, &m, &l, &n) == 3) {
            presses.push_back({f, m, l});
            ps += n;
            if (*ps == ',') ps++;
        }
    }
    FILE *fbHash = getenv("FB_HASH") ? fopen(getenv("FB_HASH"), "w") : nullptr;
    for (int i = 0; i < frames; i++) {
        uint8_t held = (press >= 0 && i >= press && i < press + 10) ? (1 << 4) : 0;
        for (auto &p : presses) if (i >= p[0] && i < p[0] + p[2]) held |= p[1];
        setInputState(held & ~prev, held, 0, 0, 0);
        prev = held;
        vm->Step();
        if (fbHash) {
            uint32_t h = 2166136261u;
            const uint8_t *fb = vm->GetPicoInteralFb();
            for (int k = 0; k < 8192; k++) h = (h ^ fb[k]) * 16777619u;
            fprintf(fbHash, "%d %08x\n", i, h);
            if (getenv("FB_DUMP") && atoi(getenv("FB_DUMP")) == i) {
                FILE *d = fopen("out/fb.dump", "wb");
                fwrite(fb, 1, 8192, d);
                fclose(d);
            }
        }
        due += 22050.0 / 60.0;
        int n = (int)due;
        due -= n;
        std::vector<int16_t> buf(n);
        audio->FillMonoAudioBuffer(buf.data(), 0, n);
        samples.insert(samples.end(), buf.begin(), buf.end());
        if (getenv("AUDIO_TRACE") && i % 30 == 0) {
            fprintf(stderr, "frame %d: music %d sfx %d %d %d %d\n", i, audio->getCurrentMusic(),
                audio->getCurrentSfxId(0), audio->getCurrentSfxId(1), audio->getCurrentSfxId(2), audio->getCurrentSfxId(3));
        }
    }

    FILE *w = fopen(argv[3], "wb");
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, w); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, w); };
    fwrite("RIFF", 1, 4, w); u32(36 + samples.size() * 2);
    fwrite("WAVEfmt ", 1, 8, w); u32(16); u16(1); u16(1); u32(22050); u32(44100); u16(2); u16(16);
    fwrite("data", 1, 4, w); u32(samples.size() * 2);
    fwrite(samples.data(), 2, samples.size(), w);
    fclose(w);
    return 0;
}
