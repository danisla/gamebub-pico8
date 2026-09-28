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
                                    │        │                           │
                                    │        ▼ 128x128 4bpp + palette    │
                                    │ framebuffer (double buffered) ─────┼─▶ framework
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
* **CPU**: [VexiiRiscv](https://github.com/SpinalHDL/VexiiRiscv) (MIT),
  single issue, with write-back data cache (64 byte lines) and GShare/BTB/RAS
  branch prediction, generated (`scripts/gen_vexiiriscv.sh`, output in
  `hdl/vexiiriscv/`). [VexRiscv](https://github.com/SpinalHDL/VexRiscv) (MIT,
  `scripts/gen_vexriscv.sh`, `hdl/vexriscv/`) is still selectable
  (`cpuVexii = 0` in `HandheldPico8.scala`).
* **Clock**: 111.1 MHz (CPU and SDRAM), and 125 MHz in the experimental
  "PICO-8 (125 MHz)" core. Both were tested on hardware with `sw/clocktest`
  (see Clock testing).

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

`cores/PICO-8-Fast/` is the same core at 125 MHz ("PICO-8 (125 MHz,
experimental)" in the core list, ~12% faster). It worked on a test device,
but is outside Vivado's worst case timing, so it may fail on other devices or
when hot (crashes, errors in carts). `extras/` has hardware test programs
(`memtest`, `clocktest`): they replace `pico8.bin`. Carts are `.p8` or `.p8.png` files; cart
data (`cartdata()`) is saved next to the cart as `.p8d`.

Controls: D-pad, B = O, A = X (Y and X also work), Start = pause menu.

## Layout

* `hdl/`: the SoC (SystemVerilog):
  * `pico8_soc.sv`: CPU, bus, block RAM, framebuffer, audio FIFO, I/O
    registers, host access.
  * `pico8_sdram.sv`: SDRAM controller (cache line bursts, byte masks).
  * `pico8_gamebub.sv`: wrapper for the Chisel core.
  * `pico8.xdc`: constraints (SDRAM I/O timing, as in the SNES core).
  * `vexii_adapter.sv`: VexiiRiscv behind VexRiscv style Wishbone buses.
  * `vexiiriscv/`, `vexriscv/`: generated CPUs.
* `src/main/scala/pico8/`: the Chisel core (clocks, host interface, commands).
* `core/PICO-8/`: SD card core definition.
* `sw/`: the CPU program: startup, system calls (RAM file system, save
  buffer), the fake-08 platform layer (`gamebub.cpp`), audio (`audio.cpp`).
* `sim/`: Verilator simulations:
  * `sim/`: the SoC with an SDRAM model; runs `pico8.bin` with a cart, dumps
    frames (PPM) and audio (WAV). `sim/hwtest/`: bare-metal hardware test.
  * `sim/host/`: the generated Chisel core, driven like the firmware (file
    loading, commands, save readback).
  * `sim/audiocmp/`: native builds of fake-08 with the original and the fixed
    point audio, and comparison scripts.
* `sw/clocktest/`, `sw/memtest/`: hardware test programs (install as
  `pico8.bin`).
* `nix/`: RISC-V toolchain (`toolchain.nix`) and a Vivado FHS environment for
  NixOS (`vivado-fhs.nix`).
* `third_party/`: fake-08, VexiiRiscv and pythondata-cpu-vexriscv
  (submodules).

## Memory maps

CPU:

| Address       | Size   | |
|---------------|--------|-|
| `0x0000_0000` | 8 MiB  | SDRAM: program image (loaded by the host) |
| `0x0080_0000` | 23 MiB | SDRAM: data, bss, stack, heap |
| `0x01F0_0000` | 1 MiB  | SDRAM: cart (loaded by the host) |
| `0x1000_0000` | 64 KiB | block RAM |
| `0xF000_0000` |        | I/O registers (`sw/hw.h`; `0x40`/`0x44`: SDRAM test controls) |
| `0xF001_0000` | 8 KiB  | framebuffer back buffer (write only) |
| `0xF002_0000` | 4 KiB  | save buffer |

Host (`files.json`): `0x1xxx_xxxx` program, `0x2xxx_xxxx` cart, `0x4xxx_xxxx`
save buffer, `0x0000_xxxx` registers (`0x2000`: reset).

## Build

Requires nix (for the RISC-V toolchain and Verilator), Vivado 2026.1 in
`~/Xilinx`, Java and Python 3.

```
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
variables. The release is built with:

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

The simulation runs at ~2.8 MHz (about 30x slower than real time).

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
middle (±2.5 ns of margin at 125 MHz). Vivado's timing (worst case): 100 MHz
met, 111.1 MHz ~0.25 ns short (CPU), 125 MHz ~0.55 ns short (CPU) and the
SDRAM read timing (with estimated board delays). The chip (Winbond
W9825G6KH) is rated for CL2 at 133 MHz (-5/-6 grades).

A higher SDRAM clock (in its own clock domain) would help little: the SDRAM
is busy ~20-25% of the time, and a clock domain crossing would add latency to
each cache miss.

## Status

* Simulated end to end: the host interface (file loading, commands, save
  readback) with the generated core, and fake-08 running carts on the soft
  CPU. Runs on a rev 4 device.
* Performance (percent of the 60 Hz frame time, VM + audio, measured on the
  CPU's cycle counter in simulation; the device matches the simulation):

  | Cart                          | VexRiscv 90.9 MHz | VexiiRiscv 90.9 MHz | VexiiRiscv 111.1 MHz (est.) | |
  |-------------------------------|------|-----|-----|---------------------|
  | Beckon the Hellspawn (gameplay) | ~62% + 19% | ~40-47% + 15% | ~33-38% + 12% | full speed |
  | Celeste                       | ~43% + 2% |  |  | full speed              |
  | Dinky Kong (gameplay)         | ~210% + 23% | ~159% + 15% | ~130% + 12% | ~70% speed (~80% at 125 MHz) |

  Heavy carts are limited by the Lua VM on the soft CPU. Dual issue
  VexiiRiscv (`cpuVexii = 2`) is only ~4% faster per clock and meets timing
  at 76.9 MHz at best (a slower clock overall). An FPU would save ~2% (soft
  float is 2-5% of the time, mostly audio control math).
* Cart data (`cartdata()`) is saved when it changes (fake-08 only saves it
  when a cart is closed, and the core is simply stopped by the host).

Design notes:
* The SDRAM controller keeps rows open (a word write to an open row takes 2
  cycles; VexRiscv's data cache is write-through) and bursts cache lines (8
  words for VexRiscv, 16 for VexiiRiscv).
* `sw/fake08.patch`: changes to fake-08 (applied to a copy in `sw/build/`,
  regenerate with `scripts/make_fake08_patch.sh`): integer `fix32` <-> double
  conversions (used for every PICO-8 API argument), `Vm::flushCartData()`,
  faster `map()`/`mget()` (cached map geometry, only visible cells),
  text and sprite drawing (checked with `sim/audiocmp/drawtest.cpp`),
  integer string to number conversion, force inlined `fix32` operators,
  pattern-filled spans and `circfill` (each row drawn once), computed goto
  dispatch in the Lua VM (`Z8_COMPUTED_GOTO`), and a fixed string hash seed
  for tests (`Z8_FIXED_SEED`). Graphics changes are checked for identical
  output with the native builds in `sim/audiocmp/`.
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

Not chosen yet. Components: the Game Bub framework (`framework/`,
CERN-OHL-S-2.0), fake-08 and z8lua (MIT), `sw/audio.cpp` (derived from fake-08
and zepto8, MIT / WTFPL), VexiiRiscv and VexRiscv (MIT), newlib and libstdc++ (linked into
`pico8.bin`).
