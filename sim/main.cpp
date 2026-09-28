// Verilator testbench for the PICO-8 SoC.
//
// Loads the program and a cart into the SDRAM model (as the Game Bub host
// does), runs the CPU, and captures video frames (PPM) and audio (WAV).
//
// Usage: Vsim_top [options] pico8.bin [cart.p8|cart.p8.png]
//   --frames N        stop after N video frames (default 120)
//   --dump-every N    write every Nth frame to out/frame_NNNN.ppm (default 30)
//   --press F:B[:L]   hold buttons B (hex, Game Bub bits) from frame F for L frames (default 6)
//   --out DIR         output directory (default out)
//   --random-ram      fill the SDRAM with random data first (like real memory at power up)
//   --profile F       sample the CPU PC every 997 cycles from frame F; writes DIR/profile.txt

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vsim_top.h"
#include "Vsim_top___024root.h"
#include "Vsim_top__Syms.h"
#include "Vsim_top_sdram_model.h"
#include "Vsim_top_sim_top.h"
#ifndef PICO8_VEXII
#include "Vsim_top_VexRiscv.h"
#endif
#include <map>
#include "verilated.h"

namespace {

constexpr uint64_t ClockHz = 90'909'090;
constexpr uint32_t CartBase = 0x01F00000;
constexpr int Width = 128;
constexpr int Height = 128;
constexpr int AudioRate = 22050;

struct Press {
    int frame;
    int length;
    uint32_t buttons;
};

std::vector<uint8_t> readFile(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(1);
    }
    std::vector<uint8_t> data;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        data.insert(data.end(), buf, buf + n);
    }
    fclose(f);
    return data;
}

void writePpm(const std::string &path, const std::vector<uint8_t> &rgb) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
        perror(path.c_str());
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", Width, Height);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
}

void writeWav(const std::string &path, const std::vector<int16_t> &samples) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
        perror(path.c_str());
        return;
    }
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
    uint32_t dataSize = samples.size() * 2;
    fwrite("RIFF", 1, 4, f);
    u32(36 + dataSize);
    fwrite("WAVEfmt ", 1, 8, f);
    u32(16);
    u16(1);
    u16(1);
    u32(AudioRate);
    u32(AudioRate * 2);
    u16(2);
    u16(16);
    fwrite("data", 1, 4, f);
    u32(dataSize);
    fwrite(samples.data(), 2, samples.size(), f);
    fclose(f);
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    int maxFrames = 120;
    int dumpEvery = 30;
    std::string outDir = "out";
    std::vector<Press> presses;
    int profileFrom = -1;
    bool randomRam = false;
    std::vector<const char *> positional;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--frames" && i + 1 < argc) {
            maxFrames = atoi(argv[++i]);
        } else if (arg == "--dump-every" && i + 1 < argc) {
            dumpEvery = atoi(argv[++i]);
        } else if (arg == "--out" && i + 1 < argc) {
            outDir = argv[++i];
        } else if (arg == "--random-ram") {
            randomRam = true;
        } else if (arg == "--profile" && i + 1 < argc) {
            profileFrom = atoi(argv[++i]);
        } else if (arg == "--press" && i + 1 < argc) {
            Press p = {0, 6, 0};
            if (sscanf(argv[++i], "%d:%x:%d", &p.frame, &p.buttons, &p.length) < 2) {
                fprintf(stderr, "bad --press\n");
                return 1;
            }
            presses.push_back(p);
        } else if (arg[0] == '+') {
            // Verilator argument
        } else {
            positional.push_back(argv[i]);
        }
    }
    if (positional.empty()) {
        fprintf(stderr, "usage: %s [options] pico8.bin [cart]\n", argv[0]);
        return 1;
    }
    std::string mkdir = "mkdir -p " + outDir;
    if (system(mkdir.c_str()) != 0) return 1;

    auto top = std::make_unique<Vsim_top>();
    auto &mem = top->rootp->vlSymsp->TOP__sim_top.sdram->mem;

    // Load the program and cart (halfwords, little endian).
    auto load = [&](const std::vector<uint8_t> &data, uint32_t address) {
        for (size_t i = 0; i < data.size(); i += 2) {
            uint16_t lo = data[i];
            uint16_t hi = i + 1 < data.size() ? data[i + 1] : 0;
            mem[(address + i) >> 1] = lo | (hi << 8);
        }
    };
    if (randomRam) {
        uint32_t x = 0x9E3779B9;
        for (size_t i = 0; i < (1u << 24); i++) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            mem[i] = x & 0xFFFF;
        }
    }
    auto program = readFile(positional[0]);
    load(program, 0);
    uint32_t cartSize = 0;
    if (positional.size() > 1) {
        auto cart = readFile(positional[1]);
        load(cart, CartBase);
        cartSize = cart.size();
    }
    printf("[sim] program %zu bytes, cart %u bytes\n", program.size(), cartSize);

    top->focus = 1;
    top->buttons = 0;
    top->cart_size = cartSize;
    top->cpu_reset = 1;
    top->reset = 1;

    auto tick = [&]() {
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();
    };
    for (int i = 0; i < 8; i++) tick();
    top->reset = 0;

    std::vector<uint8_t> frame(Width * Height * 3);
    std::vector<int16_t> audio;
    int x = 0, y = 0, frames = 0;
    bool prevVblank = true, prevHblank = false;
    uint64_t cycle = 0;
    uint64_t audioPhase = 0;
    std::map<uint32_t, uint64_t> profile;
    auto *soc = top->rootp->vlSymsp->TOP__sim_top.soc;
#ifndef PICO8_VEXII
    auto *cpu = soc->vex__DOT__cpu;
#endif
    uint64_t profileCycles = 0, sdramBusy[4] = {}, sdramWriteBusy = 0, writeRequests = 0;
    while (!Verilated::gotFinish() && frames < maxFrames) {
        if (top->sdram_ready && top->cpu_reset) {
            printf("[sim] SDRAM ready at cycle %lu, starting CPU\n", (unsigned long)cycle);
            top->cpu_reset = 0;
        }

        uint32_t buttons = 0;
        for (const auto &p : presses) {
            if (frames >= p.frame && frames < p.frame + p.length) buttons |= p.buttons;
        }
        top->buttons = buttons;

        tick();
        cycle++;
        if (profileFrom >= 0 && frames >= profileFrom) {
#ifndef PICO8_VEXII
            if (cycle % 997 == 0) profile[cpu->lastStagePc]++;
#endif
            // SDRAM use by master (arbiter state != idle): 0 = data bus, 1 = instruction bus, 2 = host
            profileCycles++;
            if (soc->arb_state != 0) sdramBusy[soc->arb_master & 3]++;
            if (soc->arb_state != 0 && soc->arb_master == 0 && soc->sd_req_write) sdramWriteBusy++;
            if (soc->arb_state == 1 && soc->sd_req_write && soc->arb_master == 0) writeRequests += 0;
        }

        // Video capture (like the framework: hblank edge ends a line).
        if (top->vblank) {
            if (!prevVblank) {
                frames++;
                if (dumpEvery > 0 && frames % dumpEvery == 0) {
                    char name[64];
                    snprintf(name, sizeof(name), "/frame_%04d.ppm", frames);
                    writePpm(outDir + name, frame);
                }
                if (frames % 10 == 0) {
                    printf("[sim] frame %d (cycle %lu)\n", frames, (unsigned long)cycle);
                    fflush(stdout);
                }
            }
            x = 0;
            y = 0;
        } else if (top->hblank) {
            if (!prevHblank) {
                x = 0;
                y++;
            }
        } else if (top->pixel_valid) {
            if (x < Width && y < Height) {
                uint8_t *p = &frame[(y * Width + x) * 3];
                p[0] = top->pixel_r;
                p[1] = top->pixel_g;
                p[2] = top->pixel_b;
            }
            x++;
        }
        prevVblank = top->vblank;
        prevHblank = top->hblank;

        // Audio capture at the sample rate.
        audioPhase += AudioRate;
        if (audioPhase >= ClockHz) {
            audioPhase -= ClockHz;
            audio.push_back((int16_t)top->audio_l);
        }
    }
    if (!profile.empty()) {
        FILE *f = fopen((outDir + "/profile.txt").c_str(), "w");
        for (auto &[pc, n] : profile) fprintf(f, "%08x %lu\n", pc, (unsigned long)n);
        fclose(f);
        printf("[sim] SDRAM busy: data bus %.1f%%, instruction bus %.1f%% of %lu cycles\n",
            100.0 * sdramBusy[0] / profileCycles, 100.0 * sdramBusy[1] / profileCycles,
            (unsigned long)profileCycles);
        printf("[sim] of which data bus writes: %.1f%%\n", 100.0 * sdramWriteBusy / profileCycles);
    }
    if (getenv("ARB_DEBUG")) {
        printf("[sim] arbiter state %d master %d write %d\n", (int)soc->arb_state, (int)soc->arb_master, (int)soc->sd_req_write);
    }
    writePpm(outDir + "/last.ppm", frame);
    writeWav(outDir + "/audio.wav", audio);
    printf("[sim] done: %d frames, %lu cycles, save size %u\n", frames, (unsigned long)cycle,
        (unsigned)top->save_size);
    top->final();
    return 0;
}
