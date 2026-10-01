// fake-08 platform for the Game Bub PICO-8 core.
//
// The cart is loaded into memory by the Game Bub host before the CPU starts.
// Each video frame (60 Hz) the VM is stepped once and the PICO-8 screen is
// copied to the hardware framebuffer. The audio core fills the audio FIFO
// (audio_core.h); without one, the audio FIFO is topped up after each step.
// With the graphics accelerator (gfx.h), the PICO-8 RAM is its block RAM, it
// draws most of the graphics, and it copies the screen to the framebuffer.

#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include <new>

#include "Audio.h"
#include "PicoRam.h"
#include "host.h"
#include "hostVmShared.h"
#include "logger.h"
#include "vm.h"
#include "miniz.h"
#include "audio_core.h"
#include "gfx.h"

extern "C" {
#include "hw.h"
#include "syscalls.h"
}

namespace gfx {
bool enabled;
uint32_t presentsSent;
uint32_t sentPalette[4];
bool paletteSent;
}

namespace {

InputState_t inputState;
/// Buttons newly pressed since the cart last read the buttons.
uint8_t pendingDown;

/// Target audio FIFO level (samples): ~4 frames at 60 Hz.
constexpr uint32_t AudioTargetLevel = 1536;
int16_t audioBuffer[AudioTargetLevel];

/// Steps between performance reports (on the console / in the log). Set with
/// -DPERF_INTERVAL=n (the simulation uses 10).
#ifndef PERF_INTERVAL
#define PERF_INTERVAL 300
#endif
constexpr uint32_t PerfInterval = PERF_INTERVAL;

/// Display colors (RGB888) for the 144 PICO-8 palette indices.
uint32_t paletteRgb[144];

/// Screen buffer after applying the screen mode.
uint8_t screenBuffer[128 * 64];

// PICO-8 buttons
constexpr uint8_t P8_LEFT = 1 << 0;
constexpr uint8_t P8_RIGHT = 1 << 1;
constexpr uint8_t P8_UP = 1 << 2;
constexpr uint8_t P8_DOWN = 1 << 3;
constexpr uint8_t P8_O = 1 << 4;
constexpr uint8_t P8_X = 1 << 5;
constexpr uint8_t P8_PAUSE = 1 << 6;

uint8_t mapButtons(uint32_t buttons) {
    uint8_t ret = 0;
    if (buttons & BTN_LEFT) ret |= P8_LEFT;
    if (buttons & BTN_RIGHT) ret |= P8_RIGHT;
    if (buttons & BTN_UP) ret |= P8_UP;
    if (buttons & BTN_DOWN) ret |= P8_DOWN;
    // As in the fake-08 libretro core: B (bottom) is O, A (right) is X.
    if (buttons & (BTN_B | BTN_Y)) ret |= P8_O;
    if (buttons & (BTN_A | BTN_X)) ret |= P8_X;
    if (buttons & BTN_START) ret |= P8_PAUSE;
    return ret;
}

inline uint8_t getPixel(const uint8_t *fb, int x, int y) {
    uint8_t b = fb[(y << 6) | (x >> 1)];
    return (x & 1) ? (b >> 4) : (b & 0xF);
}

inline void setPixel(uint8_t *fb, int x, int y, uint8_t c) {
    uint8_t &b = fb[(y << 6) | (x >> 1)];
    b = (x & 1) ? ((b & 0x0F) | (c << 4)) : ((b & 0xF0) | c);
}

/// Apply the screen mode (0x5F2C): stretching, mirroring, rotation.
const uint8_t *applyScreenMode(const uint8_t *fb, uint8_t mode) {
    if (mode == 0) return fb;
    for (int y = 0; y < 128; y++) {
        for (int x = 0; x < 128; x++) {
            int sx = x, sy = y;
            switch (mode) {
                case 1: sx = x >> 1; break;                  // horizontal stretch
                case 2: sy = y >> 1; break;                  // vertical stretch
                case 3: sx = x >> 1; sy = y >> 1; break;     // both
                case 5: sx = x < 64 ? x : 127 - x; break;    // horizontal mirror
                case 6: sy = y < 64 ? y : 127 - y; break;    // vertical mirror
                case 7: sx = x < 64 ? x : 127 - x; sy = y < 64 ? y : 127 - y; break;
                case 129: sx = 127 - x; break;               // horizontal flip
                case 130: sy = 127 - y; break;               // vertical flip
                case 131: sx = 127 - x; sy = 127 - y; break;
                case 133: sx = y; sy = 127 - x; break;       // rotate 90
                case 134: sx = 127 - x; sy = 127 - y; break; // rotate 180
                case 135: sx = 127 - y; sy = x; break;       // rotate 270
                default: return fb;
            }
            setPixel(screenBuffer, x, y, getPixel(fb, sx, sy));
        }
    }
    return screenBuffer;
}

/// The host sends files as 32-bit words: the last 1-3 bytes of a file whose
/// size isn't a multiple of 4 never arrive (the FPGA's SPI receiver drops the
/// partial word). Repair what can be repaired:
/// * PNG carts end with the IEND chunk, which is always the same 12 bytes.
/// * Text carts: if the last bytes don't look like text (leftover memory),
///   replace them with newlines. (With firmware that pads the last word, they
///   arrive intact.)
void fixCartTail(uint8_t *cart, uint32_t &size) {
    if ((size & 3) == 0) return;
    static const uint8_t pngSignature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    static const uint8_t pngEnd[12] = {0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82};
    if (size >= 20 && memcmp(cart, pngSignature, 8) == 0) {
        memcpy(cart + size - 12, pngEnd, 12);
        printf("cart: restored the PNG end (%lu bytes not transferred)\n", (unsigned long)(size & 3));
    } else {
        uint32_t n = size & 3;
        bool text = true;
        for (uint32_t i = size - n; i < size; i++) {
            uint8_t c = cart[i];
            if (!(c == '\t' || c == '\n' || c == '\r' || (c >= 0x20 && c < 0x7F))) text = false;
        }
        if (!text) {
            memset(cart + size - n, '\n', n);
            printf("cart: replaced the last %lu bytes (not transferred)\n", (unsigned long)n);
        }
    }
}

/// Evict the data cache (32 KiB, direct mapped) by reading 64 KiB elsewhere.
void flushDataCache() {
    volatile uint32_t *p = (volatile uint32_t *)0x01C00000;
    uint32_t sum = 0;
    for (int i = 0; i < 16384; i += 8) sum += p[i];
    (void)sum;
}

/// Diagnostics, written to the console (the log file): cart block checksums
/// (read twice), to compare with the file (scripts/check_cart_log.py).
void runDiagnostics(uint32_t cartSize) {
    const uint8_t *cart = (const uint8_t *)CART_BASE;
    for (int pass = 0; pass < 2; pass++) {
        flushDataCache();
        printf("[diag] cart crc32 per KiB, read %d:", pass + 1);
        for (uint32_t off = 0; off < cartSize; off += 1024) {
            uint32_t n = cartSize - off < 1024 ? cartSize - off : 1024;
            printf("%s%08lx", (off / 1024) % 8 == 0 ? "\n  " : " ", (unsigned long)mz_crc32(0, cart + off, n));
        }
        printf("\n[diag] cart crc32 total %08lx\n", (unsigned long)mz_crc32(0, cart, cartSize));
    }

}

} // namespace

////////////////////////////////////////////////////////////////////////////
// Host
////////////////////////////////////////////////////////////////////////////

Host::Host(int windowWidth, int windowHeight) {
    (void)windowWidth;
    (void)windowHeight;
}

void Host::oneTimeSetup(Audio *audio) {
    (void)audio;
    loadSettingsIni();
}

void Host::oneTimeCleanup() {}

void Host::setTargetFps(int targetFps) {
    (void)targetFps;
}

void Host::changeStretch() {}

void Host::forceStretch(StretchOption newStretch) {
    (void)newStretch;
}

InputState_t Host::scanInput() {
    // New presses (btnp) are kept until the cart reads the buttons: 30 fps
    // carts read them every other step, so a press starting on the other step
    // would be missed.
    InputState_t state = inputState;
    state.KDown = pendingDown;
    pendingDown = 0;
    return state;
}

bool Host::shouldQuit() {
    return false;
}

void Host::waitForTargetFps() {}

/// Frames not shown because the previous one was still waiting to be shown.
uint32_t droppedFrames;

void Host::drawFrame(uint8_t *picoFb, uint8_t *screenPaletteMap, uint8_t drawMode) {
    if (gfx::enabled) {
        if (drawMode == 0 && picoFb == (uint8_t *)PICO8_RAM + 0x6000) {
            // After the frame's drawing commands (waits there while 2 frames
            // are waiting to be shown: every frame is shown).
            uint32_t rgb[16];
            for (int i = 0; i < 16; i++) rgb[i] = paletteRgb[screenPaletteMap[i]];
            gfx::present(0x6000, rgb);
            return;
        }
        // The CPU writes the framebuffer, after the queued commands.
        gfx::waitIdle();
    }
    // Queued frames are shown one per video frame (triple buffered). If 2 are
    // still waiting (the cart is running behind, or this is the idle step of
    // a 30 fps cart), drop this frame instead of waiting.
    if (REG_VIDEO_CTRL & VIDEO_CTRL_FLIP_PENDING) {
        droppedFrames++;
        return;
    }

    const uint32_t *src = (const uint32_t *)applyScreenMode(picoFb, drawMode);
    for (int i = 0; i < 2048; i++) {
        FRAMEBUFFER[i] = src[i];
    }
    for (int i = 0; i < 16; i++) {
        REG_PALETTE(i) = paletteRgb[screenPaletteMap[i]];
    }
    REG_VIDEO_CTRL = 1;
}

bool Host::shouldFillAudioBuff() {
    return false;
}

void *Host::getAudioBufferPointer() {
    return nullptr;
}

size_t Host::getAudioBufferSize() {
    return 0;
}

void Host::playFilledAudioBuffer() {}

bool Host::shouldRunMainLoop() {
    return true;
}

std::vector<std::string> Host::listcarts() {
    return {};
}

std::string Host::customBiosLua() {
    return "";
}

std::string Host::getCartDirectory() {
    return _cartDirectory;
}

std::vector<std::string> Host::listdirs() {
    return {};
}

void Host::overrideLogFilePrefix(const char *newPrefix) {
    _logFilePrefix = newPrefix;
}

const char *Host::logFilePrefix() {
    return _logFilePrefix.c_str();
}

////////////////////////////////////////////////////////////////////////////
// Main loop
////////////////////////////////////////////////////////////////////////////

int main() {
    printf("PICO-8 core (fake-08) for Game Bub\n");
    uint32_t clockHz = REG_CLOCK_HZ;
    uint32_t cartSize = REG_CART_SIZE;
    printf("clock %lu Hz, cart %lu bytes\n", (unsigned long)clockHz, (unsigned long)cartSize);

    if (cartSize > CART_MAX) cartSize = 0;
    fixCartTail((uint8_t *)CART_BASE, cartSize);
    runDiagnostics(cartSize);
    fs_init();

    Host *host = new Host();
    // With the graphics accelerator, the PICO-8 RAM is its block RAM.
    gfx::enabled = (REG_GFX_STATUS & GFX_PRESENT) != 0;
    printf("graphics accelerator: %s\n", gfx::enabled ? "yes" : "no");
    PicoRam *memory = gfx::enabled ? new ((void *)PICO8_RAM) PicoRam() : new PicoRam();
    memory->Reset();
    // Before the Audio object: it becomes the audio core's proxy.
    bool audioCore = audio_core::start(memory);
    Audio *audio = new Audio(memory);
    Logger_Initialize("");
    Vm *vm = new Vm(host, memory, nullptr, nullptr, audio);

    host->setUpPaletteColors();
    Color *colors = host->GetPaletteColors();
    for (int i = 0; i < 144; i++) {
        paletteRgb[i] = (colors[i].Red << 16) | (colors[i].Green << 8) | colors[i].Blue;
    }
    host->oneTimeSetup(audio);

    if (cartSize > 0 && cartSize <= CART_MAX) {
        vm->QueueCartChange((const unsigned char *)CART_BASE, cartSize);
    } else {
        vm->QueueCartChange("__FAKE08-BIOS.p8");
    }

    // Cart data (0x5E00-0x5EFF) as last saved.
    uint8_t cartDataSaved[0x100];
    memcpy(cartDataSaved, &memory->data[0x5E00], sizeof(cartDataSaved));

    uint8_t heldPrev = 0;
    uint32_t nextFrame = REG_FRAME_COUNT + 1;
    uint32_t steps = 0;
    uint32_t skipped = 0;
    uint64_t stepCycles = 0;
    uint64_t audioCycles = 0;
    audio_core::Stats audioStats = audio_core::stats();
    uint32_t underruns = REG_AUDIO_UNDERRUNS;
    uint32_t gfxWaits = REG_GFX_WAITS;
    for (;;) {
        // One step per video frame: wait for the step's frame (and while the
        // menu is open). When running behind, steps run back to back, up to
        // 2 frames behind (one frame of a 30 fps cart), instead of waiting.
        // With the accelerator, frames aren't dropped: they wait to be shown
        // (up to 2, then PRESENT waits, and the accelerator with it). Don't
        // get further ahead than 1 frame waiting (after catching up, the
        // queue would stay full: a frame of latency, and the CPU waiting on
        // the accelerator mid-step).
        while (gfx::enabled && gfx::framesAhead() >= 2) {}
        uint32_t frame;
        while ((int32_t)((frame = REG_FRAME_COUNT) - nextFrame) < 0 || !(REG_STATUS & STATUS_FOCUS)) {}
        if ((int32_t)(frame - nextFrame) > 2) {
            skipped += frame - nextFrame - 2;
            nextFrame = frame - 2;
        }
        nextFrame++;

        uint8_t held = mapButtons(REG_BUTTONS);
        pendingDown |= held & ~heldPrev;
        inputState.KHeld = held;
        heldPrev = held;

        uint64_t t0 = hw_cycles();
        vm->Step();
        host->drawFrame(vm->GetPicoInteralFb(), vm->GetScreenPaletteMap(), memory->drawState.drawMode);
        uint64_t t1 = hw_cycles();

        uint32_t level = REG_AUDIO;
        if (audioCore) {
            audio_core::frame();
        } else if (level < AudioTargetLevel) {
            uint32_t n = AudioTargetLevel - level;
            audio->FillMonoAudioBuffer(audioBuffer, 0, n);
            for (uint32_t i = 0; i < n; i++) {
                REG_AUDIO = (uint16_t)audioBuffer[i];
            }
        }
        uint64_t t2 = hw_cycles();

        if (steps < 20 && !audioCore) {
            printf("[step %lu] step %lu kcycles, audio %lu kcycles (%lu samples)\n", (unsigned long)steps,
                (unsigned long)((t1 - t0) / 1000), (unsigned long)((t2 - t1) / 1000),
                (unsigned long)(level < AudioTargetLevel ? AudioTargetLevel - level : 0));
        }
        // fake-08 saves the cart data when the cart is closed, but the core
        // is just stopped by the host: save it when it changes.
        if (steps % 30 == 0 && memcmp(cartDataSaved, &memory->data[0x5E00], sizeof(cartDataSaved)) != 0) {
            memcpy(cartDataSaved, &memory->data[0x5E00], sizeof(cartDataSaved));
            vm->flushCartData();
        }

        stepCycles += t1 - t0;
        audioCycles += t2 - t1;
        steps++;
        if (steps < 20 && audioCore) {
            printf("[step %lu] step %lu kcycles, audio sync %lu kcycles (FIFO %lu samples)\n", (unsigned long)steps,
                (unsigned long)((t1 - t0) / 1000), (unsigned long)((t2 - t1) / 1000), (unsigned long)level);
        }
        if (steps % PerfInterval == 0) {
            uint64_t intervalCycles = (uint64_t)PerfInterval * clockHz / 60;
            printf("[perf] frames %lu: step %lu%% audio %lu%% (of 60 Hz), skipped %lu, dropped %lu, heap %u KiB, misaligned %lu\n",
                (unsigned long)steps,
                (unsigned long)(stepCycles * 100 / intervalCycles),
                (unsigned long)(audioCycles * 100 / intervalCycles),
                (unsigned long)skipped, (unsigned long)droppedFrames, (unsigned)(heap_used() / 1024), (unsigned long)misaligned_trap_count());
            if (gfx::enabled) {
                uint32_t waits = REG_GFX_WAITS;
                printf("[perf] graphics: frames waiting to be shown %lu\n", (unsigned long)(waits - gfxWaits));
                gfxWaits = waits;
            }
            uint32_t newUnderruns = REG_AUDIO_UNDERRUNS;
            if (audioCore) {
                audio_core::Stats s = audio_core::stats();
                printf("[perf] audio core: busy %lu%%, %lu samples, underruns %lu\n",
                    (unsigned long)((uint64_t)(s.busyCycles - audioStats.busyCycles) * 100 / intervalCycles),
                    (unsigned long)(s.samples - audioStats.samples), (unsigned long)(newUnderruns - underruns));
                audioStats = s;
            }
            underruns = newUnderruns;
            stepCycles = 0;
            audioCycles = 0;
            droppedFrames = 0;
            skipped = 0;
        }
    }
}
