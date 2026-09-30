# CLAUDE.md

PICO-8 core for the Game Bub (rev 4): a RISC-V SoC in the FPGA running fake-08.
See README.md for the architecture, memory maps and design notes.

## Build chain (NixOS)

The host is NixOS: nothing (no gcc, verilator, Vivado deps) is on the global
PATH. The pieces come from nix, and are built in this order:

1. **RISC-V toolchain** (`nix/toolchain.nix`): a cross GCC for
   `riscv32-none-elf`, newlib, `rv32imc_zicsr` / `ilp32`. It is already built
   and kept by the GC root `nix/result-toolchain` (GCC 15.3); `sw/Makefile`
   uses it (`TOOLCHAIN ?= nix/result-toolchain/bin`). Don't rebuild it:
   `nix build --impure -f nix/toolchain.nix -o nix/result-toolchain` compiles
   GCC from source (~15 min).
2. **CPU program**: `make -C sw` -> `sw/build/pico8.bin` (applies
   `sw/fake08.patch` to a copy of `third_party/fake-08` in `sw/build/`).
   Test programs: `make -C sw/clocktest`, `sw/memtest/`.
3. **RTL**: `python3 scripts/prepare_rtl.py` copies `hdl/` sources into
   `rtl/` (generated, ignored), which the framework build compiles. Run it
   after any change in `hdl/`.
4. **Bitstream** (`nix/vivado-fhs.nix`): Vivado 2026.1 is installed in
   `~/Xilinx/2026.1` (not from nix); it runs inside an FHS environment:
   ```
   $(nix build --impure -f nix/vivado-fhs.nix --print-out-paths --no-link)/bin/vivado-env \
       -c "./framework/mill --no-daemon root.buildCore --target gamebub_rev4"
   ```
   (Building `vivado-env` with today's nixpkgs may not work with the cached
   venv: see "nixpkgs isn't pinned" below.)
   This runs Chisel (`HandheldTop` + `pico8.HandheldPico8`) into
   `build/pico8.HandheldPico8-gamebub_rev4/generated/`, then Vivado. It takes
   a long time; ask before starting it.
   Build settings from the environment: `PICO8_SYSTEM_DIVIDER` (clock =
   1000 MHz / divider, default 9 = 111.1 MHz), `PICO8_SDRAM_PHASE`.
   `scripts/build_clocktest.sh` builds several clocks (`VIVADO_ENV` = the
   `vivado-env` path above).
5. **Package**: `./scripts/package.sh` -> `dist/cores/PICO-8/` and
   `dist/pico8-gamebub.zip` (see README "Build" for the release command with
   the 125 MHz core).

### nixpkgs isn't pinned

`shell.nix` and `nix/*.nix` use `builtins.getFlake "nixpkgs"` (needs
`--impure`), which resolves to the registry's nixpkgs-unstable at the time.
When unstable moves, the toolchain derivation changes and `nix-shell` (via
`shell.nix`) tries to build a new GCC from source. So don't use `nix-shell`
for everyday work; use the built `nix/result-toolchain` and cached nixpkgs
packages instead:

- Cross compile: `make -C sw` (uses `nix/result-toolchain` directly).
- Vivado: the framework build runs `build_core.py` in a Python venv that
  mill creates (`out/framework/pyBuildCore/venv.dest`) with the `python3` on
  PATH, and it pins `pex==2.24.1`, which needs Python < 3.14. nixpkgs
  unstable now has Python 3.14, so **don't delete that venv**: it can't be
  recreated with the FHS env's own python. The venv's python must also match
  the glibc in the env's `/usr/lib64` (else `symbol lookup error ...
  __pointer_chk_guard`), and Vivado needs `LD_LIBRARY_PATH=/usr/lib64` to find
  `libncurses.so.5` and the other libraries (older `vivado-env` builds lack
  it and some libraries, e.g. pixman). Recipe: the current `vivado-env` and
  `python313` from the same nixpkgs (same glibc), first on PATH:
  ```
  V=$(nix build --impure -f nix/vivado-fhs.nix --print-out-paths --no-link)
  P=$(nix build --impure --no-link --print-out-paths --expr \
      '(import (builtins.getFlake "nixpkgs") { system = "x86_64-linux"; }).python313')
  $V/bin/vivado-env -c "export PATH=$P/bin:\$PATH; \
      ./framework/mill --no-daemon root.buildCore --target gamebub_rev4"
  ```
  If the venv was made by another python (glibc mismatch), delete
  `out/framework/pyBuildCore` first so mill recreates it with this one. Check
  the glibc of an env or python with `nix-store -qR <path> | grep glibc-2`.
  A `hostname: symbol lookup error` at Vivado startup is harmless. Pinning
  nixpkgs would fix all of this.
- Verilator simulation (needs a host C++ compiler as well):
  ```
  cd sim && nix shell nixpkgs#verilator nixpkgs#gcc nixpkgs#gnumake nixpkgs#perl -c make vexii
  ```
  If that also rebuilds, a verilator already in the store works:
  `ls /nix/store | grep -E 'verilator-5[.0-9]+$'`, put its `bin/` first on
  PATH, and run `make` inside `nix-shell -p gcc gnumake perl python3`.

## Checking changes without Vivado

- Chisel only (compiles Scala, elaborates, emits SystemVerilog; seconds):
  ```
  ./framework/mill -i --no-build-lock root.runMain platform.handheld.HandheldTop \
      pico8.HandheldPico8 4 --target-dir=<scratch dir>
  ```
- SoC simulation (`sim/`, see README "Simulation"): `make vexii` builds
  `obj_dir_vexii/Vsim_top` (the release CPU, VexiiRiscv at 111.1 MHz);
  `make` builds the VexRiscv variant. Run with
  `./obj_dir_vexii/Vsim_top [--frames N --dump-every N --press F:B[:L] --rotate R --out DIR] ../sw/build/pico8.bin cart.p8.png`,
  frames are PPM (`python3 ppm2png.py in.ppm out.png 3`). ~30x slower than
  real time.
- Host interface simulation (`sim/host/`): needs the generated core from a
  full `buildCore` first.

## Layout notes

- `framework/` is a vendored copy of the Game Bub framework (not a
  submodule): avoid changing it; the core adapts to it.
- The core's register map for the host (`HandheldPico8.scala`) is what
  `core/PICO-8/settings.json` addresses (`0x2000` reset, `0x2004` screen
  rotation). Firmware v1.1-beta2 setting types: `action`, `checkbox`, `list`
  (up to 8 items); non-action values are sent at every core start, before it
  runs.
- Adding a SoC port means updating `hdl/pico8_soc.sv`, `hdl/pico8_gamebub.sv`,
  `Pico8IO` in `HandheldPico8.scala` and `sim/sim_top.sv`.
