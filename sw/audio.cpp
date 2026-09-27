// PICO-8 audio for the Game Bub PICO-8 core.
//
// A replacement for fake-08's Audio.cpp and synth.cpp (MIT / WTFPL, based on
// zepto8), with the same Audio interface. The CPU has no FPU, and fake-08
// updates the note state (in double precision) and synthesizes the waveforms
// (in single precision) for every sample, which is far too slow in software
// floating point. Here:
//
// * The note state (music, SFX, effects, custom instruments) is updated at a
//   control rate, once per block of BLOCK samples, with fake-08's logic.
// * The waveforms, crossfades, reverb, dampening filters and distortion are
//   computed per sample in fixed point.
//
// Values are Q16 (1.0 = 65536) unless noted.

#include "Audio.h"
#include "filter.h"
#include "hostVmShared.h"
#include "mathhelpers.h"
#include "synth.h"

#include <algorithm>
#include <cassert>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace {

constexpr int SampleRate = 22050;
/// Samples per control update (~1.5 ms).
constexpr int Block = 32;
constexpr int32_t One = 1 << 16;
/// Samples to keep running a channel after it goes silent (reverb and filter tails).
constexpr int TailSamples = 8192;

/// Fixed point synth parameters (the per-sample state of a waveform).
struct FixedSynth {
    uint8_t instrument = 0;
    uint8_t filters = 0;
    uint8_t key = 0;
    bool active = false;
    /// Phase (cycles, Q24: 8 integer bits, 24 fraction bits), and its increment per sample.
    uint32_t phase = 0;
    uint32_t inc = 0;
    /// Phaser: second triangle phase (frequency * 109/110).
    uint32_t phase2 = 0;
    uint32_t inc2 = 0;
    /// Detune: second wave.
    uint8_t detune_instrument = 0;
    bool detune = false;
    uint32_t dphase = 0;
    uint32_t dinc = 0;
    uint32_t dphase2 = 0;
    uint32_t dinc2 = 0;
    /// Channel volume (including the music/sfx master volume), Q16.
    int32_t volume = 0;
    /// Noise state
    int32_t noise_last = 0;
    int32_t noise_scale = 0;      // Q16
    int32_t noise_inv = One;      // 1 / (1 + scale), Q16
    int32_t noise_gain = 0;       // 1.5 * (1 + factor^2), Q16
};

struct Biquad {
    // Q12 coefficients
    int32_t c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0;
    int32_t x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    void init(const z8::filter &f) {
        c1 = (int32_t)lrintf(f.c1 * 4096.f);
        c2 = (int32_t)lrintf(f.c2 * 4096.f);
        c3 = (int32_t)lrintf(f.c3 * 4096.f);
        c4 = (int32_t)lrintf(f.c4 * 4096.f);
        c5 = (int32_t)lrintf(f.c5 * 4096.f);
        x1 = x2 = y1 = y2 = 0;
    }

    /// Input and output: Q15-ish samples.
    int32_t run(int32_t x) {
        int32_t y = (c1 * x + c2 * x1 + c3 * x2 - c4 * y1 - c5 * y2) >> 12;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        return y;
    }
};

struct ChannelState {
    FixedSynth synth;
    FixedSynth fade_synth;
    /// Crossfade from fade_synth to synth, Q16 (0 when done).
    int32_t fade = 0;
    int tail = 0;
    /// Reverb delay line positions (reverb_index % 366, reverb_index % 732)
    int reverb_i2 = 0;
    int reverb_i4 = 0;
    int16_t reverb_2[366] = {};
    int16_t reverb_4[732] = {};
    Biquad damp1;
    Biquad damp2;
};

ChannelState channels[4];
/// Per channel: the (sfx, note) played in the last control block.
int last_note_tag[4] = {-1, -1, -1, -1};
uint32_t noise_seed = 0x12345678;

/// Frequencies (Hz) of the 64 PICO-8 keys.
float key_freq[64];

float key_to_freq(int key) {
    return key_freq[key & 63];
}

inline int32_t fix_abs(int32_t x) {
    return x < 0 ? -x : x;
}

/// Q16 multiply
inline int32_t fmul(int32_t a, int32_t b) {
    return (int32_t)(((int64_t)a * b) >> 16);
}

inline int32_t noise_rand() {
    // Uniform in [-1, 1) (Q16)
    noise_seed = noise_seed * 1664525u + 1013904223u;
    return (int32_t)(noise_seed >> 15) - One;
}

/// Constants
constexpr int32_t Q(double x) {
    return (int32_t)(x * 65536.0 + (x < 0 ? -0.5 : 0.5));
}

/// Waveform value (Q16) at phase `phase` (cycles, Q24). Follows z8::synth::waveform.
__attribute__((always_inline)) inline int32_t waveform(uint8_t instrument, uint8_t filters, uint32_t phase, uint32_t phase2, FixedSynth *noise) {
    int32_t t = (phase >> 8) & 0xFFFF;
    bool noiz = filters & 0x2;
    bool buzz = filters & 0x4;
    switch (instrument) {
        case z8::synth::INST_TRIANGLE: {
            int32_t ret = One - fix_abs(4 * t - 2 * One);
            if (buzz) {
                // averaged with a tilted saw (a = 0.875)
                int32_t bret = t < Q(0.875) ? fmul(2 * t, Q(1.0 / 0.875)) - One
                                            : 16 * (One - t) - One;
                ret = fmul(ret, Q(0.75)) + (bret >> 2);
            }
            return ret >> 1;
        }
        case z8::synth::INST_TILTED_SAW: {
            int32_t ret;
            if (buzz) {
                ret = t < Q(0.975) ? fmul(2 * t, Q(1.0 / 0.975)) - One : 80 * (One - t) - One;
            } else {
                ret = t < Q(0.875) ? fmul(2 * t, Q(1.0 / 0.875)) - One : 16 * (One - t) - One;
            }
            return ret >> 1;
        }
        case z8::synth::INST_SAW: {
            int32_t ret = t < Q(0.5) ? t : t - One;
            if (buzz) {
                // fmod(advance, 2): phase modulo 2 cycles
                int32_t t2 = (phase >> 8) & 0x1FFFF;
                ret = fmul(ret, Q(0.83)) - (fix_abs(t2 - One) < Q(0.5) ? Q(0.085) : 0);
            }
            return fmul(ret, Q(0.653));
        }
        case z8::synth::INST_SQUARE:
            return t < (buzz ? Q(0.4) : Q(0.5)) ? Q(0.25) : -Q(0.25);
        case z8::synth::INST_PULSE:
            return t < (buzz ? Q(0.255) : Q(0.316)) ? Q(0.25) : -Q(0.25);
        case z8::synth::INST_ORGAN: {
            int32_t ret = t < Q(0.5) ? 3 * One - fix_abs(24 * t - 6 * One)
                                     : One - fix_abs(16 * t - 12 * One);
            if (buzz) {
                ret = t < Q(0.5) ? ret * 2 + 3 * One : ret;
                ret = (t < Q(0.5) && ret > -Q(1.875)) ? fmul(ret, Q(0.2)) - One : ret + Q(0.5);
            }
            return ret / 9;
        }
        case z8::synth::INST_NOISE: {
            if (!noise) return 0;
            int32_t new_sample = fmul(noise->noise_last + fmul(noise->noise_scale, noise_rand()), noise->noise_inv);
            noise->noise_last = new_sample;
            int32_t ret = fmul(new_sample, noise->noise_gain);
            if (noiz) {
                ret = fmul(ret, 2 * (t < Q(0.5) ? t : t - One));
            }
            return ret;
        }
        case z8::synth::INST_PHASER: {
            int32_t t2 = (phase2 >> 8) & 0xFFFF;
            int32_t ret = 2 * One - fix_abs(8 * t - 4 * One);
            ret += One - fix_abs(4 * t2 - 2 * One);
            if (buzz) {
                int32_t a = (int32_t)(((phase >> 7) + Q(0.5)) & 0xFFFF);
                ret += Q(0.25) - fix_abs(a - Q(0.5));
                int32_t b = (int32_t)((phase >> 6) & 0xFFFF);
                ret += Q(0.125) - fix_abs((b >> 1) - Q(0.25));
            }
            return ret / 6;
        }
    }
    return 0;
}

/// Synthesize one sample of a synth (Q16, before clamping), advancing its phases.
inline int32_t synth_sample(FixedSynth &s) {
    int32_t value = waveform(s.instrument, s.filters, s.phase, s.phase2, &s);
    if (s.detune) {
        value += waveform(s.detune_instrument, s.filters, s.dphase, s.dphase2, nullptr) >> 1;
        s.dphase += s.dinc;
        s.dphase2 += s.dinc2;
    }
    s.phase += s.inc;
    s.phase2 += s.inc2;
    value = fmul(value, s.volume);
    return std::clamp(value, -One, One);
}

/// Render n samples of a synth (Q16, clamped), with the instrument fixed for
/// the loop (the waveform switch is resolved at compile time).
template<uint8_t Instrument>
void render_loop(FixedSynth &s, int32_t *out, int n) {
    uint32_t phase = s.phase, phase2 = s.phase2;
    const uint32_t inc = s.inc, inc2 = s.inc2;
    const uint8_t filters = s.filters;
    const int32_t volume = s.volume;
    if (s.detune) {
        uint32_t dphase = s.dphase, dphase2 = s.dphase2;
        const uint32_t dinc = s.dinc, dinc2 = s.dinc2;
        const uint8_t dinst = s.detune_instrument;
        for (int i = 0; i < n; i++) {
            int32_t value = waveform(Instrument, filters, phase, phase2, &s);
            value += waveform(dinst, filters, dphase, dphase2, nullptr) >> 1;
            dphase += dinc;
            dphase2 += dinc2;
            phase += inc;
            phase2 += inc2;
            out[i] = std::clamp(fmul(value, volume), -One, One);
        }
        s.dphase = dphase;
        s.dphase2 = dphase2;
    } else {
        for (int i = 0; i < n; i++) {
            int32_t value = waveform(Instrument, filters, phase, phase2, &s);
            phase += inc;
            phase2 += inc2;
            out[i] = std::clamp(fmul(value, volume), -One, One);
        }
    }
    s.phase = phase;
    s.phase2 = phase2;
}

void render(FixedSynth &s, int32_t *out, int n) {
    if (!s.active) {
        for (int i = 0; i < n; i++) out[i] = 0;
        return;
    }
    switch (s.instrument) {
        case 0: render_loop<0>(s, out, n); break;
        case 1: render_loop<1>(s, out, n); break;
        case 2: render_loop<2>(s, out, n); break;
        case 3: render_loop<3>(s, out, n); break;
        case 4: render_loop<4>(s, out, n); break;
        case 5: render_loop<5>(s, out, n); break;
        case 6: render_loop<6>(s, out, n); break;
        case 7: render_loop<7>(s, out, n); break;
        default:
            // Custom instrument index with no custom SFX data: as waveform().
            for (int i = 0; i < n; i++) out[i] = synth_sample(s);
            break;
    }
}

uint32_t freq_to_inc(float freq) {
    float inc = freq * (16777216.f / SampleRate);
    return inc > 0.f ? (uint32_t)inc : 0;
}

/// Set up the fixed point synth from fake-08's synth parameters.
void setup_synth(FixedSynth &s, const z8::synth_param &p, float master_volume) {
    s.instrument = p.instrument;
    s.filters = p.filters;
    s.key = p.key;
    s.inc = freq_to_inc(p.freq);
    s.inc2 = (uint32_t)((uint64_t)s.inc * 109 / 110);
    s.volume = (int32_t)(std::clamp(p.volume * master_volume, 0.f, 4.f) * 65536.f);

    uint8_t detune = (p.filters / 8) % 3;
    s.detune = detune != 0 && p.instrument != z8::synth::INST_NOISE;
    if (s.detune) {
        float factor;
        if (p.instrument == z8::synth::INST_TRIANGLE)
            factor = (detune == 1) ? 3.0f / 4.0f : 3.0f / 2.0f;
        else if (p.instrument == z8::synth::INST_ORGAN)
            factor = (detune == 1) ? 200.0f / 199.0f : 800.0f / 199.0f;
        else if (p.instrument == z8::synth::INST_PHASER)
            factor = (detune == 1) ? 49.0f / 50.0f : 400.0f / 199.0f;
        else
            factor = (detune == 1) ? 200.0f / 199.0f : 400.0f / 199.0f;
        s.detune_instrument = (detune == 2 && p.instrument == z8::synth::INST_ORGAN)
            ? z8::synth::INST_TRIANGLE : p.instrument;
        uint32_t dinc = freq_to_inc(p.freq * factor);
        if (s.dinc == 0) {
            // Starting: the second wave is phi * factor.
            s.dphase = (uint32_t)((float)s.phase * factor);
            s.dphase2 = (uint32_t)((float)s.phase2 * factor);
        }
        s.dinc = dinc;
        s.dinc2 = (uint32_t)((uint64_t)dinc * 109 / 110);
    } else {
        s.dinc = 0;
    }

    if (p.instrument == z8::synth::INST_NOISE) {
        // scale = (advance per sample) * tscale, tscale = 22050 / key_to_freq(63)
        float scale = p.freq / SampleRate * 8.858923f;
        s.noise_scale = (int32_t)(scale * 65536.f);
        s.noise_inv = (int32_t)(65536.f / (1.f + scale));
        float factor = 1.0f - p.key / 63.0f;
        s.noise_gain = (int32_t)(1.5f * (1.0f + factor * factor) * 65536.f);
    }
    s.active = true;
}

} // namespace

//playback implementation based on zepto8's
//https://github.com/samhocevar/zepto8/blob/master/src/pico8/sfx.cpp

Audio::Audio(PicoRam* memory){
    _memory = memory;
    _paused = false;

    for (int k = 0; k < 64; k++) {
        key_freq[k] = 440.f * exp2f((k - 33.f) / 12.f);
    }

    resetAudioState();
}

void Audio::setPaused(bool paused) {
    _paused = paused;
}

void Audio::resetAudioState() {
    _audioState._musicChannel.count = -1;
    _audioState._musicChannel.pattern = -1;
    _audioState._musicChannel.mask = 0;
    _audioState._musicChannel.volume_music = 0.5f;
    _audioState._musicChannel.volume_sfx = 0.5f;
    _audioState._musicChannel.fade_volume = 0.f;
    _audioState._musicChannel.fade_volume_step = 0.f;
    _audioState._musicChannel.offset = -1;
    _audioState._musicChannel.length = 0;

    z8::filter damp1(z8::filter::type::highshelf, 2400.0f, 1.0f, -6.0f);
    z8::filter damp2(z8::filter::type::highshelf, 1000.0f, 1.0f, -12.0f);

    for(int i = 0; i < 4; i++) {
        sfxChannel &c = _audioState._sfxChannels[i];
        c.main_sfx.sfx = -1;
        c.main_sfx.offset = 0;
        c.main_sfx.time = 0;
        c.main_sfx.prev_key = 24;
        c.main_sfx.prev_vol = 0;

        c.custom_sfx.sfx = -1;
        c.sfx_music = -1;
        c.length = 0;
        c.can_loop = true;
        c.is_music = false;
        c.fade = 0.0f;
        c.last_main_instrument = 0;
        c.last_main_key = 0;
        c.last_synth = z8::synth_param();
        c.fade_synth = z8::synth_param();

        channels[i] = ChannelState();
        last_note_tag[i] = -1;
        channels[i].damp1.init(damp1);
        channels[i].damp2.init(damp2);
    }
}

audioState_t* Audio::getAudioState() {
    return &_audioState;
}

int Audio::api_sfx(int sfx, int channel, int offset, int length){
    // SFX index: valid values are 0..63 for actual samples,
    // -1 to stop sound on a channel, -2 to stop looping on a channel
    // Audio channel: valid values are 0..3, -1 (autoselect), or -2 (stop sfx on any channel)

    if (sfx < -2 || sfx > 63 || channel < -2 || channel > 4 || offset > 31)
        return 0;

    // CHANNEL -2: to stop the given sound from playing on any channel
    if (channel == -2) {
        for (int i = 0; i < 4; ++i) {
            if (_audioState._sfxChannels[i].main_sfx.sfx == sfx) {
                _audioState._sfxChannels[i].main_sfx.sfx = -1;
            }
        }
        return 0;
    }

    if (sfx == -1)
    {
        // Stop playing if sfx is a non musical channel
        if (channel != -1)
        {
            if (!_audioState._sfxChannels[channel].is_music)
                _audioState._sfxChannels[channel].main_sfx.sfx = -1;
        }
        else
        {
            // stop playing all non musical channels
            for (int i = 0; i < 4; ++i)
            {
                if (!_audioState._sfxChannels[i].is_music)
                    _audioState._sfxChannels[i].main_sfx.sfx = -1;
            }
        }
        return 0;
    }

    if (sfx == -2)
    {
        // Stop looping if sfx is a non musical channel
        if (channel != -1)
        {
            if (!_audioState._sfxChannels[channel].is_music)
                _audioState._sfxChannels[channel].can_loop = false;
        }
        else
        {
            // stop looping all non musical channels
            for (int i = 0; i < 4; ++i)
            {
                if (!_audioState._sfxChannels[i].is_music)
                    _audioState._sfxChannels[i].can_loop = false;
            }
        }
        return 0;
    }

    // Find the first available channel: either a channel that plays
    // nothing, or a channel that is already playing this sample (in
    // this case PICO-8 decides to forcibly reuse that channel, which
    // is reasonable)
    if (channel == -1)
    {
        for (int i = 0; i < 4; ++i)
        {
            if (((1 << i) & _audioState._musicChannel.mask) != 0)
                continue;

            if (_audioState._sfxChannels[i].main_sfx.sfx == -1 ||
                _audioState._sfxChannels[i].main_sfx.sfx == sfx)
            {
                channel = i;
                break;
            }
        }
    }

    // if no free channel is found, stop music's first interruptable channel
    if (channel == -1)
    {
        for (int i = 0; i < 4; ++i)
        {
            if (((1 << i) & _audioState._musicChannel.mask) != 0)
                continue;

            if (_audioState._sfxChannels[i].is_music)
            {
                channel = i;
                break;
            }
        }
    }

    // If still no channel found, the PICO-8 strategy seems to be to
    // stop the channel with fastest speed (if there are several, take the latest one)
    if (channel == -1)
    {
        uint8_t fastest_speed = 255;
        for (int i = 0; i < 4; ++i)
        {
            if (((1 << i) & _audioState._musicChannel.mask) != 0)
                continue;

            int const index = _audioState._sfxChannels[i].main_sfx.sfx;
            if (index < 0 || index >= 64)
                continue;

            struct sfx const& sfx_data = _memory->sfx[index];
            if (sfx_data.speed <= fastest_speed)
            {
                channel = i;
                fastest_speed = sfx_data.speed;
            }
        }
    }

    // still no channel found, the sfx is ignored
    if (channel == -1)
        return 0;

    // Stop any channel playing the same sfx
    for (int i = 0; i < 4; ++i)
        if (_audioState._sfxChannels[i].main_sfx.sfx == sfx)
            _audioState._sfxChannels[i].main_sfx.sfx = -1;

    // if there is already a music playing sfx, store it to be picked back up later before it's replaced
    if (_audioState._sfxChannels[channel].main_sfx.sfx != -1 && _audioState._sfxChannels[channel].is_music)
    {
        _audioState._sfxChannels[channel].sfx_music = _audioState._sfxChannels[channel].main_sfx.sfx;
    }

    // Play this sound!
    launch_sfx(sfx, channel, (float)std::max(0, offset), (float)std::max(0, length), false);

    return channel;
}

void Audio::api_music(int pattern, int16_t fade_len, int16_t mask){
    // pattern: 0..63, -1 to stop music.
    // fade_len: fade length in milliseconds (default 0)
    // mask: reserved channels

    if (pattern < -1 || pattern > 63)
        return;

    if (pattern == -1)
    {
        // Music will stop when fade out is finished
        _audioState._musicChannel.fade_volume_step = fade_len <= 0 ? -FLT_MAX
                                  : -_audioState._musicChannel.fade_volume * (1000.f / fade_len);
        return;
    }

    // Initialise music state for the whole song
    _audioState._musicChannel.count = 0;
    _audioState._musicChannel.mask = mask & 0xf;

    _audioState._musicChannel.fade_volume = 1.f;
    _audioState._musicChannel.fade_volume_step = 0.f;
    if (fade_len > 0)
    {
        _audioState._musicChannel.fade_volume = 0.f;
        _audioState._musicChannel.fade_volume_step = 1000.f / fade_len;
    }

    set_music_pattern(pattern);
}

void Audio::set_music_pattern(int pattern) {
    using std::max, std::min;

    // stop all previously playing music sounds
    for (int n = 0; n < 4; ++n)
        if (_audioState._sfxChannels[n].is_music)
        {
            _audioState._sfxChannels[n].main_sfx.sfx = -1;
            _audioState._sfxChannels[n].sfx_music = -1;
        }

    if (pattern < 0 || pattern > 63)
    {
        _audioState._musicChannel.pattern = -1;
        _audioState._musicChannel.count = -1;
        _audioState._musicChannel.offset = -1;
        _audioState._musicChannel.mask = 0;
        _audioState._musicChannel.length = 0.0f;
        return;
    }

    // Get song channels
    uint8_t channels_sfx[] = {
        _memory->songs[pattern].getSfx0(),
        _memory->songs[pattern].getSfx1(),
        _memory->songs[pattern].getSfx2(),
        _memory->songs[pattern].getSfx3(),
    };

    // Find music duration
    // if there is at least one non-looping channel:
    // length of the first non-looping channel
    // if not (all channels are looping):
    // length of slowest channel (so it stops when all channels have reached at least 32 steps)

    int16_t duration_looping = -1;
    int16_t duration_no_loop = -1;
    for (int i = 0; i < 4; ++i)
    {
        int n = channels_sfx[i];
        if (n & 0x40)
            continue;

        auto &sfx_data = _memory->sfx[n & 0x3f];
        bool has_loop = sfx_data.loopRangeEnd > 0 && sfx_data.loopRangeEnd > sfx_data.loopRangeStart;
        if (has_loop)
        {
            int16_t sfx_duration = 32 * sfx_data.speed;
            duration_looping = max(duration_looping, sfx_duration);
        }
        else
        {
            // take duration of first non_looping channel
            int16_t end_time = 32;
            if (sfx_data.loopRangeEnd == 0 && sfx_data.loopRangeStart > 0)
            {
                end_time = min<int16_t>(end_time, sfx_data.loopRangeStart);
            }
            duration_no_loop = end_time * sfx_data.speed;
            break;
        }
    }

    int16_t duration = duration_no_loop > 0 ? duration_no_loop : duration_looping;
    if (duration <= 0)
    {
        // Default duration if no valid sfx found
        duration = 32;
    }

    // Initialise music state for the current pattern
    _audioState._musicChannel.pattern = pattern;
    _audioState._musicChannel.offset = 0;
    _audioState._musicChannel.length = (float)duration;

    // Play music sfx on active channels
    for (int i = 0; i < 4; ++i)
    {
        int n = channels_sfx[i];
        if (n & 0x40)
            continue;

        if (_audioState._sfxChannels[i].main_sfx.sfx == -1)
        {
            launch_sfx(n, i, 0, 0, true);
        }
        else
        {
            // if there is already a sfx playing, we store the music one to be played later, when the current sfx stop
            _audioState._sfxChannels[i].sfx_music = n;
        }
    }
}

void Audio::launch_sfx(int16_t sfx, int16_t chan, float offset, float length, bool is_music)
{
    _audioState._sfxChannels[chan].main_sfx.sfx = sfx;
    _audioState._sfxChannels[chan].main_sfx.offset = std::max(0.f, offset);
    _audioState._sfxChannels[chan].main_sfx.time = 0.f;
    _audioState._sfxChannels[chan].length = std::max(0.f, length);
    _audioState._sfxChannels[chan].can_loop = true;
    _audioState._sfxChannels[chan].is_music = is_music;
    _audioState._sfxChannels[chan].last_main_instrument = 0xff;
    _audioState._sfxChannels[chan].last_main_key = 0xff;
    // Playing an instrument starting with the note C-2 and the
    // slide effect causes no noticeable pitch variation in PICO-8,
    // so I assume this is the default value for "previous key".
    _audioState._sfxChannels[chan].main_sfx.prev_key = 24;
    // There is no default value for "previous volume".
    _audioState._sfxChannels[chan].main_sfx.prev_vol = 0.f;
}

int16_t Audio::getCurrentSfxId(int channel){
    return _audioState._sfxChannels[channel].main_sfx.sfx;
}

int Audio::getCurrentNoteNumber(int channel){
    return _audioState._sfxChannels[channel].main_sfx.sfx < 0
        ? -1
        : (int)_audioState._sfxChannels[channel].main_sfx.offset;
}

int16_t Audio::getCurrentMusic(){
    return _audioState._musicChannel.pattern;
}

int16_t Audio::getMusicPatternCount(){
    return _audioState._musicChannel.count;
}

int16_t Audio::getMusicTickCount(){
    return (int16_t)_audioState._musicChannel.offset;
}

// Advances the SFX state by `inv_frames_per_second` seconds (one control
// block), and sets the synth parameters. Same as fake-08's, except for the
// phase (tracked by the fixed point synth).
void Audio::update_sfx_state(sfx_state& cur_sfx, z8::synth_param& new_synth,
                              float freq_factor, float length, bool is_music,
                              bool can_loop, bool half_rate, double inv_frames_per_second)
{
    using std::max;

    if (cur_sfx.sfx == -1) return;

    int const index = cur_sfx.sfx;
    assert(index >= 0 && index < 64);
    struct sfx const& sfx_data = _memory->sfx[index];

    // Speed must be 1—255 otherwise the SFX is invalid
    int const speed = max(1, (int)sfx_data.speed);

    // Single precision (software floating point is slow; offsets are < 32).
    float const offset = (float)cur_sfx.offset;
    float const time = (float)cur_sfx.time;

    // PICO-8 exports instruments as 22050 Hz WAV files with 183 samples
    // per speed unit per note, so this is how much we should advance
    float const offset_per_second = 22050.0f / (183.0f * speed);
    float const offset_per_frame = offset_per_second * (float)inv_frames_per_second;
    float next_offset = offset + offset_per_frame;
    float next_time = time + offset_per_frame;

    // Handle SFX loops. From the documentation: "Looping is turned
    // off when the start index >= end index".
    float const loop_range = float(sfx_data.loopRangeEnd - sfx_data.loopRangeStart);
    if (loop_range > 0.f && next_offset >= sfx_data.loopRangeEnd && can_loop)
    {
        next_offset = fmodf(next_offset - sfx_data.loopRangeStart, loop_range)
            + sfx_data.loopRangeStart;
    }

    bool has_end = false;
    float end_time = 32.f;
    if (length > 0.0f)
    {
        has_end = true;
        end_time = length;
    }
    // in pico 8, strangely, len is not applied to musical sfx except for pattern len calculation
    // it's probably a bug
    if (!is_music && sfx_data.loopRangeEnd == 0 && sfx_data.loopRangeStart > 0)
    {
        has_end = true;
        end_time = std::min<float>(end_time, sfx_data.loopRangeStart);
    }
    // if there is no loop, we end after the length
    if (loop_range <= 0.f)
    {
        has_end = true;
        // if not a music sfx, check where is the last note to early stop
        if (!is_music)
        {
            int last_note = 0;
            for (int n = 0; n < 32; ++n)
            {
                if (sfx_data.notes[n].getVolume() > 0)
                {
                    last_note = std::min(32, n + 1);
                }
            }
            end_time = std::min(end_time, float(last_note));
        }
    }

    if (offset < 32)
    {
        int const note_id = (int)offset;
        int const next_note_id = (int)next_offset;

        uint8_t key = sfx_data.notes[note_id].getKey();
        float volume = sfx_data.notes[note_id].getVolume() / 7.f;
        float freq = key_to_freq(key) * freq_factor;

        if (volume > 0.f)
        {
            int const fx = sfx_data.notes[note_id].getEffect();

            // Apply effect, if any
            switch (fx)
            {
            case FX_NO_EFFECT:
                break;
            case FX_SLIDE:
            {
                float t = offset - note_id;
                // From the documentation: "Slide to the next note and volume",
                // but it's actually _from_ the _prev_ note and volume.
                freq = lerp(key_to_freq(cur_sfx.prev_key), freq, t);
                if (cur_sfx.prev_vol > 0.f)
                    volume = lerp(cur_sfx.prev_vol, volume, t);
                break;
            }
            case FX_VIBRATO:
            {
                // Triangle wave modulation at 7.5 Hz, depth = half a semitone.
                float v = 7.5f * offset / offset_per_second;
                float t = fabsf(v - floorf(v) - 0.5f) - 0.25f;
                freq = lerp(freq, freq * 1.059463094359f, t);
                break;
            }
            case FX_DROP:
                freq *= 1.f - (offset - note_id);
                break;
            case FX_FADE_IN:
                volume *= offset - note_id;
                break;
            case FX_FADE_OUT:
                volume *= 1.f - (offset - note_id);
                break;
            case FX_ARP_FAST:
            case FX_ARP_SLOW:
            {
                // From the documentation:
                // "6 arpeggio fast  //  Iterate over groups of 4 notes at speed of 4
                //  7 arpeggio slow  //  Iterate over groups of 4 notes at speed of 8"
                // "If the SFX speed is <= 8, arpeggio speeds are halved to 2, 4"
                int const m = (speed <= 8 ? 32 : 16) / (fx == FX_ARP_FAST ? 4 : 8);
                int const n = (int)(m * 7.5f * offset / offset_per_second);
                int const arp_note = (note_id & ~3) | (n & 3);
                freq = key_to_freq(sfx_data.notes[arp_note].getKey());
                break;
            }
            }

            if (half_rate) freq *= 0.5f;

            new_synth.key = key;
            new_synth.freq = freq;
            new_synth.instrument = sfx_data.notes[note_id].getWaveform();
            new_synth.custom = sfx_data.notes[note_id].getCustom();
            new_synth.filters = sfx_data.filters;
            new_synth.volume = volume;
            new_synth.is_music = is_music;
        }

        if (next_note_id != note_id)
        {
            cur_sfx.prev_key = sfx_data.notes[note_id].getKey();
            cur_sfx.prev_vol = sfx_data.notes[note_id].getVolume() / 7.f;
        }
    }

    cur_sfx.offset = next_offset;
    cur_sfx.time = next_time;

    if (has_end && next_time >= end_time)
    {
        cur_sfx.sfx = -1;
    }
}

void Audio::FillAudioBuffer(void *audioBuffer, size_t offset, size_t size){
    // Stereo (32-bit samples)
    if (audioBuffer == nullptr) {
        return;
    }
    uint32_t *buffer = (uint32_t *)audioBuffer;
    int16_t mono[Block];
    size_t done = 0;
    while (done < size) {
        size_t n = std::min<size_t>(Block, size - done);
        FillMonoAudioBuffer(mono, 0, n);
        for (size_t i = 0; i < n; i++) {
            buffer[done + i] = ((uint32_t)(uint16_t)mono[i] << 16) | (uint16_t)mono[i];
        }
        done += n;
    }
}

void Audio::FillMonoAudioBuffer(void *audioBuffer, size_t offset, size_t size){
    (void)offset;
    if (audioBuffer == nullptr) {
        return;
    }

    int16_t *buffer = (int16_t *)audioBuffer;

    // Output silence when paused
    if (_paused) {
        memset(buffer, 0, size * sizeof(int16_t));
        return;
    }

    // Samples left in the current control block (carried over between calls).
    static int block_left = 0;

    int32_t mix[Block];
    size_t pos = 0;
    while (pos < size) {
        if (block_left == 0) {
            block_left = Block;
            bool is_pause = _memory->drawState.soundPauseState == 1;

            for (int chan = 0; chan < 4; ++chan) {
                double inv_frames_per_second = ((_memory->hwState.half_rate & (1 << chan)) ? 0.5 : 1.0) * Block / SampleRate;
                sfxChannel& channel_state = _audioState._sfxChannels[chan];
                ChannelState& fixed = channels[chan];

                // Advance music using the first channel
                if (chan == 0 && _audioState._musicChannel.pattern != -1 && !is_pause)
                {
                    double const offset_per_second = 22050.0 / 183.0;
                    double const offset_per_frame = offset_per_second * inv_frames_per_second;
                    _audioState._musicChannel.offset += offset_per_frame;
                    _audioState._musicChannel.fade_volume += (float)(_audioState._musicChannel.fade_volume_step * inv_frames_per_second);
                    _audioState._musicChannel.fade_volume = clamp(_audioState._musicChannel.fade_volume, 0.f, 1.f);

                    if (_audioState._musicChannel.fade_volume_step < 0 && _audioState._musicChannel.fade_volume <= 0)
                    {
                        set_music_pattern(-1);
                    }
                    else if (_audioState._musicChannel.offset >= _audioState._musicChannel.length)
                    {
                        int16_t next_pattern = _audioState._musicChannel.pattern + 1;
                        int16_t next_count = _audioState._musicChannel.count + 1;
                        if (_memory->songs[_audioState._musicChannel.pattern].getStop())
                        {
                            next_pattern = -1;
                            next_count = -1;
                        }
                        else if (_memory->songs[_audioState._musicChannel.pattern].getLoop())
                            while (--next_pattern > 0 && !_memory->songs[next_pattern].getStart())
                                ;

                        _audioState._musicChannel.count = next_count;
                        set_music_pattern(next_pattern);
                    }
                }

                // if no sfx is playing and there is a music sfx stored
                if (channel_state.main_sfx.sfx == -1 && channel_state.sfx_music != -1 && !is_pause)
                {
                    int const index = channel_state.sfx_music;
                    assert(index >= 0 && index < 64);
                    struct sfx const& sfx_data = _memory->sfx[index];

                    // compute offset to start the sfx to
                    bool want_play = true;
                    int const speed = std::max(1, (int)sfx_data.speed);
                    double new_offset = _audioState._musicChannel.offset / speed;

                    float const loop_range = (float)(sfx_data.loopRangeEnd - sfx_data.loopRangeStart);
                    if (loop_range > 0.f && channel_state.can_loop)
                    {
                        if (new_offset > sfx_data.loopRangeStart)
                            new_offset = std::fmod(new_offset - sfx_data.loopRangeStart, loop_range) + sfx_data.loopRangeStart;
                    }
                    else
                    {
                        if (new_offset > 32.0)
                            want_play = false;
                    }

                    if (want_play)
                    {
                        launch_sfx(index, chan, (float)new_offset, 0, true);
                    }
                    channel_state.sfx_music = -1;
                }

                z8::synth_param& last_synth = channel_state.last_synth;
                z8::synth_param new_synth;

                // The note being played (before the update). fake-08 detects
                // harsh changes between samples; at the control rate, effects
                // (slides, drops, vibrato) change the frequency by more than
                // the per-sample threshold every block, so frequency changes
                // count only at note boundaries (and for arpeggios).
                int note_tag = -1;
                bool note_arp = false;
                if (channel_state.main_sfx.sfx >= 0 && channel_state.main_sfx.offset < 32) {
                    int note_id = (int)channel_state.main_sfx.offset;
                    note_tag = channel_state.main_sfx.sfx * 32 + note_id;
                    int fx = _memory->sfx[channel_state.main_sfx.sfx].notes[note_id].getEffect();
                    note_arp = fx == FX_ARP_FAST || fx == FX_ARP_SLOW;
                }
                bool note_changed = note_tag != last_note_tag[chan];
                last_note_tag[chan] = note_tag;

                if (!is_pause && channel_state.main_sfx.sfx != -1)
                {
                    double main_sfx_base_offset = channel_state.main_sfx.offset;
                    bool half_rate = _memory->hwState.half_rate & (1 << (chan + 4));
                    // update main sfx
                    update_sfx_state(channel_state.main_sfx, new_synth, 1.0f, channel_state.length,
                                    channel_state.is_music, channel_state.can_loop, half_rate, inv_frames_per_second);

                    bool restart_custom = new_synth.instrument != channel_state.last_main_instrument ||
                                          new_synth.key != channel_state.last_main_key;
                    channel_state.last_main_instrument = new_synth.instrument;
                    channel_state.last_main_key = new_synth.key;

                    if (new_synth.volume > 0.0f && new_synth.custom)
                    {
                        // also need to restart if main_sfx loops (new offset is before base offset)
                        if (channel_state.main_sfx.offset < main_sfx_base_offset) restart_custom = true;
                        // also need to restart if custom_sfx.sfx == -1 (it has ended) and main_sfx.offset is changing integer
                        if (channel_state.custom_sfx.sfx == -1 &&
                            (int)main_sfx_base_offset != (int)channel_state.main_sfx.offset)
                            restart_custom = true;

                        if (restart_custom)
                        {
                            channel_state.custom_sfx.sfx = new_synth.instrument;
                            channel_state.custom_sfx.offset = 0.0;
                            channel_state.custom_sfx.time = 0.0;
                        }
                        float const freq_base = key_to_freq(24); // C2
                        float freq_factor = new_synth.freq / freq_base;
                        float main_sfx_volume = new_synth.volume;
                        update_sfx_state(channel_state.custom_sfx, new_synth, freq_factor, 0.0f, false, true, half_rate, inv_frames_per_second);
                        new_synth.volume *= main_sfx_volume;
                    }
                }

                // detect harsh changes of states, and do a small fade
                float freq_threshold = std::min(new_synth.freq, last_synth.freq) * 0.01f;
                bool harsh = std::abs(new_synth.volume - last_synth.volume) > 0.1f
                    || ((note_changed || note_arp) && std::abs(new_synth.freq - last_synth.freq) > freq_threshold)
                    || new_synth.instrument != last_synth.instrument;
                if (harsh)
                {
                    if (fixed.fade <= 0) // avoid continuous fades, it messes with noise algo
                    {
                        fixed.fade_synth = fixed.synth;
                    }
                    fixed.fade = One;
                    // reset the phase between notes (keep the fraction)
                    // (the phaser's second triangle and the detune wave are
                    // derived from the phase, as in fake-08)
                    fixed.synth.phase &= 0xFFFFFF;
                    fixed.synth.phase2 = (uint32_t)((uint64_t)fixed.synth.phase * 109 / 110);
                    fixed.synth.dinc = 0; // re-derive the detune phase in setup_synth
                }
                last_synth = new_synth;

                if (new_synth.volume > 0.f)
                {
                    float master = new_synth.is_music
                        ? _audioState._musicChannel.fade_volume * _audioState._musicChannel.volume_music
                        : _audioState._musicChannel.volume_sfx;
                    setup_synth(fixed.synth, new_synth, master);
                    fixed.tail = TailSamples;
                }
                else
                {
                    fixed.synth.active = false;
                    fixed.synth.volume = 0;
                    fixed.synth.filters = new_synth.filters;
                }
            }
        }

        int n = std::min<int>(block_left, (int)(size - pos));
        for (int i = 0; i < n; i++) mix[i] = 0;

        for (int chan = 0; chan < 4; ++chan) {
            ChannelState& c = channels[chan];
            if (!c.synth.active && c.fade <= 0 && c.tail <= 0) continue;
            c.tail -= n;

            uint8_t filters = c.synth.filters;
            uint8_t reverb = (filters / 24) % 3;
            uint8_t dampen = (filters / 72) % 3;
            int32_t reverb1 = reverb == 1 ? One : 0;
            int32_t reverb2 = reverb == 2 ? One : 0;
            int32_t damp1 = dampen == 1 ? One : 0;
            int32_t damp2 = dampen == 2 ? One : 0;
            int32_t fade_reverb1 = 0, fade_reverb2 = 0, fade_damp1 = 0, fade_damp2 = 0;
            if (c.fade > 0) {
                uint8_t fr = (c.fade_synth.filters / 24) % 3;
                uint8_t fd = (c.fade_synth.filters / 72) % 3;
                fade_reverb1 = fr == 1 ? One : 0;
                fade_reverb2 = fr == 2 ? One : 0;
                fade_damp1 = fd == 1 ? One : 0;
                fade_damp2 = fd == 2 ? One : 0;
            }
            // hw can force fx passes
            uint8_t hw_reverb = _memory->hwState.reverb;
            uint8_t hw_lowpass = _memory->hwState.lowpass;
            uint8_t hw_distort = _memory->hwState.distort;

            int32_t value_buf[Block];
            render(c.synth, value_buf, n);
            int32_t fade_buf[Block];
            const bool fading = c.fade > 0;
            if (fading) render(c.fade_synth, fade_buf, n);

            // Effects that the hardware forces on
            const bool hw_r1 = hw_reverb & (1 << (chan + 4));
            const bool hw_r2 = hw_reverb & (1 << chan);
            const bool hw_d1 = hw_lowpass & (1 << (chan + 4));
            const bool hw_d2 = hw_lowpass & (1 << chan);
            const bool distort_a = hw_distort & (1 << chan);
            const bool distort_b = !distort_a && (hw_distort & (1 << (chan + 4)));

            for (int i = 0; i < n; i++) {
                int32_t value = value_buf[i];
                int32_t r1 = reverb1, r2 = reverb2, d1 = damp1, d2 = damp2;

                if (fading && c.fade > 0) {
                    value += fmul(fade_buf[i] - value, c.fade);
                    r1 += fmul(fade_reverb1 - r1, c.fade);
                    r2 += fmul(fade_reverb2 - r2, c.fade);
                    d1 += fmul(fade_damp1 - d1, c.fade);
                    d2 += fmul(fade_damp2 - d2, c.fade);
                    // fade -= 130 / 22050 per sample
                    c.fade -= (130 * One) / SampleRate;
                }

                if (hw_r1) r1 = One;
                if (hw_r2) r2 = One;
                if (hw_d1) d1 = One;
                if (hw_d2) d2 = One;

                // Work in Q15 from here (like the int16 buffers).
                int32_t v = value >> 1;
                int i2 = c.reverb_i2;
                int i4 = c.reverb_i4;
                if (r1 > 0) v += fmul(r1, c.reverb_2[i2]) >> 1;
                if (r2 > 0) v += fmul(r2, c.reverb_4[i4]) >> 1;
                int16_t stored = (int16_t)std::clamp(v, -32768, 32767);
                c.reverb_2[i2] = stored;
                c.reverb_4[i4] = stored;
                c.reverb_i2 = i2 == 365 ? 0 : i2 + 1;
                c.reverb_i4 = i4 == 731 ? 0 : i4 + 1;

                // The dampening filters only run while they're used (fake-08
                // runs them all the time; their state matters only briefly
                // after they're enabled).
                if (d1 > 0) v += fmul(c.damp1.run(v) - v, d1);
                if (d2 > 0) v += fmul(c.damp2.run(v) - v, d2);

                // 32767.99 * clamp(value, -0.99, 0.99)
                int32_t chan_sample = std::clamp(v, -32440, 32440);

                // Apply hardware distort
                if (distort_a) {
                    chan_sample = chan_sample / 0x1000 * 0x1249;
                } else if (distort_b) {
                    chan_sample = (chan_sample - (chan_sample < 0 ? 0x1000 : 0)) / 0x1000 * 0x1249;
                }
                mix[i] += chan_sample;
            }
            if (c.fade < 0) c.fade = 0;
        }

        for (int i = 0; i < n; i++) {
            buffer[pos + i] = (int16_t)std::clamp(mix[i], -32767, 32767);
        }
        pos += n;
        block_left -= n;
    }
}
