// The audio core: a second CPU that runs the PICO-8 synthesizer (audio.cpp)
// and fills the audio FIFO, so that the main CPU only runs the VM.
//
// The main CPU's Audio object (used by fake-08) becomes a proxy: its calls
// (sfx(), music(), resets, pauses) are sent to the audio core's Audio object
// (the engine) and wait for it to be done, and stat() reads the engine's
// state as published by the audio core. The caches aren't coherent, so the
// CPUs only exchange data through the shared RAM (uncached):
//
// * The mailbox (Mailbox, at the start of the shared RAM): a command, done
//   when done_seq == cmd_seq, and the engine's state.
// * A mirror of the PICO-8 memory the synthesizer reads (music, SFX, the
//   draw and hardware state at 0x5F00-0x5F7F), in 64 byte chunks. The main
//   CPU copies the changed chunks into it before commands (and once per
//   frame), and the audio core copies them into its own copy of the PICO-8
//   memory.
//
// Each CPU keeps its own data in the SDRAM apart from the other's (see
// sw/link.ld): the audio core's is audio.o's and audio_core1.o's.
#pragma once

#include <stdint.h>

#include "hw.h"

class Audio;
struct PicoRam;

namespace audio_core {

/// Mailbox commands
enum Command : uint32_t {
    CmdSync = 0,   // only copy the changed memory
    CmdReset,      // resetAudioState()
    CmdPause,      // setPaused(arg[0])
    CmdSfx,        // api_sfx(arg[0..3]) -> result
    CmdMusic,      // api_music(arg[0..2])
};

constexpr uint32_t ReadyMagic = 0x41554431; // "AUD1"

/// Mirrored memory: 72 chunks for 0x3100-0x42FF (music, SFX), then 2 for
/// 0x5F00-0x5F7F.
constexpr int ChunkBytes = 64;
constexpr int ChunkWords = ChunkBytes / 4;
constexpr int SfxChunks = (0x4300 - 0x3100) / ChunkBytes;
constexpr int Chunks = SfxChunks + 2;
constexpr int DirtyWords = (Chunks + 31) / 32;
constexpr uint32_t MirrorOffset = 0x400; // in the shared RAM

inline uint32_t chunkAddress(int chunk) {
    return chunk < SfxChunks ? 0x3100 + chunk * ChunkBytes : 0x5F00 + (chunk - SfxChunks) * ChunkBytes;
}

/// Mailbox (in the shared RAM, word accesses only)
struct Mailbox {
    // Written by the main CPU
    uint32_t cmd_seq;
    uint32_t cmd;
    int32_t arg[4];
    /// Mirror chunks changed since the last command (cleared by the audio core)
    uint32_t dirty[DirtyWords];
    // Written by the audio core
    uint32_t ready;
    uint32_t done_seq;
    int32_t result;
    /// Engine state (for stat())
    int32_t sfx_id[4];
    int32_t note[4];
    int32_t music_pattern;
    int32_t music_count;
    int32_t music_tick;
    /// Cycles spent making samples, samples made (wrapping)
    uint32_t busy_cycles;
    uint32_t samples;
};

static_assert(sizeof(Mailbox) <= 0x3F4, "mailbox too large");
// Written by the audio core's trap handler (crt0.S)
#define AUDIO_TRAPPED    (SHARED_RAM[0x3F4 / 4])
#define AUDIO_TRAP_CAUSE (SHARED_RAM[0x3F8 / 4])
#define AUDIO_TRAP_PC    (SHARED_RAM[0x3FC / 4])
static_assert(MirrorOffset + Chunks * ChunkBytes <= 8192, "mirror too large");

/// Audio FIFO level kept by the audio core (samples, ~23 ms).
constexpr uint32_t TargetLevel = 512;

/// The engine (constructed by the audio core, in its data).
extern unsigned char engine_storage[];
/// The main CPU's calls go to the audio core (set by start()).
extern bool remote_enabled;

inline bool remote(const Audio *audio) {
    return (const void *)audio != (const void *)engine_storage && remote_enabled;
}

// Main CPU (audio_core.cpp)

/// Start the audio core, before the Audio object is made. Returns whether it
/// runs the audio (otherwise the main CPU makes the samples, as before).
bool start(PicoRam *memory);
/// Once per frame: copy the changed memory.
void frame();

int sfx(int sfx, int channel, int offset, int length);
void music(int pattern, int16_t fade_len, int16_t mask);
void reset();
void pause(bool paused);

int16_t sfxId(int channel);
int noteNumber(int channel);
int16_t musicPattern();
int16_t musicCount();
int16_t musicTick();

struct Stats {
    uint32_t busyCycles;
    uint32_t samples;
};
Stats stats();

} // namespace audio_core

// Audio core (audio_core1.cpp), called by crt0.S
extern "C" void core1_main();
