# PICO-8 core for Game Bub

A [PICO-8](https://www.lexaloffle.com/pico-8.php) fantasy console core for the
[Game Bub](https://gamebub.net/) handheld, built with the Game Bub framework. It
runs as an SD card core.

Like the [MiSTer PICO-8 core](https://github.com/MiSTerOrganize/MiSTer_PICO-8),
it's a hybrid: a CPU runs a PICO-8 emulator (Lua VM), and the FPGA does the
video and audio output. The Game Bub has no application processor (its MCU, an
ESP32-S3, is busy with the UI and has too little RAM), so the CPU is a RISC-V
soft core in the FPGA:

```
 ESP32-S3 (menu, SD card) ──QSPI──▶ FPGA (XC7A100T)
   loads pico8.bin, cart,           ┌────────────────────────────────────┐
   save file                        │ VexiiRiscv RV32IMC @ 111.1 MHz     │
                                    │   32 KiB I$ / 32 KiB D$            │
                                    │   fake-08 + z8lua, from SDRAM      │
                                    │        │  ▲▼ shared RAM            │
                                    │        │ 2nd VexiiRiscv: audio     │
                                    │        ▼ 128x128 4bpp + palette    │
                                    │ framebuffer (triple buffered) ─────┼─▶ framework
                                    │ audio FIFO (22050 Hz) ─────────────┼─▶ (LCD/HDMI,
                                    │ SDRAM controller ── 32 MiB SDRAM   │    speakers)
                                    └────────────────────────────────────┘
```

* **Emulator**: [fake-08](https://github.com/jtothebell/fake-08) (MIT), with
  its PICO-8 flavored Lua ([z8lua](https://github.com/jtothebell/z8lua)),
  compiled for the soft CPU with newlib (`sw/`). The PICO-8 video frame is
  scaled 3x (384x384) by the framework.
* **Audio**: fake-08's synthesizer (from zepto8) updates the note state and
  generates waveforms per sample in floating point, which is ~10x too slow
  without an FPU. `sw/audio.cpp` reimplements it: note state at a control rate
  (every 32 samples), waveforms, reverb and filters per sample in fixed point
  (~2-20% of the CPU time, depending on the channels used). It's compared
  against the original in `sim/audiocmp/` (per instrument/effect/filter, and
  whole carts).
* **Audio core**: a second VexiiRiscv runs the synthesizer and keeps the
  audio FIFO filled (~23 ms), so the main CPU only runs the VM
  (`sw/audio_core.h`). The main CPU's `sfx()`, `music()` and so on are sent
  to it through a mailbox in a shared RAM, with the changed music and SFX
  memory. The caches aren't coherent, so each CPU's data in the SDRAM is kept
  apart from the other's (`sw/link.ld`). Without an audio core (VexRiscv, or
  `audioCore = 0` in `HandheldPico8.scala`), the main CPU makes the samples.
* **Graphics accelerator** (`hdl/pico8_gfx.sv`): a blitter that draws
  sprites, fills (with fill patterns), text and the frame copy from commands
  the CPU queues, in parallel with the Lua VM. The PICO-8 RAM (64 KiB) lives
  in its block RAM, uncached for the CPU; fake-08 sends commands for the
  common cases (`sw/gfx.h`) and draws the rest itself. The SoC holds the
  CPU's accesses that would race the queued commands (screen reads and
  writes, sprite sheet writes). See `docs/performance-roadmap.md`.
* **CPU**: [VexiiRiscv](https://github.com/SpinalHDL/VexiiRiscv) (MIT),
  single issue, with write-back data cache (64 byte lines) and GShare/BTB/RAS
  branch prediction, generated (`scripts/gen_vexiiriscv.sh`, output in
  `hdl/vexiiriscv/`). [VexRiscv](https://github.com/SpinalHDL/VexRiscv) (MIT,
  `scripts/gen_vexriscv.sh`, `hdl/vexriscv/`) is still selectable
  (`cpuVexii = 0` in `HandheldPico8.scala`).
* **Clock**: 111.1 MHz (CPU and SDRAM) for the default core, tested on
  hardware with `sw/clocktest` (see Clock testing). A second, experimental
  core runs at 125 MHz (~12% faster): it works on the test device but is
  outside Vivado's worst case timing, see "125 MHz core" below.

## AI assistance

This port was developed with extensive AI assistance: most of its code (the
SoC and graphics accelerator RTL, the Chisel core, the CPU program and the
fake-08 changes), its tests and tools, and its documentation were written
with Claude (Anthropic) in Claude Code, directed by the author, who chose
what to build and tested the cores on a Game Bub. Every commit in this
repository is co-authored by Claude (the `Co-Authored-By` trailers).
Performance claims and correctness checks come from the simulations and
tests described here and in `docs/performance-roadmap.md`; hardware results
are from a single rev 4 device.

The components it builds on (fake-08, z8lua, zepto8, VexiiRiscv, VexRiscv,
the Game Bub framework) are their authors' work, under their licenses (see
License).

## Install

Requires a rev 4 device with Game Bub firmware v1.1-beta2 or later (the
first official firmware that lists SD card cores).
The v1.1-beta2 firmware (`gamebub-rev4_v1.1-beta2.uf2`) is attached to the
[latest release](https://github.com/danisla/gamebub-pico8/releases/latest).

Download `pico8-gamebub.zip` from the
[releases](https://github.com/danisla/gamebub-pico8/releases) (or build it,
see Build) and copy its `cores/PICO-8/` to `/cores/PICO-8/` on the SD card:
`core.json`, `files.json`, `settings.json`, `pico8_rev4.bit` and `pico8.bin`.
PICO-8 then appears in the core list.

The zip also has `cores/PICO-8-Fast/`, the same core at 125 MHz ("PICO-8
(125 MHz, experimental)"): copy it too to try it, see "125 MHz core".

`extras/` has hardware test programs (`memtest`, `clocktest`): they replace
`pico8.bin`. Carts are `.p8` or `.p8.png` files; cart data (`cartdata()`) is
saved next to the cart as `.p8d`.

### 125 MHz core

`PICO-8-Fast` is the same design and program as `PICO-8` with the clock
raised from 111.1 to 125 MHz, about 12% faster on carts that are limited by
the Lua VM. It is experimental, so the default stays at 111.1 MHz:

* Vivado's worst case timing is not met at 125 MHz (about -0.9 ns in the CPU
  and -1.4 ns on the SDRAM read capture, see Clock testing). Vivado assumes a
  slow chip, high temperature and low voltage. It passed the stress test
  (0 errors, cold and warm) and ran carts fine on one rev 4 device, but
  other devices may have less margin.
* If it fails, it fails as a freeze, a TRAP screen, corrupted graphics or
  sound, or a crash after running for a while, most likely when the device is
  hot (long sessions, a warm room, charging while playing) or on a low
  battery. If you see any of these, go back to `PICO-8` (111.1 MHz) before
  reporting a bug in the emulator.
* To check your device, run the clock test (`pico8-clocktest.zip`, the
  "PICO-8 T125 p225" core) for at least 5 minutes, both cold and after the
  device has warmed up: it should show 0 errors and a wide passing window
  around the built-in phase.
* Rebuilding the bitstream changes placement and routing, so timing and
  margin can shift: each build needs to be tested on hardware again.
* Power use and heat are slightly higher.

Controls: D-pad, B = O, A = X (Y and X also work), Start = pause menu.

Settings: "Screen rotation" turns the screen 90 degrees, to play with the
device held in portrait ("D-pad at bottom" or "D-pad at top"), and turns the
D-pad with it. The PICO-8 screen is square, so it's the same size (3x,
384x384) either way: 480 pixels (the short side) is the limit.

## Layout

* `hdl/`: the SoC (SystemVerilog):
  * `pico8_soc.sv`: CPUs, bus, block RAM, shared RAM, framebuffer, audio FIFO, I/O
    registers, host access.
  * `pico8_sdram.sv`: SDRAM controller (cache line bursts, byte masks).
  * `pico8_gfx.sv`: graphics accelerator.
  * `pico8_gamebub.sv`: wrapper for the Chisel core.
  * `pico8.xdc`: constraints (SDRAM I/O timing, as in the SNES core).
  * `vexii_adapter.sv`: VexiiRiscv behind VexRiscv style Wishbone buses.
  * `vexiiriscv/`, `vexriscv/`: generated CPUs.
* `src/main/scala/pico8/`: the Chisel core (clocks, host interface, commands).
* `core/PICO-8/`: SD card core definition.
* `sw/`: the CPU program: startup, system calls (RAM file system, save
  buffer), the fake-08 platform layer (`gamebub.cpp`), audio (`audio.cpp`).
* `sim/`: simulations and test tools:
  * `sim/`: the SoC with an SDRAM model (Verilator); runs `pico8.bin` with a
    cart, dumps frames (PPM) and audio (WAV), samples the CPU's PC
    (`--profile`). `cmp_frames.py` compares the frames of two runs.
    `sim/hwtest/`: bare-metal hardware test; `sim/iobench/`: memory access
    costs.
  * `sim/host/`: the generated Chisel core, driven like the firmware (file
    loading, commands, save readback).
  * `sim/audiocmp/`: native (x86) builds of fake-08: the audio comparison,
    `native_check.sh`'s builds (deterministic screen hashes and audio, to
    check software changes in a minute), Lua profiling and traces
    (`native_main.cpp`), `vmbench.py` (the Lua VM against stock Lua).
  * `sim/carts/`: test carts (`gfxtest`, `alltest`, `tabletest`, `trigtest`,
    `envtest`) and the baseline carts.
* `docs/performance-roadmap.md`: profiles, what was optimized and how it was
  checked, and what's next.
* `sw/clocktest/`, `sw/memtest/`: hardware test programs (install as
  `pico8.bin`).
* `nix/`: RISC-V toolchain (`toolchain.nix`) and a Vivado FHS environment for
  NixOS (`vivado-fhs.nix`).
* `framework/`: the Game Bub framework (submodule).
* `third_party/`: fake-08, VexiiRiscv and pythondata-cpu-vexriscv
  (submodules).

## Memory maps

CPU:

| Address       | Size   | |
|---------------|--------|-|
| `0x0000_0000` | 8 MiB  | SDRAM: program image (loaded by the host) |
| `0x0080_0000` | 22 MiB | SDRAM: data, bss, stack, heap |
| `0x01E0_0000` | 1 MiB  | SDRAM: audio core data and stack |
| `0x01F0_0000` | 1 MiB  | SDRAM: cart (loaded by the host) |
| `0x1000_0000` | 64 KiB | block RAM (cached; `sw/clocktest`) |
| `0xF000_0000` |        | I/O registers (`sw/hw.h`; `0x40`/`0x44`: SDRAM test controls) |
| `0xF001_0000` | 8 KiB  | framebuffer back buffer (write only) |
| `0xF002_0000` | 4 KiB  | save buffer |
| `0xF003_0000` | 8 KiB  | shared RAM (with the audio core) |
| `0xF004_0000` | 64 KiB | the block RAM, uncached: the PICO-8 RAM (with the graphics accelerator) |

Host (`files.json`): `0x1xxx_xxxx` program, `0x2xxx_xxxx` cart, `0x4xxx_xxxx`
save buffer, `0x0000_xxxx` registers (`0x2000`: reset).

## Build

Requires nix (for the RISC-V toolchain and Verilator), Vivado 2026.1 in
`~/Xilinx`, Java and Python 3.

```
git submodule update --init framework
git submodule update --init --recursive third_party/fake-08
# only to regenerate the CPU (needs a JDK 17 and sbt):
git submodule update --init --recursive third_party/VexiiRiscv

# RISC-V toolchain (rv32imc, ilp32; builds GCC from source, ~15 min)
nix build --impure -f nix/toolchain.nix -o nix/result-toolchain

# CPU program -> sw/build/pico8.bin
make -C sw

# Bitstream (on NixOS, inside the Vivado FHS environment)
python3 scripts/prepare_rtl.py
$(nix build --impure -f nix/vivado-fhs.nix --print-out-paths --no-link)/bin/vivado-env \
    -c "./framework/mill --no-daemon root.buildCore --target gamebub_rev4"

# SD card folder -> dist/cores/PICO-8/ (and dist/pico8-gamebub.zip)
./scripts/package.sh
```

The clock (`PICO8_SYSTEM_DIVIDER`, VCO 1000 MHz / divider) and SDRAM clock
phase (`PICO8_SDRAM_PHASE`, degrees) can be set for a build with environment
variables (the defaults are the release's: 111.1 MHz, 225 degrees).
`FAST_BIT` adds a second core with another bitstream: the release has the
experimental 125 MHz one (`PICO-8-Fast`, see "125 MHz core"):

```
PICO8_SDRAM_PHASE=225 VIVADO_ENV=... ./scripts/build_clocktest.sh 9 8  # dist/clocktest/
make -C sw/clocktest
BIT=dist/clocktest/pico8_rev4_111.1_p225.bit FAST_BIT=dist/clocktest/pico8_rev4_125_p225.bit \
    FAST_NAME="PICO-8 (125 MHz, experimental)" ./scripts/package.sh
./scripts/package_clocktest.sh  # dist/pico8-clocktest.zip
```

Simulation:

```
cd sim && nix shell nixpkgs#verilator nixpkgs#gcc nixpkgs#gnumake nixpkgs#perl -c make
# (make vexii: the SoC with VexiiRiscv, obj_dir_vexii/Vsim_top; make: VexRiscv)
./obj_dir/Vsim_top --frames 300 --dump-every 60 --press 120:10:10 ../sw/build/pico8.bin cart.p8.png
python3 ppm2png.py out/last.ppm out/last.png 3
```

The VexiiRiscv simulation (two CPUs) runs at ~0.6 MHz (~180x slower than
real time; the VexRiscv one at ~2.8 MHz); run several in parallel.
`make vexii VEXII_DIR=obj_dir_nogfx VEXII_GFX=0` builds it without the
graphics accelerator; `sim/cmp_frames.py` compares the frames of two runs.
For software changes, `sim/native_check.sh` checks the output in a minute
(see `docs/performance-roadmap.md`, "Measuring").

## Clock testing

`sw/clocktest/` tests the CPU and SDRAM on hardware, for choosing the clock.
It runs from block RAM (so SDRAM timing failures can't crash it):

* It sweeps the SDRAM clock phase over one clock period (the MMCM's dynamic
  phase shift), for CAS latency 2 and 3 and extra read delays, and tests the
  SDRAM at each point, showing the working range and the built-in phase's
  margin. (The SoC's `REG_SDRAM_CFG` / `REG_SDRAM_PHASE` registers change the
  SDRAM configuration and clock phase at run time; the PICO-8 program doesn't
  use them.)
* It then stress tests the SDRAM (30 MiB, several patterns) and the CPU
  (test programs with expected results computed at build time, run from
  block RAM and SDRAM), counting errors.

The results are on screen and in `<cart>.p8.log`. `scripts/build_clocktest.sh`
builds bitstreams at several clocks, and `scripts/package_clocktest.sh` makes
one test core per bitstream (`pico8-clocktest.zip` in the releases).

Measured on a rev 4 device (5 minutes of stress tests each, 0 errors at 100,
111.1 and 125 MHz): the SDRAM works over about 100-340 degrees of clock phase
(CL2), the same in degrees at each clock; the cores use 225 degrees, the
middle (±2.5 ns of margin at 125 MHz). Vivado's timing (worst case):
111.1 MHz -0.05 ns (the SDRAM read capture only, with estimated board
delays); 125 MHz short in both CPUs (up to ~0.8 ns) and the SDRAM read
capture (~1.4 ns), see `docs/performance-roadmap.md` (Fmax). The chip
(Winbond W9825G6KH) is rated for CL2 at 133 MHz (-5/-6 grades).

A higher SDRAM clock (in its own clock domain) would help little: with
VexiiRiscv's caches the SDRAM is busy under 10% of the time, and a clock
domain crossing would add latency to each cache miss.

## Status

* Simulated end to end: the host interface (file loading, commands, save
  readback) with the generated core, and fake-08 running carts on the soft
  CPU. Runs on a rev 4 device.
* Performance (CPU time per 60 Hz frame at 111.1 MHz, measured on the CPU's
  cycle counter in simulation; the device matches the simulation; details
  in `docs/performance-roadmap.md`):

  | Cart | before the accelerator and VM work | now | |
  |------|-----|-----|-----|
  | Beckon the Hellspawn (gameplay) | ~40% | ~16% | full speed |
  | Celeste | ~30% | ~20% | full speed |
  | Dinky Kong (title) | ~105% | ~65% | full speed |
  | Praxis Fighter X (title) | ~550% (10.3M cycles per step) | ~310% (5.8M) | Lua bound |

  The audio runs on the second CPU: the main CPU spends ~1% of the frame on
  it (copying changed sound memory), and the audio core is 1-12% busy (no
  FIFO underruns). Heavy carts are limited by the Lua VM on the soft CPU.
  Dual issue VexiiRiscv (`cpuVexii = 2`) is only ~4% faster per clock and
  meets timing at 76.9 MHz at best (a slower clock overall). An FPU would
  save ~2%.
* Cart data (`cartdata()`) is saved when it changes (fake-08 only saves it
  when a cart is closed, and the core is simply stopped by the host).

Design notes:
* The SDRAM controller keeps rows open (a word write to an open row takes 2
  cycles; VexRiscv's data cache is write-through) and bursts cache lines (8
  words for VexRiscv, 16 for VexiiRiscv).
* `sw/fake08.patch`: changes to fake-08 (applied to a copy in `sw/build/`,
  regenerate with `scripts/make_fake08_patch.sh`): the graphics accelerator
  hooks (`graphics.cpp`, `sw/gfx.h`), the Lua VM compiled with optimization
  (upstream z8lua had it at `-O0`), the sandbox fallback for `_ENV` only,
  `all`/`count`/`foreach`/`add`/`del`/`deli` in C, Lua API arguments
  converted to integers without soft float, integer `fix32` <-> double
  conversions, `Vm::flushCartData()`, faster `map()`/`mget()`, text and
  sprite drawing, integer string to number conversion, force inlined `fix32`
  operators, pattern-filled spans and `circfill`, computed goto dispatch
  (`Z8_COMPUTED_GOTO`), fixes (the sine table's missing last entry: `cos(0)`
  was ~1.57; the keyboard and mouse state initialized; the sandbox fallback
  writing to a reallocated stack), and fixed random and string hash seeds
  for tests (`Z8_FIXED_SEED`, `make -C sw BUILD=build-test
  EXTRA_DEFINES=-DZ8_FIXED_SEED`). Checked for identical output with the
  native builds in `sim/audiocmp/` (`sim/native_check.sh`) and the test
  carts.
* Lua errors and coroutine yields use setjmp/longjmp (`LUA_USE_LONGJMP`)
  instead of C++ exceptions (fake-08 yields every frame).
* New button presses are kept until the cart reads the buttons (30 fps carts
  read them every other frame).
* The host sends files as 32-bit words, so the last 1-3 bytes of a file whose
  size isn't a multiple of 4 are lost; the core restores the end of PNG carts
  (see `firmware-pad-partial-word.patch` for a firmware fix).
* The console output is saved as `<cart>.p8.log` next to the cart (the Log
  file in `files.json`).
* Misaligned loads/stores (the CPU traps on them) are emulated in the trap
  handler.

Not supported: splore / BBS, multicarts (`load()` of other carts), mouse and
keyboard, save states.

## License

MIT (see `LICENSE`), for this project's own code. The components keep their
own licenses (details and notices in `THIRD_PARTY_NOTICES`, which is also in
the release zip):

* Game Bub framework (`framework/`, submodule): used unmodified, under
  CERN-OHL-W-2.0 as its `LICENSE` allows (the Game Bub HDL is otherwise
  CERN-OHL-S-2.0). Keep it unmodified to keep that.
* fake-08 (MIT) and its z8lua (Lua 5.2, MIT; zepto8 parts, WTFPL 2), changed
  by `sw/fake08.patch`; the patched files keep their licenses.
* `sw/audio.cpp`: derived from fake-08 and zepto8 (MIT / WTFPL 2).
* VexiiRiscv and VexRiscv (MIT): generated Verilog in `hdl/vexiiriscv/` and
  `hdl/vexriscv/`.
* Linked into `pico8.bin`: LodePNG (zlib), miniz and SimpleIni (MIT), newlib
  (BSD-style), libstdc++ (GPL-3.0 with the GCC Runtime Library Exception).

PICO-8 is a trademark of Lexaloffle Games; this project is not affiliated with
Lexaloffle. Carts aren't included (the test carts in `sim/carts/` are this
project's own).
