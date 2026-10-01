# Performance roadmap

Heavy carts (Dinky Kong: ~100-130% of the 60 Hz frame at 111.1 MHz)
are limited by the soft CPU. A faster ISA wouldn't help: the official
PICO-8 is a closed Linux/Cortex-A binary, there's no hard ARM in the
XC7A100T, and any soft CPU tops out around 100-150 MHz in this fabric. The
gains have to come from more work per clock, from the FPGA doing work the CPU
does now, or from leaner software. Three workstreams, each scoped to be picked
up independently:

1. [CPU microarchitecture](#1-cpu-microarchitecture): more instructions per
   clock from VexiiRiscv.
2. [Hot paths in hardware](#2-hot-paths-in-hardware): a graphics accelerator
   (and maybe Lua VM helpers).
3. [Software](#3-software): z8lua / fake-08 tuned for this memory hierarchy.

## Measuring

All three use the same baseline, so results compare.

**Fastest loop for a software change** (no Vivado: the device only needs the
new `pico8.bin`):

1. Correctness, ~30 s: `sim/native_check.sh before` (old sources), change
   `sw/build/fake-08`, `sim/native_check.sh after`, then `sim/native_check.sh
   compare before after`. fake-08 built natively, 6 carts x 1800 VM steps with
   presses timed in steps: screen hashes after every step and the audio must
   be identical. (It doesn't cover RISC-V specifics: the accelerator, `sw/`
   platform code, timing.)
2. Speed, a few minutes: one RTL simulation alone (~0.6 MHz: 300 frames take
   ~15 minutes; runs in parallel slow each other down; Verilator threads and
   `-O3` don't help), with a test build reporting every second:
   `make -C sw BUILD=build-perf EXTRA_DEFINES="-DZ8_FIXED_SEED -DPERF_INTERVAL=60"`.
3. Device: copy `sw/build/pico8.bin` to the core folder.

Details:

* **Simulation profile** (`sim/`, see README "Simulation"): `--profile F`
  samples the PC every 997 cycles from frame F into `DIR/profile.txt`;
  `sim/profile.py profile.txt ../sw/build/pico8.elf 40
  nix/result-toolchain/bin/riscv32-none-elf-addr2line` groups by function.
  The `[perf]` lines (every 300 frames) give the step time in percent of the
  60 Hz frame, and the run ends with SDRAM bus occupancy.
* **Baseline carts** (`sim/carts/`): Dinky Kong (`dinkykong-0.p8.png`; the
  title screen and attract demo without presses, gameplay with
  `--press 150:20:10 --press 300:1:120 --press 480:2:100`; profile from
  frame 450) is the heavy one, Beckon the Hellspawn (`--press 120:10:10
  --press 300:10:10`) and Celeste are the "must not regress" ones. porklike
  is extra coverage (many sprites); poom only up to its menu (its game is a
  multicart).
* **Same output**: build the program with fixed random and string hash
  seeds (`make -C sw BUILD=build-test EXTRA_DEFINES=-DZ8_FIXED_SEED`; fake-08
  seeds `rnd()` from the clock, so runs that differ in speed diverge), dump
  every frame (`--dump-every 1`) and compare the runs with
  `sim/cmp_frames.py`: each frame shown must be one the reference showed, in
  order (a faster run shows frames earlier). Button presses are timed in
  video frames, so runs that differ in speed may diverge after a press.
* The simulation runs at ~0.3-3 MHz: 600 frames take 10-50 minutes. Run
  carts in parallel (one process each).
* Hardware: the `[perf]` lines are in `<cart>.p8.log` on the SD card; the
  device matches the simulation.

### Baseline (2026-09-30, VexiiRiscv at 111.1 MHz, before item 2)

Simulated, profile over frames 450-600 (PC sampled in the execute stage;
`main` is the idle wait for the next frame):

| | Dinky Kong (title, ~105%) | Beckon (gameplay, ~40%) | poom (menu) |
|-|-|-|-|
| `luaV_execute` | 32.3% | 13.9% | 57.5% |
| other Lua VM / API glue | ~25% | ~8% | ~30% |
| sprites (`copySpriteToScreen`) | 9.2% | 1.3% | 2.2% |
| text (`drawCharacter*`, `print`) | 8.3% | 0.9% | 0.4% |
| spans (`_private_h_line`) | - | 7.9% | - |
| frame copy (`Host::drawFrame`) | 1.2% | 1.2% | - |
| idle (`main`) | 0 | 59.5% | 0 |

* Graphics is ~20-25% of the busy time on Dinky Kong and Beckon; the rest is
  the Lua VM and its C API glue (`luaD_precall`, `luaV_gettable`,
  `luaH_getstr`, string interning for `print`/`..`).
* The SDRAM is busy only 3-9% of the time: the caches hold the working set,
  so the CPU is limited by instructions and pipeline stalls, not memory.
* Uncached I/O accesses cost ~5.3 cycles, a cached load or store ~1.3
  (`sim/iobench/`).

## 1. CPU microarchitecture

**Goal:** more instructions per clock at the same clock (111.1 MHz, ideally
125 MHz) on the Lua VM, which is most of the time on heavy carts.

**Already tried** (README "Status"): dual issue (`cpuVexii = 2`) is ~4%
faster per clock but only meets timing at 76.9 MHz; an FPU would save ~2%.

**Candidates** (generator flags in `scripts/gen_vexiiriscv.sh`, VexiiRiscv in
`third_party/VexiiRiscv`):

* **Bigger / more associative caches.** 32 KiB I$ and D$ now (128 sets x 4
  ways x 64 B). Probably not worth much: the SDRAM is busy only 3-9% of the
  time in the baseline profiles. Confirm with hit/miss counters in the
  simulation (refills per kilo-instruction for I$ and D$). Block RAM is the
  constraint: 113.5 of 135 tiles used (the 64 KiB block RAM is now the PICO-8
  RAM, item 2a).
* **Bit manipulation (`--with-rvZbb`, `--with-rvZba`).** `sh1add/sh2add`
  (table indexing in the VM), `andn`, `clz/ctz`, `rev8`, `sext.b/h`,
  `zext.h`, `min/max`. Needs a toolchain with `-march=rv32imc_zba_zbb`
  (GCC 15 supports it, rebuild with the `march` in `sw/Makefile` only, no new
  toolchain). Cheap in LUTs; check timing.
* **LSU bypass / load-use latency** (`--with-lsu-bypass`), and the late ALU
  / relaxed branch settings: the VM's dispatch loop is load heavy
  (instruction fetch, `GETARG_*` decode, register loads), so load-to-use
  latency likely matters; measure the stall cycles first.
* **Branch prediction**: a bigger BTB / GShare history for the VM's
  indirect dispatch (computed goto, one indirect jump per opcode). Count
  mispredictions in the sim first (check whether the whiteboxer outputs,
  `--with-whiteboxer-outputs`, expose them).
* **Divide**: `fix32` division goes through `__divdi3` (64-bit software
  division, ~1.7% on Dinky Kong), see item 3; the hardware `div` latency
  matters once that uses it.
* **Fmax**: the CPU path is ~0.25 ns short at 111.1 MHz and ~0.55 ns at
  125 MHz. Floorplanning (pblock for the CPU), `--relaxed-*` options, or
  retiming the worst paths could make 125 MHz "within timing" (the
  experimental core then becomes the release one: ~12% faster).

**Steps:** (1) add cache / branch counters in the simulation, (2) try each
flag alone on Dinky Kong + Beckon (regenerate, `make vexii`, profile),
(3) keep the ones that help per clock, (4) Vivado build to check timing and
BRAM/LUTs, (5) hardware test with `sw/clocktest`.

**Watch out:** each generator run needs a JDK 17 + sbt; the `rv32imc`
toolchain flags in `sw/Makefile` must match the CPU (an instruction the CPU
lacks traps). Keep the audio core's CPU the same as the main one unless the
SoC learns to generate two variants.

## 2. Hot paths in hardware

**Goal:** take work off the CPU: the FPGA has spare LUTs (~16% used) and
DSPs (8 of 240); block RAM is tight (113.5 of 135 tiles).

### 2a. Graphics accelerator (blitter)

fake-08 draws into the PICO-8 RAM (`PicoRam`, 64 KiB, allocated in SDRAM
and cached), then `Host::drawFrame` copies the screen (0x6000, 8 KiB) to the
hardware framebuffer each frame. Candidates for hardware, by the profile:
`copySpriteToScreen` (`spr`, `sspr`), `map`, `rectfill` / `cls` / spans
(fill patterns), `print` (character blits), `tline`, `circfill`, the frame
copy.

**Architecture options considered** (the hard part is the CPU's write-back
data cache, which isn't coherent with anything else):

* **A. PICO-8 RAM in block RAM, cached, with cache maintenance.** Place
  `PicoRam` in the unused 64 KiB block RAM (`0x1000_0000`, same speed as an
  L1 hit for the CPU once cached, and a second port for the blitter). The
  CPU must write back dirty screen lines before the blitter reads them and
  invalidate them after it writes. Needs Zicbom (`--with-rvZcbm`:
  `cbo.flush` / `cbo.inval` per 64 B line) or a full-cache flush. Per-call
  maintenance is too slow for small blits (a 8x8 sprite touches 8 lines).
* **B. Screen owned by the accelerator.** The screen (8 KiB) lives only in
  the accelerator's block RAM (it can also be the video back buffer, so the
  per-frame copy disappears). Every draw is a command pushed to a FIFO
  (uncached posted stores), so drawing runs **in parallel** with the Lua VM;
  the CPU only waits when it reads the screen (`pget`, `peek`/`memcpy` in
  0x6000-0x7FFF, screen-as-spritesheet mappings via 0x5F54/0x5F55) or at
  `flip`. The accelerator keeps its own copy of the sprite sheet / map /
  flags (0x0000-0x30FF): fake-08 writes PICO-8 RAM only through its C++ API
  (`poke*`, `memcpy`, `memset`, `sset`, `mset`, `reload`, cart load), so
  those functions mirror their writes (or mark ranges dirty and upload before
  the next command). Draw state (palettes, camera, clip, fill pattern,
  color, bitmask, 0x5F00-0x5F3F) is sent with the commands that use it
  (only when it changed). Anything the accelerator doesn't support falls
  back to software on the uncached screen RAM after waiting for idle:
  correct, just slower.
* **C. Uncached screen only.** Like B, but with synchronous blits (the CPU
  waits for each one). Simpler, no parallelism, no state mirroring
  issues for state the CPU reads back.

B was chosen (overlap is where the gain is), but without mirroring: the
whole PICO-8 RAM moved into the block RAM, uncached, which is simpler and
correct by construction (uncached accesses cost ~5.3 cycles instead of ~1.3,
see below).

**Done (option B, first commands):** `hdl/pico8_gfx.sv`, driven by
`sw/gfx.h` and the `__GAMEBUB__` blocks in fake-08's `graphics.cpp`
(`sw/fake08.patch`):

* The PICO-8 RAM is the 64 KiB block RAM, mapped uncached at `0xF004_0000`
  (`PICO8_RAM`; the cached view at `0x1000_0000` is still there for
  `sw/clocktest`). Port A: the CPU. Port B: the accelerator (or the
  instruction bus when it's idle). All of fake-08 and z8lua use it unchanged
  through `PicoRam *`, so every case the accelerator doesn't handle still
  works, on the CPU.
* Commands (512 word FIFO at `REG_GFX_CMD`): `PAL` (draw palette, sent when it
  changes), `SPR` (`spr`, `map` (per cell), `sspr` when not stretched nor
  flipped horizontally: the two fast paths of `copySpriteToScreen`), `RECT` (`rectfill`, `_private_h_line` /
  `_private_v_line` spans, so `rect`, `line` (straight), `circfill`, `ovalfill`,
  `rrectfill`; `cls`), `GLYPH` (the plain text fast path), `PRESENT` (copies
  the screen to the video back buffer, sets the palette, flips).
* Frame pacing: the display is triple buffered (3 x 8 KiB): up to 2 frames
  wait to be shown, one per video frame, in order. `PRESENT` copies to the
  free back buffer right away; only with 2 frames waiting does it wait in the
  queue (`REG_GFX_WAITS` counts it), so every frame is shown and the CPU runs
  ahead. The main loop doesn't start a step with 2 frames ahead (waiting to
  be shown, or PRESENTs not done: `gfx::framesAhead`, `REG_GFX_PRESENTS`):
  otherwise, after catching up, the queue stays full (production = display
  rate), every PRESENT waits for a vblank and the CPU stalls behind it
  (screen accesses, full FIFO), with an extra frame of latency.
  Pitfalls found on the way: dropping the newest frame (the CPU path's
  policy) or replacing the pending one both lock onto every other frame
  with uneven step times (Dinky Kong's title flickers between two renderings
  every frame: it looked frozen); the accelerator's own flip reaches the
  queue count 2 cycles late, so a back-to-back PRESENT must wait for it, or
  it copies into the front buffer (a torn frame). The CPU path drops the newest frame
  instead, and with uneven step times (Dinky Kong's title: ~115% then ~60%
  of a frame) dropping (or replacing the pending frame) locks onto every
  other frame: Dinky Kong's title flickers between two renderings every
  frame, so it looked frozen.
* Ordering: the SoC holds a CPU access to the PICO-8 RAM while the
  accelerator is busy if it's a write below 0x3100 (sprites, map, flags) or
  any access to the screen (0x6000-0x7FFF), and accesses to the back buffer.
  The CPU never sees a half-drawn state. (The software must send whole
  commands: a partial command in the FIFO keeps it busy.)
* Not on the accelerator (CPU, uncached RAM: ~4x slower per pixel than
  before): color bitmask (`0x5F5E`), screen / sprite sheet remapping
  (`0x5F54`/`0x5F55`), `sspr` stretching, `tline`, `pset`, diagonal `line`,
  `circ`/`oval` outlines, `print` with wide/tall/inverted/background modes,
  odd-width clipped horizontally flipped sprites, screen modes (`0x5F2C`).
* `GFX_USE` (`sw/gfx.h`, e.g. `EXTRA_DEFINES=-DGFX_USE=1`): use only some
  commands, to find which one a difference comes from.
* Checked: `sim/carts/gfxtest.p8` (`make_gfxtest.py`) and the baseline carts
  give the same frames with and without the accelerator
  (`make vexii VEXII_DIR=obj_dir_nogfx VEXII_GFX=0`, `sim/cmp_frames.py`).

**Results** (simulated, `[perf]` step time over the first 300 frames:
CPU time per 60 Hz frame, without the idle wait; both builds show every
frame, triple buffered):

| | CPU only | with the accelerator |
|-|-|-|
| Dinky Kong (title, attract mode) | 105% | 95% |
| Dinky Kong (gameplay) | 98% | 93% |
| Celeste | 30% | 26% |
| Beckon the Hellspawn | 15% | 12% |

Graphics was ~20% of the busy time; the accelerator takes ~10-20% of it
off. What's left on the graphics side is the CPU's own work in the API
calls (uncached draw state reads, command words: ~5 cycles per access) and
the cases it doesn't handle (Dinky Kong's title text). Frames: the same as
the CPU only build (`sim/cmp_frames.py`, both directions) until the first
button press (presses are timed in video frames, and the builds run at
different speeds).

Vivado (111.1 MHz, worst case): LUTs 9974 -> 12106 (19%), block RAM 113.5 ->
117.5 tiles (third display buffer), DSPs unchanged; worst slack -0.06 ns,
only CPU internal and SDRAM read capture paths (as before the accelerator,
~-0.25 ns). Not tested on hardware yet.

What's left is the Lua VM (items 1 and 3). poom's gameplay can't be
measured: it's a multicart (`load("poom_1.p8.png")`, not supported).

**Next:**

1. Hardware test (`dist/pico8-gpu-test.zip`, core "PICO-8 (GPU test)").
2. Throughput: SPR is 4 cycles per 8 destination pixels; reuse the source
   word between destination words (3 cycles), and RECT writes whole words.
3. Move what's left by the profile: `tline` (poom-like carts), `pset` /
   `line` / `circ` (a PIXEL / LINE command), `sspr` stretching, `map` cell
   loop (one command per call instead of per cell).
4. Cut the CPU side: the draw state reads are uncached (~5 cycles each), so
   cache the draw state reads per call, and batch `map` cells.

### 2b. Lua VM helpers (later, after 2a and item 3)

The VM is most of the time on heavy carts; hardware can't run Lua, but it
can shorten the hottest paths. Options, from cheapest:

* **CFU instructions** (`--with-cfu`, VexiiRiscv's custom function unit):
  single-cycle helpers for `fix32` (saturating ops, `shl`/`shr` with
  PICO-8 semantics, `flr`, the 16.16 multiply with rounding), or a string
  hash step for `luaH_getstr` / `luaS_hash`.
* **Table lookup assist**: a small hardware hash for short strings. Only
  if the profile shows `luaH_*` / `luaS_*` near the top after item 3.

### 2c. Arithmetic helpers (libgcc calls)

The CPU has a 32-bit hardware divider (RV32M) but no FPU or bit
manipulation, so some operations go through libgcc. Measured on Dinky Kong
(gameplay, before 2a):

| helper | ~time | called from |
|-|-|-|
| `__divdi3` (64-bit signed divide) | 1.7% | `fix32::operator/` (`(a << 16) / b`, a 48/32-bit divide), `luaO_arith` (Lua `/`), `pico8_atan2`, `fix32::pow` |
| `fix32::operator double`, `__fixdfsi`, `__clzsi2`, `__fixunsdfsi` | ~2.3% | fake-08's Lua API glue: `(int)lua_tonumber(L, i)` converts each argument fix32 -> double -> int (141 call sites of `__fixdfsi`: `line`, `sspr`, `map`, `pal`, ...) |

Plan, cheapest first:

1. **Software, no hardware (done):** in fake-08's `picoluaapi.cpp`,
   `lua_tonumber` returns a small wrapper that converts to integer types on
   the bits (truncation toward zero, as through `double`; a negative number
   to a 32-bit unsigned type gives 0, as RISC-V's soft float), and to
   `fix32`/`double` as before; the 6 explicit `(int)` casts (fix32's own
   flooring conversion) call `lua_tonumberx` directly. Soft float calls in
   the API glue: 258 -> 2. Same screens and audio (`sim/native_check.sh`);
   Dinky Kong 93% -> 91% of a frame (first 300 frames).
2. **Division:** libgcc's `__divdi3` does the 64/32 divide with several
   32-bit `div`/`rem` instructions plus normalization (~200 cycles, estimated: measure it with `sim/iobench/`). Options:
   * A `fix32` specific divide (Hacker's Delight `divlu`: 2 hardware divides
     and corrections), in software.
   * A hardware divider: a VexiiRiscv CFU instruction (`--with-cfu`, needs
     regenerating the CPU) doing the 64/32 signed divide in ~34 cycles, or,
     without a CPU change, a memory-mapped divider (write dividend and
     divisor, read the quotient: ~4 uncached accesses, ~21 cycles, plus the
     divide). Either cuts a division from ~200 to ~40-60 cycles.
   * The divider itself can use the DSP48E1 slices (240, 8 used): a
     reciprocal estimate from a small table and Newton-Raphson steps on the
     DSP multipliers give a 64/32 quotient in ~6-10 cycles (vs ~34 for a
     bit-serial divider). Multiplication is already on DSPs (`mul`/`mulh`,
     so `fix32` `*` is fast).
   * `--with-rvZbb` (item 1) gives a 1-cycle `clz` for the normalization.
3. Re-profile: the soft float left is `printf`/`tostr` (`_dtoa_r`), `pow`,
   `sqrt`, and `Graphics::_getRRectCutAmount` (`rrect`), each small.

## 3. Software

**Done:**

* **The Lua VM is compiled with optimization.** Upstream z8lua had
  `__attribute__((optimize("O0")))` on `luaV_execute` (no reason recorded),
  so the interpreter loop ran unoptimized on every build, the device
  included: 2.4-5x the instructions of stock Lua 5.2 per VM operation
  (`sim/audiocmp/vmbench.py`: microbenchmarks against stock Lua). Optimized,
  it's on par with stock Lua (0.8-1.06x), and real carts take 1.4-2.7x fewer
  instructions per frame (native: poom 2.71x, Dinky Kong 1.91x, Praxis
  Fighter 1.75x, porklike 1.72x, Celeste 1.66x, Beckon 1.43x). Same screens
  and audio on all carts (switch and computed goto dispatch), test carts
  pass, and ASan + UBSan report nothing on all carts.
* Fix (z8lua): the sandbox fallbacks in `OP_GETTABUP`/`OP_GETTABLE` (API
  functions found when a cart replaces `_ENV`) wrote their result through
  `ra` computed before a call that can reallocate the Lua stack: with an
  `__index` metamethod that grows the stack, the result was lost
  (`sim/carts/envtest.p8`: "attempt to call global 'flr'").
* `all()` in C (`picoluaapi.cpp`; fake-08 had it in Lua: a Lua closure call,
  3 table reads and up to 2 `#c` per element). Praxis Fighter X (a heavy,
  object-heavy cart) spent ~25% of its Lua time in it: 17.6% fewer
  instructions per frame (native). Same values in the same order as the Lua
  version: `sim/carts/alltest.p8` (2400 randomized cases with deletions,
  insertions and holes while iterating, metatables) and identical screens
  and audio on all the `sim/native_check.sh` carts.
* Bugs found on the way (making the results depend on the build's memory
  layout): `sin_helper` read one entry past its 4096 entry table for exact
  quarter turns (`cos(0)`, `sin(0.25)`, ...): on the device `cos(0)` was ~1.57
  instead of 1 (`trigtables.h`: the missing last entry, 0;
  `sim/carts/trigtest.p8`); `Input::_kbDown` (`stat(30)`) and the mouse state
  weren't initialized.
* Tools: `LUA_PROFILE=n` (hottest Lua functions, with their names and
  string constants, for minified carts), `CALL_TRACE`/`LINE_TRACE` (API calls
  with arguments and results / Lua lines executed, to find where two builds
  part) and `NOGC` in `sim/audiocmp/native_main.cpp`; memcheck runs clean on
  the native carts (`valgrind ./sim/audiocmp/native-check cart N out.wav`).

**Next for object-heavy carts** (Praxis Fighter: ~10M cycles per frame on
the title, Lua bound): the Lua functions below; flipped and stretched `sspr`
on the accelerator (a scaled blit command: fake-08's stretch blitter runs on
the CPU, on uncached memory on the device).

**Done:** `count`, `foreach`, `add`, `del`, `deli` in C
(`installTableHelpers` in `picoluaapi.cpp`): a C function for a table
without a metatable and the usual argument types, the former Lua function
(kept, as an upvalue) for anything else, so edge cases and error messages
are unchanged. Same results and tables after: `sim/carts/tabletest.p8`
(3000 randomized cases, each function's reference mutated once to check the
test catches it) and `sim/native_check.sh` (identical on all carts);
memcheck clean. Native instructions per frame: Celeste -6.7%, Dinky Kong
-2.2%.

**Lua functions to move to C** (the list these came from), by measured share of each cart's VM
instructions (exact counts: `INSTR_COUNT=1` with a counting build of
`lvm.c`, see `sim/audiocmp/native_main.cpp`; 7 carts x 1800 frames with
presses, `all()` already in C). fake-08 implements these PICO-8 API
functions in Lua (`p8GlobalLuaFunctions.h`); everything else is C already.

| # | function | measured | why it's slow in Lua | C version |
|-|-|-|-|-|
| 1 | `count(c, v)` | Celeste 7.8% | Lua loop over `c[1..#c]` | raw loop, `lua_compare` for `v` |
| 2 | `foreach(c, f)` | Celeste 6.7%, Dinky Kong 0.4% | `for v in all(c)` + a Lua call per element | iterate as `all()` does, `lua_call(f, v)` per element (the call to `f` stays) |
| 3 | `deli(c, i)` | Dinky Kong 2.7% | `mid()` call, Lua loop shifting `c[i+1..#c]` down | raw `lua_rawgeti`/`lua_rawseti` shift |
| 4 | `add(c, x, i)` | Praxis Fighter 0.7%, porklike 0.1% | `mid()` call, `#c` twice, shift loop for `i` | `lua_rawlen` + `lua_rawseti` (append: no loop) |
| 5 | `del(c, v)` | 0 in these carts; common in games (removing bullets, particles) | Lua search then shift loop | raw search and shift, `lua_compare` for `v` |
| - | `__z8_tick`, `flip` (per-frame glue) | Beckon 13%, else <2% | ~30 VM instructions and 3 C calls per frame | not worth it (absolute cost is tiny) |
| - | `assert`, `menuitem`, `cartdata`, `load`, `stop`, `serial`, `__z8_strlen` | not per frame | | no |

Notes: 1-5 are one change (same pattern as `all()`; ~150 lines), and must
keep the Lua versions' exact behavior, including metatables (`__index`,
`__len`, `__eq`) and their error messages where carts could see them; check
with `sim/native_check.sh` and a randomized test cart like `alltest.p8`
(the old Lua functions as the reference). The shares are of VM
instructions, so the gain is a bit more than they show (each of those Lua
instructions also costs C calls: `#c`, `mid`, table reads). Most of a heavy
cart's time is its own Lua code: z8lua runs a global variable access loop at
~2.5x the instructions of stock Lua 5.2 (212 vs 85 x86 instructions per VM
instruction, `x=x+1` on a global), a VM level item to look into (fix32
arithmetic, table access).

**Goal:** fewer instructions and fewer cache misses for the same Lua
program. Already done (README "Design notes"): integer `fix32` conversions,
faster `map`/`mget`, sprite/text/span drawing, computed goto dispatch,
`LUA_USE_LONGJMP`.

**Candidates:**

* **Profile-guided layout**: `-fprofile-use` with a profile from the sim is
  not directly possible (no file I/O at profile time), but the PC samples
  can drive a hot/cold function order (`-ffunction-sections` + a linker
  script order) so the VM loop and hot API functions fit in the I$ without
  conflicts.
* **Fewer uncached accesses**: with the accelerator, the PICO-8 RAM is
  uncached; fake-08 reads the draw state field by field (camera, clip,
  palettes) in every API call. Read it once per call (or in words), and
  check `peek`/`poke` heavy carts.
* **VM**: register caching in `luaV_execute` (`base`, `k`, `pc` in
  registers across ops; check what GCC already does), specialized
  `OP_GETTABLE`/`OP_SETTABLE` paths for short string keys (field access is
  most of the table traffic in PICO-8 carts), `fix32` fast paths for
  `OP_ADD`/`OP_SUB`/`OP_MUL` without overflow checks (z8lua's semantics
  allow wrap).
* **`fix32` division**: `__divdi3` (64-bit software division, from
  `fix32::operator/`) is ~1.7% on Dinky Kong. A 32-bit `div` based version
  (normalize, one hardware divide plus a correction step), or a CFU
  instruction (item 2b).
* **Allocator**: newlib's malloc in SDRAM; a size-class allocator for small
  objects (tables, closures, strings) may cut GC + alloc time. Measure
  `luaM_*` / `malloc` / `free` / `luaC_*` share first.
* **GC tuning**: `collectgarbage("generational")` isn't in Lua 5.2, but the
  incremental pause/stepmul can trade memory (we have ~20 MiB of heap) for
  CPU time.
* **Compiler flags**: `-O2` vs `-O3` per file (VM: `-O3` + no inline limit
  for `luaV_execute`), LTO for fake-08's API glue.

**Steps:** profile Dinky Kong / Beckon with the current build, rank
functions, pick the top ones; every change checked for identical output
(`sim/audiocmp/` native builds for graphics, frame dumps for carts).

## Status

| | |
|-|-|
| 1. CPU microarchitecture | not started |
| 2a. Graphics accelerator | first version: simulated (same frames, ~5-20% less CPU time), Vivado timing no worse than before (still slightly short in the CPUs, as before); needs a hardware test |
| 2b. Lua VM helpers | not started |
| 2c. Arithmetic helpers | API argument conversions done (software); divider planned |
| 3. Software | Lua VM optimized (was -O0); `all`, `count`, `foreach`, `add`, `del`, `deli` in C; trig table, input initialization and sandbox fallback fixes |
