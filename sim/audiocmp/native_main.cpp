// Native (x86) fake-08 audio harness: runs a cart for N 60 Hz frames and writes
// the audio (22050 Hz mono) to a WAV file. Built twice: with fake-08's original
// audio and with sw/audio.cpp, to compare them.
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <array>
#include <algorithm>

#include "Audio.h"
#include "PicoRam.h"
#include "host.h"
// The Lua profiler (LUA_PROFILE) reads the VM's Lua state (private: vm.h
// with its members public, after the headers it includes).
#include <string>
#include <vector>
#include "graphics.h"
#include "Input.h"
#include "cart.h"
#include "hostVmShared.h"
#define class struct
#include "vm.h"
#undef class
#include <map>
#include <string>
#include "lstate.h"
#include "lobject.h"
#include "lfunc.h"
#include "ldebug.h"

// LUA_PROFILE=n: sample the running Lua function every n VM instructions
// (from the first frame on), and print the hottest functions at the end:
// samples, the name it was called by, its size, and its first string
// constants (to find it in the source: minified carts are one long line).
namespace luaprof {
struct Entry { long samples = 0; std::string name; bool bios = false; };
std::map<const Proto *, Entry> funcs;
long total;
void hook(lua_State *L, lua_Debug *ar) {
    if (lua_getinfo(L, "Sn", ar) == 0) return;
    CallInfo *ci = ar->i_ci;
    if (!isLua(ci)) return;
    const Proto *p = clLvalue(ci->func)->p;
    Entry &e = funcs[p];
    e.samples++;
    if (e.name.empty() && ar->name) e.name = ar->name;
    // fake-08's Lua code (the bios) vs the cart's (loaded with the cart's
    // first line as its source).
    e.bios = strncmp(ar->source, "--", 2) != 0 && strstr(ar->source, "__z8_tick") != nullptr;
    total++;
}
// LINE_TRACE=file: the Lua source lines executed (a line per line event:
// step, source, line), to find where two builds' executions part.
FILE *lineTrace;
int step;
void lineHook(lua_State *L, lua_Debug *ar) {
    if (lua_getinfo(L, "S", ar) == 0) return;
    // The first characters of the chunk (the bios and the cart are strings).
    char src[13] = {0};
    for (int k = 0; k < 12 && ar->source[k] && ar->source[k] != '\n'; k++) src[k] = ar->source[k];
    fprintf(lineTrace, "%d %s %d\n", step, src, ar->currentline);
}
// CALL_TRACE=file: each call of a C function (the PICO-8 API) with its
// arguments: step, name, arguments (numbers as fix32 bits).
FILE *callTrace;
void callHook(lua_State *L, lua_Debug *ar) {
    if (lua_getinfo(L, "Sn", ar) == 0 || ar->what[0] != 'C') return;
    if (ar->event == LUA_HOOKRET) {
        // The top value: the (first) result of most API functions.
        if (lua_gettop(L) > 0 && lua_type(L, -1) == LUA_TNUMBER)
            fprintf(callTrace, "%d  %s -> %08x (%d values)\n", step, ar->name ? ar->name : "?",
                (unsigned)lua_tonumberx(L, -1, NULL).bits(), lua_gettop(L));
        return;
    }
    fprintf(callTrace, "%d %s", step, ar->name ? ar->name : "?");
    for (int k = 1; k <= lua_gettop(L); k++) {
        int t = lua_type(L, k);
        if (t == LUA_TNUMBER) fprintf(callTrace, " %08x", (unsigned)lua_tonumberx(L, k, NULL).bits());
        else if (t == LUA_TSTRING) fprintf(callTrace, " \"%.20s\"", lua_tostring(L, k));
        else fprintf(callTrace, " %s", lua_typename(L, t));
    }
    fputc('\n', callTrace);
}
// The hook set on every thread (also the coroutines created later, see
// z8hooks.h).
lua_Hook threadHook;
int threadMask, threadCount;
void setHook(lua_State *L, lua_Hook h, int mask, int count) {
    threadHook = h;
    threadMask = mask;
    threadCount = count;
    lua_sethook(L, h, mask, count);
}
// INSTR_COUNT=1, with a build counting every VM instruction (lvm.c calling
// z8_instr_count, not in the normal build): exact instructions per function.
std::map<const Proto *, long> instrs;
long instrTotal;
void countInstr(const Proto *p) {
    instrs[p]++;
    instrTotal++;
}
void reportInstrs(int frames) {
    std::vector<std::pair<long, const Proto *>> v;
    for (auto &[p, n] : instrs) v.push_back({n, p});
    std::sort(v.rbegin(), v.rend());
    fprintf(stderr, "VM instructions: %ld (%ld per frame)\n", instrTotal, instrTotal / (frames ? frames : 1));
    for (size_t i = 0; i < v.size() && i < 25; i++) {
        const Proto *p = v[i].second;
        const char *src = getstr(p->source);
        bool bios = strncmp(src, "--", 2) != 0 && strstr(src, "__z8_tick") != nullptr;
        std::string consts;
        for (int k = 0; k < p->sizek && consts.size() < 60; k++) {
            if (ttisstring(&p->k[k])) consts += std::string(" ") + getstr(rawtsvalue(&p->k[k]));
        }
        fprintf(stderr, "%5.1f%%  %-4s line %-5d %4d instr %2d params |%s\n", 100.0 * v[i].first / instrTotal,
            bios ? "BIOS" : "cart", p->linedefined, p->sizecode, p->numparams, consts.c_str());
    }
}
void report() {
    std::vector<std::pair<long, const Proto *>> v;
    for (auto &[p, e] : funcs) v.push_back({e.samples, p});
    std::sort(v.rbegin(), v.rend());
    fprintf(stderr, "Lua profile: %ld samples\n", total);
    for (size_t i = 0; i < v.size() && i < 25; i++) {
        const Proto *p = v[i].second;
        std::string consts;
        for (int k = 0; k < p->sizek && consts.size() < 60; k++) {
            if (ttisstring(&p->k[k])) consts += std::string(" ") + getstr(rawtsvalue(&p->k[k]));
        }
        fprintf(stderr, "%5.1f%%  %-4s %-10s %4d instr %2d params |%s\n", 100.0 * v[i].first / total,
            funcs[p].bios ? "BIOS" : "cart", funcs[p].name.c_str(), p->sizecode, p->numparams, consts.c_str());
    }
}
}

// Deterministic time (fake-08 seeds rnd() from the clock), so runs can be compared.
#include <time.h>
extern "C" int clock_gettime(clockid_t, struct timespec *ts) {
    static long long t = 1000000000LL;
    t += 1000;
    ts->tv_sec = t / 1000000000LL;
    ts->tv_nsec = t % 1000000000LL;
    return 0;
}

// Defined by a build that counts instructions (see luaprof::countInstr).
extern void (*z8_instr_count)(const Proto *) __attribute__((weak));

void z8_newthread_hook(lua_State *L1) {
    // Before the thread's stack and CallInfo exist: the fields lua_sethook sets.
    if (luaprof::threadHook) {
        L1->hook = luaprof::threadHook;
        L1->basehookcount = luaprof::threadCount;
        L1->hookcount = luaprof::threadCount;
        L1->hookmask = (lu_byte)luaprof::threadMask;
    }
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
    // NOGC=1: stop Lua's garbage collector (to test whether a difference
    // between builds comes from the collection timing).
    if (getenv("NOGC")) lua_gc(vm->_luaState, LUA_GCSTOP, 0);
    if (const char *ct = getenv("CALL_TRACE")) {
        luaprof::callTrace = fopen(ct, "w");
        luaprof::setHook(vm->_luaState, luaprof::callHook, LUA_MASKCALL | LUA_MASKRET, 0);
    }
    if (const char *lt = getenv("LINE_TRACE")) {
        // Before the cart's coroutine is created (it inherits the hook).
        luaprof::lineTrace = fopen(lt, "w");
        luaprof::setHook(vm->_luaState, luaprof::lineHook, LUA_MASKLINE, 0);
    }
    if (getenv("INSTR_COUNT") && &z8_instr_count) {
        vm->Step();  // the cart's init isn't counted
        z8_instr_count = luaprof::countInstr;
    }
    if (const char *lp = getenv("LUA_PROFILE")) {
        // Before the cart's coroutine is created (it inherits the hook), and
        // the cart's init isn't counted.
        luaprof::setHook(vm->_luaState, luaprof::hook, LUA_MASKCOUNT, atoi(lp));
        vm->Step();
        luaprof::funcs.clear();
        luaprof::total = 0;
    }
    for (int i = 0; i < frames; i++) {
        uint8_t held = (press >= 0 && i >= press && i < press + 10) ? (1 << 4) : 0;
        for (auto &p : presses) if (i >= p[0] && i < p[0] + p[2]) held |= p[1];
        setInputState(held & ~prev, held, 0, 0, 0);
        prev = held;
        luaprof::step = i;
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

    if (getenv("LUA_PROFILE")) luaprof::report();
    if (getenv("INSTR_COUNT") && &z8_instr_count) luaprof::reportInstrs(frames);
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
