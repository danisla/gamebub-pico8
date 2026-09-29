// The audio core, main CPU side: starts the audio core, sends it the Audio
// calls and the changed memory, reads its state (see audio_core.h).

#include "audio_core.h"

#include <stdio.h>
#include <string.h>

#include "PicoRam.h"

// sw/link.ld
extern "C" uint32_t __core1_data_start[], __core1_data_end[], __core1_data_load[];
extern "C" uint32_t __core1_bss_start[], __core1_bss_end[];

namespace audio_core {

bool remote_enabled;

namespace {

volatile Mailbox *const mailbox = (volatile Mailbox *)SHARED_RAM;
volatile uint32_t *const mirror = SHARED_RAM + MirrorOffset / 4;

PicoRam *memory;
/// The mirrored memory as last sent (the audio core's copy starts zeroed).
uint32_t sent[Chunks * ChunkWords];
uint32_t seq;
/// The audio core stopped answering: the audio is stopped.
bool failed;

/// Wait limit (cycles): far more than a command takes.
constexpr uint64_t Timeout = 20000000;

/// For the main CPU making the samples: initialize the synthesizer's data
/// (the audio core's, which the main CPU otherwise never touches).
void initCore1Data() {
    memcpy(__core1_data_start, __core1_data_load, (__core1_data_end - __core1_data_start) * 4);
    memset(__core1_bss_start, 0, (__core1_bss_end - __core1_bss_start) * 4);
}

void reportFailure(const char *what) {
    failed = true;
    printf("[audio] the audio core %s (trap cause %lu at %08lx): audio stopped\n", what,
        (unsigned long)AUDIO_TRAP_CAUSE, (unsigned long)AUDIO_TRAP_PC);
}

/// Copy the changed chunks in [first, last] to the mirror; returns whether
/// any changed.
bool syncChunks(int first, int last) {
    bool changed = false;
    for (int c = first; c <= last; c++) {
        const uint32_t *src = (const uint32_t *)&memory->data[chunkAddress(c)];
        uint32_t *old = &sent[c * ChunkWords];
        if (memcmp(src, old, ChunkBytes) == 0) continue;
        for (int i = 0; i < ChunkWords; i++) {
            old[i] = src[i];
            mirror[c * ChunkWords + i] = src[i];
        }
        mailbox->dirty[c / 32] |= 1u << (c % 32);
        changed = true;
    }
    return changed;
}

bool syncAll() {
    return syncChunks(0, Chunks - 1);
}

/// Memory an sfx() reads: the SFX (and the custom instruments, SFX 0-7), and
/// the draw and hardware state.
void syncSfx(int sfx) {
    auto chunkOf = [](uint32_t address) { return (int)(address - 0x3100) / ChunkBytes; };
    syncChunks(chunkOf(0x3200), chunkOf(0x3200 + 8 * 68 - 1));
    if (sfx >= 0 && sfx < 64) syncChunks(chunkOf(0x3200 + sfx * 68), chunkOf(0x3200 + sfx * 68 + 67));
    syncChunks(SfxChunks, Chunks - 1);
}

int32_t call(Command cmd, int32_t a0 = 0, int32_t a1 = 0, int32_t a2 = 0, int32_t a3 = 0) {
    if (failed) return 0;
    mailbox->cmd = cmd;
    mailbox->arg[0] = a0;
    mailbox->arg[1] = a1;
    mailbox->arg[2] = a2;
    mailbox->arg[3] = a3;
    mailbox->cmd_seq = ++seq;
    uint64_t start = hw_cycles();
    while (mailbox->done_seq != seq) {
        if (hw_cycles() - start > Timeout) {
            reportFailure("isn't answering");
            return 0;
        }
    }
    return mailbox->result;
}

} // namespace

bool start(PicoRam *mem) {
    memory = mem;
    if (!(REG_CORE1_CTRL & CORE1_PRESENT)) {
        printf("[audio] no audio core: audio on the main CPU\n");
        initCore1Data();
        return false;
    }
    for (int i = 0; i < 0x400 / 4; i++) SHARED_RAM[i] = 0;
    REG_CORE1_CTRL = CORE1_RUN;
    uint64_t t0 = hw_cycles();
    while (mailbox->ready != ReadyMagic) {
        if (hw_cycles() - t0 > Timeout) {
            // Not started: the main CPU makes the samples.
            REG_CORE1_CTRL = 0;
            printf("[audio] the audio core didn't start (trap cause %lu at %08lx): audio on the main CPU\n",
                (unsigned long)AUDIO_TRAP_CAUSE, (unsigned long)AUDIO_TRAP_PC);
            initCore1Data();
            return false;
        }
    }
    printf("[audio] audio core started (%lu kcycles)\n", (unsigned long)((hw_cycles() - t0) / 1000));
    remote_enabled = true;
    return true;
}

void frame() {
    if (failed) return;
    if (syncAll()) call(CmdSync);
    if (AUDIO_TRAPPED) reportFailure("stopped");
}

int sfx(int sfx, int channel, int offset, int length) {
    syncSfx(sfx);
    return call(CmdSfx, sfx, channel, offset, length);
}

void music(int pattern, int16_t fade_len, int16_t mask) {
    syncAll();
    call(CmdMusic, pattern, fade_len, mask);
}

void reset() {
    syncAll();
    call(CmdReset);
}

void pause(bool paused) {
    call(CmdPause, paused);
}

int16_t sfxId(int channel) {
    return (int16_t)mailbox->sfx_id[channel & 3];
}

int noteNumber(int channel) {
    return mailbox->note[channel & 3];
}

int16_t musicPattern() {
    return (int16_t)mailbox->music_pattern;
}

int16_t musicCount() {
    return (int16_t)mailbox->music_count;
}

int16_t musicTick() {
    return (int16_t)mailbox->music_tick;
}

Stats stats() {
    return {mailbox->busy_cycles, mailbox->samples};
}

} // namespace audio_core
