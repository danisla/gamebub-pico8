// The audio core's program (see audio_core.h): runs the Audio calls sent by
// the main CPU, and keeps the audio FIFO filled.
//
// Its data (this file's and audio.cpp's) is its own (sw/link.ld). It doesn't
// use the C library's state (no malloc, no stdio): the main CPU owns it.

#include "audio_core.h"

#include <new>
#include <string.h>

#include "Audio.h"
#include "PicoRam.h"

namespace audio_core {

alignas(Audio) unsigned char engine_storage[sizeof(Audio)];

} // namespace audio_core

namespace {

using namespace audio_core;

volatile Mailbox *const mailbox = (volatile Mailbox *)SHARED_RAM;
volatile uint32_t *const mirror = SHARED_RAM + MirrorOffset / 4;

/// The audio core's copy of the PICO-8 memory (only the mirrored parts).
PicoRam ram;

/// Copy the chunks changed by the main CPU from the mirror.
void copyChanged() {
    for (int w = 0; w < DirtyWords; w++) {
        uint32_t bits = mailbox->dirty[w];
        if (bits == 0) continue;
        mailbox->dirty[w] = 0;
        for (int b = 0; b < 32; b++) {
            if (!(bits & (1u << b))) continue;
            int c = w * 32 + b;
            uint32_t *dst = (uint32_t *)&ram.data[chunkAddress(c)];
            for (int i = 0; i < ChunkWords; i++) dst[i] = mirror[c * ChunkWords + i];
        }
    }
}

void publishState(Audio *engine) {
    for (int ch = 0; ch < 4; ch++) {
        mailbox->sfx_id[ch] = engine->getCurrentSfxId(ch);
        mailbox->note[ch] = engine->getCurrentNoteNumber(ch);
    }
    mailbox->music_pattern = engine->getCurrentMusic();
    mailbox->music_count = engine->getMusicPatternCount();
    mailbox->music_tick = engine->getMusicTickCount();
}

void runCommand(Audio *engine) {
    copyChanged();
    int32_t result = 0;
    switch (mailbox->cmd) {
        case CmdReset:
            engine->resetAudioState();
            break;
        case CmdPause:
            engine->setPaused(mailbox->arg[0] != 0);
            break;
        case CmdSfx:
            result = engine->api_sfx(mailbox->arg[0], mailbox->arg[1], mailbox->arg[2], mailbox->arg[3]);
            break;
        case CmdMusic:
            engine->api_music(mailbox->arg[0], (int16_t)mailbox->arg[1], (int16_t)mailbox->arg[2]);
            break;
        default:
            break;
    }
    publishState(engine);
    mailbox->result = result;
    mailbox->done_seq = mailbox->cmd_seq;
}

} // namespace

extern "C" void core1_main() {
    Audio *engine = new (engine_storage) Audio(&ram);
    publishState(engine);
    mailbox->ready = ReadyMagic;

    // One control block (audio.cpp) at a time.
    constexpr int Block = 32;
    int16_t buffer[Block];
    uint32_t busy = 0, samples = 0;
    for (;;) {
        if (mailbox->cmd_seq != mailbox->done_seq) runCommand(engine);
        // Nothing is made while the core is paused by the menu (the main CPU
        // is stopped too).
        if (!(REG_STATUS & STATUS_FOCUS) || REG_AUDIO > TargetLevel - Block) continue;

        uint32_t t0 = REG_CYCLE_LO;
        engine->FillMonoAudioBuffer(buffer, 0, Block);
        for (int i = 0; i < Block; i++) REG_AUDIO = (uint16_t)buffer[i];
        publishState(engine);
        busy += REG_CYCLE_LO - t0;
        samples += Block;
        mailbox->busy_cycles = busy;
        mailbox->samples = samples;
    }
}
